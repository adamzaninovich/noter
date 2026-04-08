# Plan: Notes Runner GenServer for Progress Tracking on Reconnect

## Context

When a user reloads the page during notes generation, the UI shows "Generating notes..." instead of "Extracting facts... (3/20 chunks)". The current approach tried `Registry.update_value` in the pipeline's `broadcast/2`, but this fails silently because `Registry.update_value/3` must be called by the owning process — and `broadcast` is called from `Task.async_stream` child processes, not the registered Task.

The fix: create a `Noter.Notes.Runner` GenServer following the `SSEClient` pattern. The GenServer holds progress state and exposes `get_progress/1` for LiveView reconnect queries.

## Changes

### 1. Add DynamicSupervisor — `lib/noter/application.ex`

Add `{DynamicSupervisor, name: Noter.NotesSupervisor, strategy: :one_for_one}` to the children list. `JobSupervisor` is a `Task.Supervisor` and can't supervise GenServers.

### 2. Create `lib/noter/notes/runner.ex` (new file)

GenServer that:
- **Registers** in `JobRegistry` with key `{session_id, :notes}` via `:via` tuple (so `Jobs.running?/2` works unchanged)
- **Starts** under `Noter.NotesSupervisor` via `DynamicSupervisor.start_child`
- In `handle_continue(:run_pipeline)`, spawns `Task.async(fn -> Pipeline.run(session_id, opts) end)` where opts include `notify_pid: self()`
- **Receives** `{:notes_progress, %{stage: :extracting, ...}}` messages from the pipeline, stores in `state.progress` (handles all stages: `:extracting`, `:complete`, `:error`)
- **Exposes** `get_progress/1`: looks up pid in `JobRegistry`, calls `GenServer.call(pid, :get_progress)`, returns `nil` if not running (matches SSEClient pattern)
- **Stops** when the task completes (`{ref, _result}` message) or crashes (`{:DOWN, ...}`)
- Uses `restart: :temporary` (same as SSEClient)

### 3. Modify `lib/noter/notes/pipeline.ex`

- Remove `@registry Noter.JobRegistry` module attribute
- Remove `Registry.update_value` from `broadcast/2`
- Add `notify_pid` parameter: extract from opts in `do_run/2`, thread through `run_pipeline/3`, `write_and_persist/5`, `handle_failure/3`, and `broadcast/3`
- `broadcast/3` becomes:
  ```elixir
  defp broadcast(session_id, message, notify_pid) do
    if notify_pid, do: send(notify_pid, message)
    Phoenix.PubSub.broadcast(@pubsub, "session:#{session_id}:jobs", message)
  end
  ```
- The `rescue` clause in `run/2` also needs `notify_pid` — extract it from opts before the rescue

### 4. Modify `lib/noter/jobs.ex`

- `start_notes_generation/2`: Replace `Task.Supervisor.start_child` + `Registry.register` with `DynamicSupervisor.start_child(Noter.NotesSupervisor, {Runner, session_id: session_id, pipeline_opts: opts})`
- `get_notes_progress/1`: Delegates to `Runner.get_progress(session_id)` which does the registry lookup + GenServer.call (matches SSEClient pattern)
- Remove `alias Noter.Notes.Pipeline, as: NotesPipeline`, add `alias Noter.Notes.Runner`

### 5. LiveView — `lib/noter_web/live/session_live/show.ex`

No changes needed. The existing code already:
- Checks `Jobs.running?(session.id, :notes)` — still works via Registry
- Calls `Jobs.get_notes_progress(session.id)` — now delegates to Runner
- Handles `{:notes_progress, ...}` from PubSub — unchanged

## Verification

1. Run `mix precommit` — all tests pass
2. Start a notes generation job in the UI
3. While "Extracting facts... (X/Y chunks)" is showing, reload the page
4. Should see the correct progress instead of "Generating notes..."
