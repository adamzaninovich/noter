defmodule Noter.Transcription.SSEClient do
  @moduledoc """
  GenServer that connects to a transcription service via Server-Sent Events (SSE),
  streams progress updates, and handles job completion notifications.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Noter.Sessions

  defstruct [
    :session_id,
    :job_id,
    :task_ref,
    buffer: "",
    completed_files: 0,
    total_files: 0,
    current_file: nil,
    current_file_pct: 0
  ]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    job_id = Keyword.fetch!(opts, :job_id)
    name = {:via, Registry, {Noter.TranscriptionRegistry, session_id}}
    GenServer.start_link(__MODULE__, {session_id, job_id}, name: name)
  end

  def running?(session_id) do
    case Registry.lookup(Noter.TranscriptionRegistry, session_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  def get_progress(session_id) do
    case Registry.lookup(Noter.TranscriptionRegistry, session_id) do
      [{pid, _}] -> GenServer.call(pid, :get_progress)
      [] -> nil
    end
  end

  @impl true
  def init({session_id, job_id}) do
    state = %__MODULE__{session_id: session_id, job_id: job_id}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    file_pct = Map.get(state, :current_file_pct, 0)
    total = max(state.total_files, 1)
    overall_pct = (state.completed_files + file_pct / 100) / total * 100

    progress = %{
      overall_pct: overall_pct,
      file: state.current_file,
      file_pct: file_pct
    }

    {:reply, progress, state}
  end

  @impl true
  def handle_continue(:connect, state) do
    parent = self()

    task =
      Task.async(fn ->
        url = Noter.Transcription.stream_url(state.job_id)

        Req.get!(url,
          into: fn {:data, chunk}, {req, resp} ->
            send(parent, {:sse_chunk, chunk})
            {:cont, {req, resp}}
          end,
          receive_timeout: :infinity
        )
      end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  @impl true
  def handle_info({:sse_chunk, chunk}, state) do
    buffer = state.buffer <> chunk
    {events, remaining} = parse_events(buffer)
    state = %{state | buffer: remaining}

    state =
      Enum.reduce(events, state, fn event, acc ->
        handle_sse_event(event, acc)
      end)

    {:noreply, state}
  end

  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    if reason != :normal do
      Logger.error("SSE stream task crashed: #{inspect(reason)}")
      broadcast(state.session_id, :error, %{error: "Stream connection lost"})
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp parse_events(buffer) do
    case String.split(buffer, "\n\n", parts: 2) do
      [complete, rest] ->
        event = parse_single_event(complete)
        {more_events, remaining} = parse_events(rest)
        {[event | more_events], remaining}

      [incomplete] ->
        {[], incomplete}
    end
  end

  defp parse_single_event(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["data", value] -> Map.put(acc, "data", value)
        ["event", value] -> Map.put(acc, "event", String.trim(value))
        _ -> acc
      end
    end)
  end

  defp handle_sse_event(%{"data" => data_str}, state) do
    case Jason.decode(data_str) do
      {:ok, %{"type" => type} = data} -> dispatch_event(type, data, state)
      {:ok, _data} -> state
      {:error, _} -> state
    end
  end

  defp handle_sse_event(_event, state), do: state

  defp dispatch_event("queued", _data, state) do
    broadcast(state.session_id, :queued, %{})
    state
  end

  defp dispatch_event("file_start", data, state) do
    total = Map.get(data, "total", state.total_files)
    file = Map.get(data, "file", state.current_file)
    state = %{state | total_files: total, current_file: file, current_file_pct: 0}
    broadcast(state.session_id, :file_start, %{file: file, total_files: total})
    state
  end

  defp dispatch_event("progress", data, state) do
    file_pct = Map.get(data, "pct", 0)
    state = %{state | current_file_pct: file_pct}
    total = max(state.total_files, 1)
    overall_pct = (state.completed_files + file_pct / 100) / total * 100

    broadcast(state.session_id, :progress, %{
      overall_pct: overall_pct,
      file: state.current_file,
      file_pct: file_pct
    })

    state
  end

  defp dispatch_event("file_done", _data, state) do
    state = %{state | completed_files: state.completed_files + 1}
    broadcast(state.session_id, :file_done, %{completed: state.completed_files})
    state
  end

  defp dispatch_event("done", data, state) do
    result = Map.get(data, "result", %{})

    Sessions.update_transcription(
      Sessions.get_session!(state.session_id),
      %{
        status: "transcribed",
        transcript_json: encode_if_map(result)
      }
    )

    broadcast(state.session_id, :done, %{})
    state
  end

  defp dispatch_event("error", data, state) do
    error = Map.get(data, "error", "Unknown transcription error")
    Logger.error("Transcription error for session #{state.session_id}: #{error}")

    Sessions.update_transcription(
      Sessions.get_session!(state.session_id),
      %{status: "trimmed"}
    )

    broadcast(state.session_id, :error, %{error: error})
    state
  end

  defp dispatch_event("cancelled", _data, state) do
    Sessions.update_transcription(
      Sessions.get_session!(state.session_id),
      %{status: "trimmed"}
    )

    broadcast(state.session_id, :cancelled, %{})
    state
  end

  defp dispatch_event(_type, _data, state), do: state

  defp encode_if_map(value) when is_map(value), do: Jason.encode!(value)
  defp encode_if_map(value) when is_list(value), do: Jason.encode!(value)
  defp encode_if_map(value), do: value

  defp broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(
      Noter.PubSub,
      "transcription:#{session_id}",
      {:transcription, event, payload}
    )
  end
end
