defmodule Noter.Notes.Runner do
  @moduledoc """
  GenServer that wraps the notes generation pipeline, enabling progress
  tracking on LiveView reconnect via the JobRegistry.

  Follows the same pattern as `Noter.Transcription.SSEClient`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Noter.Notes.Pipeline

  defstruct [:session_id, :task_ref, progress: nil]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = {:via, Registry, {Noter.JobRegistry, {session_id, :notes}}}
    GenServer.start_link(__MODULE__, {session_id, opts}, name: name)
  end

  def get_progress(session_id) do
    case Registry.lookup(Noter.JobRegistry, {session_id, :notes}) do
      [{pid, _}] -> GenServer.call(pid, :get_progress)
      [] -> nil
    end
  end

  @impl true
  def init({session_id, opts}) do
    state = %__MODULE__{session_id: session_id}
    {:ok, state, {:continue, {:run_pipeline, opts}}}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    {:reply, state.progress, state}
  end

  @impl true
  def handle_continue({:run_pipeline, opts}, state) do
    notify_pid = self()
    pipeline_opts = Keyword.get(opts, :pipeline_opts, [])

    task =
      Task.async(fn ->
        Pipeline.run(state.session_id, [notify_pid: notify_pid] ++ pipeline_opts)
      end)

    {:noreply, %{state | task_ref: task.ref}}
  end

  @impl true
  def handle_info({:notes_progress, progress}, state) do
    {:noreply, %{state | progress: progress}}
  end

  def handle_info({:extraction_started, total}, state) do
    chunks = Enum.map(0..(total - 1), &%{index: &1, status: :pending})

    progress = %{
      stage: :extracting,
      completed: 0,
      in_progress: 0,
      total: total,
      chunks: chunks
    }

    broadcast_progress(state.session_id, progress)
    {:noreply, %{state | progress: progress}}
  end

  def handle_info({:chunk_started, index}, state) do
    chunks = update_chunk_status(state.progress.chunks, index, :in_progress)
    in_progress = state.progress.in_progress + 1

    progress = %{state.progress | chunks: chunks, in_progress: in_progress}

    broadcast_progress(state.session_id, progress)
    {:noreply, %{state | progress: progress}}
  end

  def handle_info({:chunk_done, index}, state) do
    chunks = update_chunk_status(state.progress.chunks, index, :done)
    completed = state.progress.completed + 1
    in_progress = state.progress.in_progress - 1

    progress = %{state.progress | chunks: chunks, completed: completed, in_progress: in_progress}

    broadcast_progress(state.session_id, progress)
    {:noreply, %{state | progress: progress}}
  end

  def handle_info(:writing_started, state) do
    progress = %{stage: :writing}

    broadcast_progress(state.session_id, progress)
    {:noreply, %{state | progress: progress}}
  end

  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    if reason != :normal do
      Logger.error(
        "Notes pipeline task crashed for session #{state.session_id}: #{inspect(reason)}"
      )
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp broadcast_progress(session_id, progress) do
    Phoenix.PubSub.broadcast(
      Noter.PubSub,
      "session:#{session_id}:jobs",
      {:notes_progress, progress}
    )
  end

  defp update_chunk_status(chunks, index, status) do
    Enum.map(chunks, fn
      %{index: ^index} = chunk -> %{chunk | status: status}
      chunk -> chunk
    end)
  end
end
