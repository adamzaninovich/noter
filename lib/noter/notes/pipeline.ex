defmodule Noter.Notes.Pipeline do
  @moduledoc """
  Orchestrates the full notes generation pipeline for a session.
  Runs as a background job via `Noter.Jobs`.
  """

  require Logger

  alias Noter.Notes.{Aggregator, Chunker, Extractor, Writer}
  alias Noter.Sessions
  alias Noter.Sessions.Session
  alias Noter.Settings
  alias Noter.Transcription.Transcript

  @pubsub Noter.PubSub

  @doc """
  Runs the full pipeline for the given session_id.
  Session must be in `noting` status (set by finalize).
  """
  def run(session_id, opts \\ []) do
    do_run(session_id, opts)
  rescue
    e ->
      reason = Exception.message(e)
      handle_failure(session_id, reason)
      {:error, reason}
  end

  defp do_run(session_id, opts) do
    session = Sessions.get_session!(session_id)

    if session.status == "noting" do
      run_pipeline(session, opts)
    else
      reason = "Session is not in noting status"
      handle_failure(session_id, reason)
      {:error, reason}
    end
  end

  defp run_pipeline(session, opts) do
    session_id = session.id

    raw_turns = Transcript.parse_turns(session.transcript_json)

    corrected_turns =
      Transcript.apply_corrections(
        raw_turns,
        Session.replacements(session),
        Session.edits(session)
      )

    chunks = Chunker.chunk_turns(corrected_turns)
    total = length(chunks)
    context = session.context
    concurrency = Settings.get("llm_extraction_concurrency", 4)

    extraction_result =
      chunks
      |> Task.async_stream(
        fn chunk -> Extractor.extract(chunk, context, opts) end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.reduce_while({:ok, [], 0}, fn task_result, {:ok, acc, completed} ->
        case task_result do
          {:ok, {:ok, facts}} ->
            new_completed = completed + 1

            broadcast(
              session_id,
              {:notes_progress, %{stage: :extracting, completed: new_completed, total: total}}
            )

            {:cont, {:ok, [{completed, facts} | acc], new_completed}}

          {:ok, {:error, reason}} ->
            {:halt, {:error, "Extraction failed: #{reason}"}}

          {:exit, reason} ->
            {:halt, {:error, "Extraction task crashed: #{inspect(reason)}"}}
        end
      end)

    case extraction_result do
      {:ok, chunk_facts_rev, _} ->
        aggregated = chunk_facts_rev |> Enum.reverse() |> Aggregator.aggregate()
        write_and_persist(session, aggregated, context, opts)

      {:error, reason} ->
        handle_failure(session_id, reason)
        {:error, reason}
    end
  end

  defp write_and_persist(session, aggregated, context, opts) do
    case Writer.write(aggregated, context, opts) do
      {:ok, markdown} ->
        case Sessions.update_session_notes(session, %{status: "done", session_notes: markdown}) do
          {:ok, _} ->
            broadcast(session.id, {:notes_progress, %{stage: :complete}})
            :ok

          {:error, err} ->
            reason = "Failed to save notes: #{inspect(err)}"
            handle_failure(session.id, reason)
            {:error, reason}
        end

      {:error, reason} ->
        handle_failure(session.id, reason)
        {:error, reason}
    end
  end

  defp handle_failure(session_id, reason) do
    session = Sessions.get_session!(session_id)

    case Sessions.update_session_notes(session, %{status: "reviewing", notes_error: reason}) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.error("Failed to revert session #{session_id} to reviewing: #{inspect(err)}")
    end

    broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "session:#{session_id}:jobs", message)
  end
end
