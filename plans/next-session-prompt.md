## Task

You have two documents to work with:

1. **State Machine Spec**: `plans/State Machine Spec.md` — a new specification for how session statuses work in this app. This was written to fix architectural problems in the current codebase where status management was ad-hoc, had shadow state machines (`notes_status`), unnecessary intermediate statuses, and inconsistent transitions.

2. **Tech Plan**: `plans/llm-phase-plan/techplan.md` — the original technical plan for adding LLM-powered session notes generation to the app. Phases 1-3 are complete. Phase 4 (UI) has not been started. Phase 5 is future/optional.

### What needs to happen

The state machine spec introduces changes that affect the entire app, not just the notes feature. Before phase 4 can proceed, the app needs to be refactored to match the spec. This means:

- Removing 4 intermediate statuses (`uploaded`, `trimmed`, `transcribed`, `reviewed`)
- Removing the `notes_status` column (shadow state machine)
- Removing `finalized?/1` predicate
- Auto-chaining transitions (trim completion auto-starts transcription, finalize auto-starts notes)
- Fixing several bugs documented in the spec's migration notes

After that refactor, phase 4 of the tech plan can proceed — but the current phase 4 section is written against the old status flow and needs to be rewritten.

### Your job

Rewrite the tech plan from phase 4 onward to account for the state machine spec. Specifically:

1. **Add a new phase** (call it phase 4 or whatever makes sense) for the state machine refactor itself. This phase covers everything in the spec's "Migration notes" section. It is a prerequisite for the UI work.

2. **Rewrite the UI phase** (currently phase 4, will become phase 5 or whatever follows the refactor phase). Key changes from the old phase 4:
   - There is no `reviewed` status anymore. Finalize goes directly from `reviewing → noting` and auto-starts notes generation. There is no "Generate Notes" button.
   - There is no "Regenerate" button. To regenerate notes, the user goes `done → reviewing` ("Edit Session"), then finalizes again.
   - The context editor should be available during `reviewing` status, before the user finalizes. Once finalized, notes start immediately.
   - Download ZIP is only available from `done`, not from intermediate statuses.
   - Progress display and rendered notes display are still needed.
   - Error handling: on notes failure, status reverts to `reviewing`. The user sees the error and can finalize again to retry.
   - The `noting?` assign and `notes_state/2` helper in the LiveView should be removed — derive everything from `session.status`.

3. **Keep phase 5** (context auto-update) as future/optional, adjusting any status references.

4. **Update the "Data Model Changes" section** if needed to reflect the removal of `notes_status` and the simplified status list.

5. **Update the "Resolved Questions" section** at the bottom — the status flow answer needs to reflect the new simplified flow.

### Important context

- The uncommitted phase 4 code is being discarded. Don't try to preserve or reference it.
- The state machine spec is the source of truth for status management. If the tech plan contradicts the spec, the spec wins.
- Read `CLAUDE.md` and `AGENTS.md` for project conventions before writing.
- Don't change phases 1-3 — they're done and committed.
- The backend pipeline code (chunker, extractor, aggregator, writer, prompts, LLM client) from phase 3 is solid and doesn't need changes. The refactor is about status management and UI wiring, not the pipeline internals.
