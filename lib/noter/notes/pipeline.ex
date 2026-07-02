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
    notify_pid = opts[:notify_pid]

    try do
      do_run(session_id, opts, notify_pid)
    rescue
      e ->
        reason = Exception.message(e)
        handle_failure(session_id, reason, notify_pid)
        {:error, reason}
    end
  end

  defp do_run(session_id, opts, notify_pid) do
    session = Sessions.get_session!(session_id)

    if session.status == "noting" do
      run_pipeline(session, opts, notify_pid)
    else
      reason = "Session is not in noting status"
      handle_failure(session_id, reason, notify_pid)
      {:error, reason}
    end
  end

  defp run_pipeline(session, opts, notify_pid) do
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

    if notify_pid, do: send(notify_pid, {:extraction_started, total})

    extraction_result =
      chunks
      |> Task.async_stream(fn chunk -> process_chunk(chunk, context, opts, notify_pid) end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce_while({:ok, []}, &reduce_chunk_result/2)

    case extraction_result do
      {:ok, chunk_facts} ->
        aggregated = chunk_facts |> Enum.sort_by(&elem(&1, 0)) |> Aggregator.aggregate()
        {_banter, facts_for_writer} = Map.pop(aggregated, "banter", [])
        write_and_persist(session, facts_for_writer, context, opts, notify_pid)

      {:error, reason} ->
        handle_failure(session_id, reason, notify_pid)
        {:error, reason}
    end
  end

  defp process_chunk(chunk, context, opts, notify_pid) do
    if notify_pid, do: send(notify_pid, {:chunk_started, chunk.index})

    result = Extractor.extract(chunk, context, opts)

    if notify_pid != nil && match?({:ok, _}, result) do
      send(notify_pid, {:chunk_done, chunk.index})
    end

    {chunk.index, result}
  end

  defp reduce_chunk_result({:ok, {index, {:ok, facts}}}, {:ok, acc}) do
    {:cont, {:ok, [{index, facts} | acc]}}
  end

  defp reduce_chunk_result({:ok, {_index, {:error, reason}}}, _acc) do
    {:halt, {:error, "Extraction failed: #{reason}"}}
  end

  defp reduce_chunk_result({:exit, reason}, _acc) do
    {:halt, {:error, "Extraction task crashed: #{inspect(reason)}"}}
  end

  defp write_and_persist(session, aggregated, context, opts, notify_pid) do
    if notify_pid, do: send(notify_pid, :writing_started)

    case Writer.write(aggregated, context, opts) do
      {:ok, markdown} ->
        case Sessions.update_session_notes(session, %{status: "done", session_notes: markdown}) do
          {:ok, _} ->
            broadcast(session.id, {:notes_progress, %{stage: :complete}}, notify_pid)
            :ok

          {:error, err} ->
            reason = "Failed to save notes: #{inspect(err)}"
            handle_failure(session.id, reason, notify_pid)
            {:error, reason}
        end

      {:error, reason} ->
        handle_failure(session.id, reason, notify_pid)
        {:error, reason}
    end
  end

  defp handle_failure(session_id, reason, notify_pid) do
    session = Sessions.get_session!(session_id)

    case Sessions.update_session_notes(session, %{notes_error: reason}) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.error("Failed to save notes error for session #{session_id}: #{inspect(err)}")
    end

    broadcast(session_id, {:notes_progress, %{stage: :error, error: reason}}, notify_pid)
  end

  defp broadcast(session_id, message, notify_pid) do
    if notify_pid, do: send(notify_pid, message)
    Phoenix.PubSub.broadcast(@pubsub, "session:#{session_id}:jobs", message)
  end
end
