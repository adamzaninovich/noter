# Plan: Chunk Cards for Notes Extraction Progress

## Context

When a user starts notes generation, they see "Generating notes..." until the first chunk completes. There's no visibility into what's actually happening during extraction. Average session has ~20 chunks, with 4 running concurrently.

Goal: Show granular progress with visual chunk cards showing: pending (dimmed number), in-progress (spinner), done (checkmark).

## Data Structure

**Progress map** (stored in Runner, broadcast to LiveView via PubSub):
```elixir
%{
  stage: :extracting,
  completed: 5,
  in_progress: 3,
  total: 20,
  chunks: [
    %{index: 0, status: :done},
    %{index: 1, status: :done},
    # ... 5 done
    %{index: 5, status: :in_progress},
    %{index: 6, status: :in_progress},
    %{index: 7, status: :in_progress},
    # ... 3 in progress
    %{index: 8, status: :pending},
    # ... 12 pending
  ]
}
```

For writing: `%{stage: :writing}`
For complete: `%{stage: :complete}` (unchanged)

## Architecture: Message Flow

The Runner GenServer owns all progress state. The pipeline sends lightweight events to the Runner, and the Runner builds the progress map and broadcasts via PubSub.

```
Task.async_stream workers  -->  Runner GenServer  -->  PubSub  -->  LiveView
  {:chunk_started, index}        updates chunks        broadcasts
  {:chunk_done, index}           builds progress map
  {:extraction_complete}
  {:writing_started}
```

Key principles:
- **Pipeline does NOT broadcast progress directly** — it sends raw events to the Runner
- **Runner is the single source of truth** — builds the progress map from chunk states, broadcasts to PubSub
- **Extractor is not modified** — chunk lifecycle events are sent from the `Task.async_stream` callback in pipeline.ex

## Changes

### 1. `lib/noter/notes/extractor.ex`

No changes. Extractor stays pure — it takes a chunk, context, and opts, returns `{:ok, facts}` or `{:error, reason}`.

### 2. `lib/noter/notes/pipeline.ex`

**`run_pipeline/3`**:

Remove the existing progress broadcast from inside `Task.async_stream`. Instead, send lightweight events to `notify_pid` (the Runner):

- Before async_stream starts, send initial event:
  ```elixir
  if notify_pid, do: send(notify_pid, {:extraction_started, total})
  ```

- Inside the `Task.async_stream` callback:
  ```elixir
  fn chunk ->
    if notify_pid, do: send(notify_pid, {:chunk_started, chunk.index})

    result = Extractor.extract(chunk, context, opts)

    if notify_pid and match?({:ok, _}, result) do
      send(notify_pid, {:chunk_done, chunk.index})
    end

    {chunk.index, result}
  end
  ```

- Before `Writer.write/3` call in `write_and_persist/5`:
  ```elixir
  if notify_pid, do: send(notify_pid, :writing_started)
  ```

- Keep the existing `:complete` and `:error` broadcasts via `broadcast/3` (these still go to both Runner and PubSub directly since they trigger LiveView state transitions like reloading the session).

**Remove** the direct PubSub broadcast for extraction progress — the Runner handles that now. The `broadcast/3` helper is still used for `:complete` and `:error` stages.

### 3. `lib/noter/notes/runner.ex`

Update the struct to hold progress with chunks:

```elixir
defstruct [:session_id, :task_ref, progress: nil]
```

Add `handle_info/2` clauses for the new events:

```elixir
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
```

Keep the existing `handle_info({:notes_progress, progress}, state)` for `:complete` and `:error` stages.

Helper functions:

```elixir
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
```

### 4. `lib/noter_web/live/session_live/show.ex`

**Add handle_info for `:writing` stage:**
```elixir
def handle_info({:notes_progress, %{stage: :writing} = progress}, socket) do
  {:noreply, assign(socket, :notes_progress, progress)}
end
```

**Update template** (replaces current spinner-only display around line 321-333).

Use `:if` attribute on elements, flex layout (not grid), three states:

```heex
<%!-- Notes generation card --%>
<div :if={@session.status == "noting" and @review_loaded?} class="card bg-base-200 shadow-sm">
  <div class="card-body">
    <div :if={@active_job == :notes and @notes_progress && @notes_progress.stage == :extracting}>
      <div class="space-y-3">
        <div class="flex items-center justify-between text-sm">
          <span class="font-medium">Extracting facts...</span>
          <span class="text-base-content/60">
            {@notes_progress.completed} done · {@notes_progress.in_progress} in progress
          </span>
        </div>

        <div class="flex flex-wrap gap-1">
          <div :for={chunk <- @notes_progress.chunks} class="flex items-center justify-center">
            <div class="badge badge-sm h-7 w-7 rounded-full justify-center">
              <%= case chunk.status do %>
                <% :done -> %>
                  <.icon name="hero-check" class="size-3 text-success" />
                <% :in_progress -> %>
                  <span class="loading loading-spinner loading-xs text-primary"></span>
                <% :pending -> %>
                  <span class="text-base-content/30 text-xs">{chunk.index + 1}</span>
              <% end %>
            </div>
          </div>
        </div>

        <progress
          class="progress progress-primary w-full"
          value={@notes_progress.completed}
          max={@notes_progress.total}
        >
        </progress>
      </div>
    </div>

    <div :if={@active_job == :notes and @notes_progress && @notes_progress.stage == :writing} class="flex flex-col items-center py-6 gap-3">
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="text-sm text-base-content/70">Generating markdown...</p>
    </div>

    <div :if={@active_job == :notes and is_nil(@notes_progress)} class="flex flex-col items-center py-8 gap-4">
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="text-base-content/70">Preparing extraction...</p>
    </div>
  </div>
</div>
```

### 5. `reconnect_notes_progress/1`

No changes needed — `Runner.get_progress/1` returns the full progress map with chunks, so reconnect restores the correct UI state automatically.

## DaisyUI Components

- `badge badge-sm h-7 w-7 rounded-full justify-center` — compact circular chunk indicators
- `hero-check` with `text-success` — completed checkmark
- `loading-spinner loading-xs text-primary` — in-progress spinner
- `text-base-content/30` — pending dimming
- `progress progress-primary w-full` — overall progress bar

## Verification

1. `mix precommit` passes
2. Start notes generation with ~20 chunks
3. Immediately see chunk badges appear as pending (dimmed numbers)
4. As chunks process: badges flip to spinner, then checkmark
5. On reconnect (refresh page): correct badge states shown via Runner state
6. After extraction: writing stage shows spinner with "Generating markdown..."
7. On complete: notes card disappears, done state shown

## Notes

- Average session has 20 chunks, displayed in a flex-wrap layout
- Concurrency typically 4, so up to 4 badges show spinner at once
- The `{:chunk_started, index}` and `{:chunk_done, index}` messages are sent from `Task.async_stream` workers to the Runner GenServer — the GenServer mailbox serializes these into consistent state updates
- Runner stores full progress with chunks, so `get_progress/1` restores complete UI state on reconnect
- Pipeline still uses `broadcast/3` for `:complete` and `:error` stages (these go to both Runner and PubSub directly since they trigger session reload in the LiveView)
