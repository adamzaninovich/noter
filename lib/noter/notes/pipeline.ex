defmodule Noter.Notes.Pipeline do
  @moduledoc """
  Orchestrates the full notes generation pipeline for a session.
  Runs as a background job via `Noter.Jobs`.
  """

  alias Noter.Notes.{Aggregator, Chunker, Extractor, Writer}
  alias Noter.Sessions
  alias Noter.Sessions.Session
  alias Noter.Settings
  alias Noter.Transcription.Transcript

  @pubsub Noter.PubSub

  @doc """
  Runs the full pipeline for the given session_id.
  Steps:
  1. Validate session is finalized
  2. Set notes_status to "running"
  3. Parse + apply corrections + chunk the transcript
  4. Extract facts per chunk in parallel
  5. Aggregate facts
  6. Write markdown notes
  7. Persist result and broadcast completion
  """
  def run(session_id, opts \\ []) do
    do_run(session_id, opts)
  rescue
    e ->
      reason = Exception.message(e)
      session = Sessions.get_session!(session_id)
      Sessions.update_session_notes(session, %{notes_status: "error", notes_error: reason})
      broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
      {:error, reason}
  end

  defp do_run(session_id, opts) do
    session = Sessions.get_session!(session_id)

    if Session.finalized?(session) do
      run_pipeline(session, opts)
    else
      reason = "Session is not finalized"
      Sessions.update_session_notes(session, %{notes_status: "error", notes_error: reason})
      broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
      {:error, reason}
    end
  end

  defp run_pipeline(session, opts) do
    session_id = session.id
    Sessions.update_session_notes(session, %{notes_status: "running", notes_error: nil})

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

        case Writer.write(aggregated, context, opts) do
          {:ok, markdown} ->
            {:ok, updated} =
              Sessions.update_session_notes(session, %{
                notes_status: "complete",
                session_notes: markdown
              })

            {:ok, _} = Sessions.update_session(updated, %{status: "done"})
            broadcast(session_id, {:notes_progress, %{stage: :complete}})
            :ok

          {:error, reason} ->
            Sessions.update_session_notes(session, %{notes_status: "error", notes_error: reason})
            broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
            {:error, reason}
        end

      {:error, reason} ->
        Sessions.update_session_notes(session, %{notes_status: "error", notes_error: reason})
        broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}})
        {:error, reason}
    end
  end

  defp broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "session:#{session_id}:jobs", message)
  end
end
