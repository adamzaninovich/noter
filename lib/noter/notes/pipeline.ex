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
  @registry Noter.JobRegistry

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

    completed = :counters.new(1, [])

    extraction_result =
      chunks
      |> Task.async_stream(
        fn chunk ->
          result = Extractor.extract(chunk, context, opts)

          if match?({:ok, _}, result) do
            :counters.add(completed, 1, 1)

            broadcast(
              session_id,
              {:notes_progress,
               %{stage: :extracting, completed: :counters.get(completed, 1), total: total}}
            )
          end

          {chunk.index, result}
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce_while({:ok, []}, fn task_result, {:ok, acc} ->
        case task_result do
          {:ok, {index, {:ok, facts}}} ->
            {:cont, {:ok, [{index, facts} | acc]}}

          {:ok, {_index, {:error, reason}}} ->
            {:halt, {:error, "Extraction failed: #{reason}"}}

          {:exit, reason} ->
            {:halt, {:error, "Extraction task crashed: #{inspect(reason)}"}}
        end
      end)

    case extraction_result do
      {:ok, chunk_facts} ->
        aggregated = chunk_facts |> Enum.sort_by(&elem(&1, 0)) |> Aggregator.aggregate()
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

    case Sessions.update_session_notes(session, %{notes_error: reason}) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.error("Failed to save notes error for session #{session_id}: #{inspect(err)}")
    end

    broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
  end

  defp broadcast(session_id, message) do
    Registry.update_value(@registry, {session_id, :notes}, fn _ -> message end)
    Phoenix.PubSub.broadcast(@pubsub, "session:#{session_id}:jobs", message)
  end
end
