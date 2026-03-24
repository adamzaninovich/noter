# Noter Improvements

Tracked issues from a full code review. Ordered by priority within each category.

Instructions:
Whenever this file is invoked by the user, find the next uncompleted issue and analyze it.
Always discuss possible solutions before diving in.
Once a solution is agreen upon with the user, enter plan mode and plan it out.
Fix the issue.
If it makes sense, do not hesitate to add tests.
Once an issue is fixed. Edit this file and mark it complete.

---

## Security

### ~~S1: Path traversal in AudioController~~ ✅

**File:** `lib/noter_web/controllers/audio_controller.ex:6-7, 16-17, 26-27`

The `session_id` param is passed directly to `Uploads.session_dir/1` without validation. A crafted request like `/sessions/..%2F..%2Fetc/audio/merged` can read arbitrary files from the server.

The `DownloadController` is safe because it calls `Sessions.get_session_with_campaign!/1` first (Ecto coerces to integer), but `AudioController` skips the DB entirely.

**Fixed:** Added controller plug to validate `session_id` is a positive integer (returns 404 otherwise), and added path containment check in `Uploads.session_dir/1` that raises if the resolved path escapes the uploads directory.

### ~~S2: No server-side guard on mutation events during "done" status~~ ✅

**File:** `lib/noter_web/live/session_live/show.ex` — `add_replacement`, `remove_replacement`, `save_edit`, `delete_turn`, `start_edit` event handlers

The template hides mutation UI when status is "done", but LiveView events can be sent via raw websocket messages. Adding a replacement while "done" transitions back to "reviewing" and clears the finalized SRT.

**Fix:** Add a guard clause to each mutating event handler that rejects mutations when status is "done". Could be a shared helper like:

```elixir
defp require_editable(%{assigns: %{session: %{status: "done"}}} = socket),
  do: {:halt, socket}
defp require_editable(socket),
  do: {:cont, socket}
```

---

## Bugs

### ~~B1: Stream container not rendered when `@sessions_empty?` is true~~ ✅

**File:** `lib/noter_web/live/campaign_live/show.ex:66`

```heex
<div :if={not @sessions_empty?} id="sessions" phx-update="stream" ...>
```

When `@sessions_empty?` is true, the `phx-update="stream"` container isn't in the DOM. If a PubSub `{:session_updated, session}` message arrives (line 469 does `stream_insert`), there's no container to insert into. The `CampaignLive.Index` does this correctly — always renders the stream container and puts the empty state outside.

**Fix:** Always render the stream container. Move the empty-state div outside with a separate `:if`:

```heex
<div :if={@sessions_empty?} class="...">No sessions yet.</div>
<div id="sessions" phx-update="stream" class="space-y-2 mt-2">
  <.link :for={{id, session} <- @streams.sessions} id={id} ...>
```

Also update `@sessions_empty?` when a session is inserted via PubSub.

### ~~B2: Nil-safety on `session.corrections` access~~ ✅

**File:** `lib/noter/sessions.ex` — lines 112-117, 120-127, 129-136, 158-162, 165-171

`session.corrections` is accessed directly with `Map.get(session.corrections, "replacements", %{})`. The schema default is `%{}`, but if the database column stores NULL, `session.corrections` would be `nil` and `Map.get(nil, ...)` crashes.

The `apply_campaign_replacements` function at line 65 already guards with `session.corrections || %{}`, but the other functions don't.

**Fix options:**
- Add a NOT NULL + default '{}' constraint at the DB level via migration, then backfill any existing NULLs
- Consistently use `(session.corrections || %{})` everywhere
- Add accessor helpers on the Session schema: `Session.replacements(session)`, `Session.edits(session)` that handle nil internally (also addresses story C4)

### ~~B3: `cancel_upload_by_ref` crashes on unrecognized upload ref~~ ✅

**File:** `lib/noter_web/live/session_live/upload_helpers.ex:39-44`

The `case` has no fallback clause — a `CaseClauseError` will crash the LiveView if an unexpected ref arrives.

**Fix:** Add a catch-all clause that returns the socket unchanged, or logs and ignores.

---

## Performance

### ~~P1: `DownloadController.build_zip` reads all files into memory~~ ✅

**File:** `lib/noter_web/controllers/download_controller.ex:26-38`

`:zip.create/3` with `:memory` loads every FLAC track and the merged M4A into memory simultaneously. For a session with many tracks and a multi-hour recording, this could spike memory by several GB and crash the node.

`add_merged_audio` (line 41-48) and `add_tracks` (line 51-65) both use `File.read!` to load entire files eagerly.

**Fix options:**
- Write the zip to a temp file on disk instead of `:memory`, then `send_file` it (simplest)
- Stream the zip to the client via `send_chunked` using a streaming zip library
- Use Erlang's `:zip.create/3` with a file path instead of `:memory` (writes to disk, then serve)
- Add a pre-built zip step to the finalization flow so the zip is ready before the user clicks download

### ~~P2: `assign_review_state` runs heavy computation on static mount~~ ✅

**File:** `lib/noter_web/live/session_live/show.ex:48, 1573-1625`

`assign_review_state/2` parses transcript JSON, applies replacements, builds display turns, and streams all turns. Called from `mount`, this runs on both the static render and the connected mount — so JSON parsing and replacement computation for 1500-3000 turns happens twice.

**Fix options:**
- In mount, only assign the minimum for static render (`reviewing?`, session status, empty streams). Defer the heavy computation to connected mount using `if connected?(socket)` or a self-sent message
- Use `assign_async` for the transcript parsing and replacement computation
- Cache the computed display turns in the session struct or a separate ETS table

### ~~P3: `Transcript.apply_replacements` rebuilds patterns on every call~~ ✅

**File:** `lib/noter/transcription/transcript.ex:88-101`

`build_patterns/1` and `split_patterns/1` are called each time `apply_replacements` is invoked. In `recompute_review` this means patterns are rebuilt on every replacement add/remove. For large replacement sets with 1500-3000 turn transcripts, this adds up.

Also, `find_display_turn/2` (`show.ex:1674-1683`) rebuilds patterns just to process a single turn during edit/cancel.

**Fix options:**
- Split `apply_replacements` so that pattern compilation is separate from application: compile once, apply many
- Cache compiled patterns in the socket assigns and only rebuild when replacements change
- Have `find_display_turn` accept pre-compiled patterns from the socket

### ~~P4: PubSub subscription outside `connected?` guard in `reconnect_transcription`~~ ✅

**File:** `lib/noter_web/live/session_live/show.ex:1480-1527`

`reconnect_transcription/2` subscribes to PubSub and potentially starts a `DynamicSupervisor` child from `mount`, but runs on both static and connected mounts. The static mount process is short-lived, so the subscription is wasted and the SSE client restart is premature.

**Fix:** Wrap the entire `reconnect_transcription` body in a `connected?(socket)` check, or call it only from a connected-mount path.

---

## Correctness

### C1: Jobs callbacks use captured (potentially stale) session struct

**File:** `lib/noter/jobs.ex` — `start_trim/3` (line 40), `start_peaks/1` (line 75), `start_upload_processing/5` (line 107)

In `start_trim/3`, the session is fetched at line 27 and captured in the task closure. After the trim completes (could take minutes), the callback does `Sessions.update_session(session, ...)` using the original struct. If any other process modified the session in the meantime, this update operates on stale data.

Less critical with SQLite single-writer, but matters if the app grows to multi-user.

**Fix:** Re-fetch the session by ID inside the callback before updating:

```elixir
session = Sessions.get_session!(session_id)
Sessions.update_session(session, %{status: "trimmed", ...})
```

### C2: `update_transcription` is not atomic across two DB writes

**File:** `lib/noter/sessions.ex:47-56`

If the first `Repo.update` succeeds and broadcasts, but `apply_campaign_replacements` fails, the session has been updated in the DB without campaign replacements applied. Not wrapped in a transaction.

**Fix options:**
- Wrap both operations in `Repo.transaction/1` or `Ecto.Multi`
- Alternatively, make `apply_campaign_replacements` infallible (log errors but don't fail the pipeline)

### C3: `Sessions.apply_campaign_replacements` does a redundant DB read

**File:** `lib/noter/sessions.ex:59`

```elixir
session = Repo.preload(session, :campaign)
```

The campaign is preloaded here, but `update_transcription` already has a session that may have been preloaded upstream. Passing the campaign through or preloading earlier would avoid the extra query.

**Fix:** Accept the campaign as a parameter, or preload `:campaign` on the session before entering `update_transcription`.

---

## Code Clarity / Structure

### C4: `SessionLive.Show` is 1733 lines

**File:** `lib/noter_web/live/session_live/show.ex`

This module contains mount, render (~860 lines including inline JS hooks), 15+ `handle_event` callbacks, 10+ `handle_info` callbacks, and 10+ private helpers.

**Suggested decomposition:**
- Extract `turn_row/1`, `file_indicator/1` into a `SessionLive.Components` module
- Extract the waveform trim card into its own function component
- Move `format_time/1`, `word_diff/2`, `leading_space/1`, `strip_display_word/1`, `status_badge_class/1` into a shared `NoterWeb.SessionHelpers` module
- Consider splitting review state management (`assign_review_state`, `recompute_review`, `diff_turns`, `stamp_editing_state`, `find_display_turn`, `build_speaker_colors`, `compute_done_stats`) into a `SessionLive.ReviewState` module

### C5: Duplicated `slugify/1` logic

**Files:** `lib/noter/campaigns/campaign.ex:27-41` and `lib/noter/sessions/session.ex:52-66`

Identical `slugify/1` and `generate_slug/1` private functions.

**Fix:** Extract to a shared module (e.g., `Noter.Slug`) with a public `slugify/1` and a changeset helper `generate_slug/2` that takes the changeset and source field.

### C6: Duplicated `status_badge_class/1`

**Files:** `lib/noter_web/live/campaign_live/show.ex:460-466` and `lib/noter_web/live/session_live/show.ex:1094-1100`

Same function with identical logic. Should live in a shared helper module.

### C7: Raw map access on `corrections` without helpers

**File:** `lib/noter/sessions.ex` — throughout

`session.corrections` is accessed with string keys like `Map.get(corrections, "replacements", %{})` and `Map.get(corrections, "edits", %{})` in many places. This is fragile and the string keys are easy to typo.

**Fix:** Add accessor helpers on `Session` or `Sessions`:

```elixir
def replacements(%Session{corrections: c}), do: Map.get(c || %{}, "replacements", %{})
def edits(%Session{corrections: c}), do: Map.get(c || %{}, "edits", %{})
```

This also addresses the nil-safety issue from B2.

### C8: Repeated map-to-rows conversion pattern in `CampaignLive.Show`

**File:** `lib/noter_web/live/campaign_live/show.ex`

The pattern of converting `player_map` / `common_replacements` to row structs with `System.unique_integer` IDs appears 6 times (mount, cancel_edit_player_map, save_player_map, cancel_edit_replacements, save_replacements, import_campaign_replacements).

**Fix:** Extract private helpers:

```elixir
defp player_map_to_rows(player_map) do
  Enum.map(player_map, fn {discord, character} ->
    %{id: System.unique_integer([:positive]), discord: discord, character: character}
  end)
end
```

### C9: `@done_stats != nil` used as proxy for read-only mode

**File:** `lib/noter_web/live/session_live/show.ex:402, 407`

Using `@done_stats != nil` to mean "read-only" is indirect and will confuse future readers.

**Fix:** Add a dedicated `@read_only?` assign derived from session status.

---

## Configuration

### F1: Hardcoded internal server URL in base config

**File:** `config/config.exs:54`

```elixir
config :noter, :transcription_url, "http://tycho.protogen.cloud:8000"
```

This leaks an internal server address into version control in the base config (shared by all environments).

**Fix:** Move to `config/dev.exs` with a comment, and require the env var in production via `runtime.exs`. Or use a localhost placeholder as the base default.

---

## Testing

### T1: "Database busy" SQLite contention in test suite

Intermittent `Exqlite.Error: Database busy` failures appear when running the full test suite with certain seeds (e.g. `--seed 66955`). Multiple async test modules that insert into the `campaigns` table can collide under SQLite's single-writer constraint.

**Affected tests:** `SessionLive.DoneGuardTest`, `SessionLive.NewTest`, `SessionsTest`, `SessionLive.ShowTest`, `UploadsTest` — all fail during setup inserts.

**Fix options:**
- Switch contention-prone test modules to `async: false`
- Configure the SQLite `busy_timeout` in the test repo config (e.g. `busy_timeout: 5000`) to let writers retry instead of failing immediately
- Reduce parallelism with `max_cases` in test config
