# State Machine Refactor: Fix Plan

## Context

Branch `phase-4-state-machine-refactor` consolidates 9 session statuses down to 6 (`uploading`, `trimming`, `transcribing`, `reviewing`, `noting`, `done`). The core idea is good: eliminate the redundant "completed step" statuses (`uploaded`, `trimmed`, `transcribed`, `reviewed`) and use a single `@active_job` assign instead of multiple boolean flags. But the branch has ~1200 lines of changes and introduced 4 state-machine bugs along the way.

This plan fixes those 4 bugs with minimal, targeted changes. No new abstractions, no new modules, no new infrastructure.

---

## Fix 1: Trim failure reverts to wrong state

**File:** `lib/noter/jobs.ex:54-68`
**Bug:** When `Uploads.trim_session/4` fails, the session reverts to `"uploading"`. But in the new model, post-upload sessions live in `"trimming"` — there's no way back to `"uploading"` from the UI. The user loses access to the trim editor.
**Fix:** Change `"uploading"` to `"trimming"` on line 58. The session stays in the trim stage so the user can retry.

```diff
- case Sessions.update_session(session, %{status: "uploading"}) do
+ case Sessions.update_session(session, %{status: "trimming"}) do
```

That's it. One word change.

---

## Fix 2: Unhandled exceptions in transcription submit strand sessions

**File:** `lib/noter/jobs.ex:189-226`
**Bug:** `start_transcription_submit/1` sets status to `"transcribing"` before spawning the task. Inside the task, any crash (filesystem error, process failure) kills the task without hitting the `{:error, reason}` branch. Session stays stuck in `"transcribing"` forever.
**Fix:** Wrap the task body in `try/rescue` that calls `revert_to_trimming/1` and broadcasts the failure. Keep it simple — one rescue clause, reuse the existing `revert_to_trimming/1` helper.

```elixir
Task.Supervisor.start_child(@supervisor, fn ->
  try do
    Registry.register(@registry, {session_id, :transcription_submit}, [])
    # ... existing task body unchanged ...
  rescue
    e ->
      Logger.error("Transcription submit crashed for session #{session_id}: #{Exception.message(e)}")
      revert_to_trimming(session_id)
      broadcast(session_id, {:transcription_submit_failed, "unexpected error"})
  end
end)
```

No new functions. No new modules. Just a try/rescue around the existing code.

---

## Fix 3: Migration rollback maps in-progress states to completed states

**File:** `priv/repo/migrations/20260328181029_simplify_session_statuses.exs:14-19`
**Bug:** The `down/0` maps `trimming -> trimmed` and `reviewing -> reviewed`. If a session is actively mid-trim or mid-review during a rollback, the old app sees it as "completed" and skips the step.
**Fix:** Map to the *prior incomplete* states instead — the safe fallback positions:

```diff
- execute "UPDATE sessions SET status = 'trimmed' WHERE status = 'trimming'"
- execute "UPDATE sessions SET status = 'reviewed' WHERE status = 'reviewing'"
+ execute "UPDATE sessions SET status = 'uploaded' WHERE status = 'trimming'"
+ execute "UPDATE sessions SET status = 'transcribed' WHERE status = 'reviewing'"
```

Also need to handle the new `noting` status that doesn't exist in the old schema. Map it back to `reviewed` (the old "finalized but not done" state):

```diff
+ execute "UPDATE sessions SET status = 'reviewed' WHERE status = 'noting'"
```

This is still imperfect (rollbacks always are), but at least no session skips a step.

---

## Fix 4: Notes failure dead-end — no path back to review

**File:** `lib/noter/sessions.ex:206-216`
**Bug:** `edit_session/1` only allows `done -> reviewing`. If notes generation fails, the session is stuck in `"noting"` with `notes_error` set. The user can retry notes, but can't go back to fix transcript/context issues. Dead end.
**Fix:** Allow `noting -> reviewing` in `edit_session/1`. When reverting from `noting`, clear `notes_error` and `transcript_srt` (since the transcript will be re-finalized).

```diff
- def edit_session(%Session{status: "done"} = session) do
+ def edit_session(%Session{status: status} = session) when status in ~w(noting done) do
    session
    |> Session.notes_changeset(%{
      status: "reviewing",
-     notes_error: nil
+     notes_error: nil,
+     transcript_srt: nil
    })
    |> Repo.update()
    |> broadcast_session_update()
  end
```

Also update the state machine test to cover `noting -> reviewing`.

In the LiveView (`show.ex`), the "Edit Session" button currently has `:if={@session.status == "done"}`. Change to `:if={@session.status in ~w(noting done)}` so it appears during failed notes too. But only show it when notes aren't actively generating (not when `@active_job == :notes`).

```heex
<button
  :if={@session.status in ~w(noting done) and @active_job != :notes}
  id="edit-session-btn"
  ...
```

---

## Fix 5 (bonus): Complexity audit — things that look suspicious but are fine

After reading the full diff, these are **not** problems:
- `active_job/1` replacing multiple boolean assigns — this is a genuine simplification, good change
- Auto-chain (trim -> transcription) — removes a manual step, fine
- Upload progress tracking with atomics — a bit clever but isolated and small
- `reconnect_transcription/2` refactor into cond branches — clearer than the original nested if
- Notes generation UI moved into the session page — follows the state machine flow, makes sense

The branch is large but most of the line count is mechanical status string replacements (`"uploaded"` -> `"trimming"`, `Session.finalized?(@session)` -> `@session.status in ~w(noting done)`, etc). The actual logic changes are concentrated in jobs.ex and sessions.ex.

---

## Execution order

1. Fix 1 (trim revert) — one word, zero risk
2. Fix 2 (try/rescue in transcription submit) — small, isolated
3. Fix 4 (noting -> reviewing recovery) — small change in sessions.ex + button visibility in show.ex + test
4. Fix 3 (migration rollback) — add the `noting` mapping
5. Run `mix precommit`, run `mix test`, verify all 4 fixes

## Verification

- `mix test test/noter/state_machine_test.exs` — existing tests still pass
- Add test: `noting -> reviewing` via `edit_session/1`  
- Add test: trim failure keeps session in `trimming` (not `uploading`)
- Manual: trigger a trim failure and confirm the trim editor is still accessible
- Manual: trigger a notes failure and confirm "Edit Session" button appears
