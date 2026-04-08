## Session Status State Machine

### Statuses (linear pipeline)

```
uploading → trimming → transcribing → reviewing → noting → done
```

- **uploading** — system is processing uploaded files
- **trimming** — user sets trim boundaries, confirms, system trims audio files
- **transcribing** — system is transcribing (auto-started after trim completes)
- **reviewing** — user edits transcript corrections, clicks Finalize to proceed
- **noting** — system is generating notes (auto-started on finalize)
- **done** — pipeline complete, download available

### Forward transitions

Each status advances to the next in the pipeline. Forward transitions are triggered by either user action or job completion:

| From         | To           | Trigger                       | Data produced       |
| ------------ | ------------ | ----------------------------- | ------------------- |
| uploading    | trimming     | Upload processing completes   | Files on disk       |
| trimming     | transcribing | Trim job completes            | Trimmed audio files |
| transcribing | reviewing    | Transcription completes       | `transcript_json`   |
| reviewing    | noting       | User clicks Finalize          | `transcript_srt`    |
| noting       | done         | Notes pipeline completes      | `session_notes`     |

### Backward transitions (user-initiated)

Only one backward transition exists. It discards all data produced after the reviewing phase:

| From | To        | Trigger          | Data discarded                          |
| ---- | --------- | ---------------- | --------------------------------------- |
| done | reviewing | "Edit Session"   | `session_notes`, `notes_error`, `transcript_srt` |

From `reviewing`, the user can edit corrections and finalize again, which regenerates the SRT and kicks off notes generation.

No other backward transitions exist. You cannot go back from `transcribing` to `trimming`, etc. Those processes are destructive/expensive and re-running them means starting the forward flow again from that point.

### Error transitions

Jobs that fail revert to the previous status:

| From         | To           | Condition                              |
| ------------ | ------------ | -------------------------------------- |
| noting       | reviewing    | Notes pipeline fails or is cancelled   |
| trimming     | uploading    | Trim job fails                         |
| transcribing | trimming     | Transcription fails                    |

When reverting to a previous status, persisted data from that phase is preserved so the user doesn't have to redo work. For example, reverting to `trimming` preserves the saved trim region (`trim_start_seconds`, `trim_end_seconds`) so the user sees their previous selection and can immediately re-confirm without re-trimming.

### Rules

1. **Adjacent only**: A session can only transition to the immediately next or previous status (where backward is allowed). No skipping.
2. **Discard on revert**: Moving backward discards all data produced by the reverted phase and everything after it.
3. **Status is the single source of truth**: All UI decisions, available actions, and predicates derive from `status`. No shadow state machines or meta-statuses.
4. **Job statuses are system-controlled**: Statuses that represent a running job (`trimming`, `transcribing`, `noting`) are entered and exited by the system, not by the user. They resolve to the next status on success or revert to the previous status on failure.
5. **Sub-state is internal**: Jobs like notes generation and transcription may track their own internal progress (extraction step, writing step, etc.) for UI feedback. This is ephemeral process state, not session state — it lives in the running process and is not persisted.
6. **One active job per session**: Only one background job can run per session at a time.

### Migration notes

Changes required to align the existing codebase with this spec:

- **Remove statuses `uploaded`, `trimmed`, `transcribed`, `reviewed`** from the schema. Update `@valid_statuses` and all status checks throughout the codebase. Existing sessions in these statuses need a data migration to map them to the correct new status (`uploaded` → `trimming`, `trimmed` → `trimming`, `transcribed` → `reviewing`, `reviewed` → `reviewing`).
- **Remove `notes_status` column** from the sessions table and schema. This is a shadow state machine — the session `status` already encodes whether notes are running (`noting`), complete (`done`), or failed (reverted to `reviewing`). Existing code that reads `notes_status` should derive state from `status` instead.
- **Remove `finalized?/1` predicate**. Replace call sites with direct status checks.
- **Replace `unfinalize/1`** with a single `edit_session/1` function for the `done → reviewing` transition. It should enforce that the session is in `done` status and clear `session_notes`, `notes_error`, and `transcript_srt`.
- **Auto-chain forward transitions**: Trim completion should auto-start transcription. Finalize should auto-start notes generation. Remove the manual "Start Transcription" and "Generate Notes" buttons — these become automatic on the preceding step's completion/action.
- **Fix `update_corrections` backdoor** (`sessions.ex`). Currently changes status as a side effect of editing corrections. The function should only update corrections data. Corrections should only be editable when status is `reviewing`.
- **Fix trim failure: no status revert** (`jobs.ex`). When `Uploads.trim_session` fails, the error is broadcast but status is never reverted from `trimming` to `uploading`. Session gets stuck.
- **Guard source status on all transitions**. No transition function currently validates that the session is in the expected source status. Each transition should verify the session is in the correct source status and return an error otherwise.
- **Fix `Settings.get/2` falsy values** (`settings.ex`). `Jason.decode!(setting.value) || default` treats `false`, `0`, and `0.0` as missing. Should only fall back to default for `nil`.
