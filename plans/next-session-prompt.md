## Task

Implement Phase 5 (Notes GenServer) from the tech plan.

### Context

Read these documents before starting:

1. **Tech Plan**: `plans/llm-phase-plan/techplan.md` — phase 5 has the full task list
2. **State Machine Spec**: `plans/State Machine Spec.md` — the source of truth for status management
3. **`CLAUDE.md`** and **`AGENTS.md`** — project conventions

Phases 1-4 are complete. Phase 5 replaces the fire-and-forget Task pipeline with a dynamically supervised GenServer that tracks pipeline stage and progress, enabling reconnect-safe progress queries from the UI.

### What this phase does

- Create `Noter.Notes.Server` GenServer (temporary restart, registered via Registry)
- Start it under a new `DynamicSupervisor` (`Noter.NotesSupervisor`)
- Register via `Noter.NotesRegistry` keyed by `session_id`
- `running?/1` and `get_progress/1` for LiveView reconnect
- Drive the pipeline step-by-step, updating GenServer state between steps
- Broadcast progress on `"notes:#{session_id}"` topic
- Replace `Jobs.start_notes_generation` — start a `Notes.Server` under the DynamicSupervisor instead of Task.Supervisor
- Remove old Task-based notes job from JobRegistry

### Approach

Follow the existing `Transcription.SSEClient` pattern — it's the same DynamicSupervisor + Registry + GenServer design. The pipeline logic stays in `Pipeline` module; the GenServer orchestrates and tracks progress.

Run `mix precommit` before committing.

### What NOT to do

- Don't change phases 1-4 in the tech plan — they're done
- Don't touch the pipeline internals (`Notes.Chunker`, `Extractor`, `Aggregator`, `Writer`, `Prompts`, `LLM.Client`)
- Don't start on phase 6 (UI) — this phase is just the GenServer backend
- Don't start the dev server — if Tidewave MCP is available, it's already running
