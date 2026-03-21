# Technical Implementation Plan

See PLAN.md for full feature spec and data model.

## Phase 1 — Data Model & Campaign CRUD ✅

DB schemas, context modules, and campaign management UI.

- Migration: `campaigns` table (name, player_map as JSON)
- Migration: `sessions` table (all columns from PLAN.md)
- `Noter.Campaigns` context — CRUD for campaigns, player map management
- `Noter.Sessions` context — create/update/get sessions, status transitions
- `NoterWeb.CampaignLive.Index` — list campaigns, inline create form
- `NoterWeb.CampaignLive.Show` — edit name, edit player map (add/remove rows), list sessions with status badges
- Routes: `/ → campaigns`, `/campaigns/:id`
- Wire up the home page route to the campaign list

## Phase 2 — File Upload & Rename ✅

Session creation, file uploads, FLAC extraction and renaming.

- `NoterWeb.SessionLive.Show` — session workspace LiveView (step-based UI)
- Upload step: `allow_upload` for zip, AAC, vocab.txt (large file limits for audio)
- On upload complete: extract zip, rename FLACs using campaign player map (reuse `Prep` logic)
- Store files under `priv/uploads/<session_id>/`
- **TODO**: `Uploads.session_dir/1` uses `Application.app_dir(:noter, "priv")` which resolves inside the release bundle. Before deploying, move upload storage to a configurable path outside the release (e.g. an env-driven `NOTER_UPLOADS_DIR`).
- Show uploaded file list with character name mapping
- Transition session status `uploading → uploaded`
- Route: `/campaigns/:campaign_id/sessions/new` and `/campaigns/:campaign_id/sessions/:id`

## Phase 3 — Audio Trimming ✅

Waveform UI for setting trim points, server-side peak generation, ffmpeg clipping with sample-accurate boundaries. Files are 3-4 hours long so browser decoding is not viable — precomputed peaks via `audiowaveform` are used instead.

- Add `ffmpeg` + `audiowaveform` to `flake.nix` buildInputs
- Install wavesurfer.js v7 (npm in assets/)
- Migration: add `duration_seconds` float column to sessions
- `Session` schema: add `duration_seconds` field, cast + validate trim fields (>= 0)
- `Uploads.generate_peaks/1` — ffmpeg mono WAV → audiowaveform JSON, temp file cleanup via `try/after`
- `Uploads.get_duration/1` — ffprobe duration extraction
- `Uploads.trim_session/3` — `precise_clip` using `-ss` + `atrim` filter for sample-accurate trim (re-encodes, no `-c copy`). Clips all renamed FLACs + merged AAC → M4A. Cleans up `trimmed/` on failure
- Persist duration + generate peaks during upload processing (background Task, after `process_uploads`)
- `AudioController` (new) — serves `merged.aac` and `peaks.json` via `send_file`
- Routes: `GET /sessions/:session_id/audio/merged`, `GET /sessions/:session_id/audio/peaks`
- Colocated `.Waveform` JS hook with `phx-update="ignore"`:
  - Loads precomputed peaks JSON, renders via wavesurfer with `peaks: [data]` + `duration`
  - Regions plugin for draggable start/end trim handles (region = audio to keep)
  - Click-to-seek, spacebar play/pause, zoom slider (1–200 minPxPerSec)
  - Preview Start/End buttons: seek to boundary ±3s, play 6s, auto-pause (clears previous timer)
  - Time labels updated locally during drag (`region.on("update")`), synced to LiveView on drag end (`pushEvent("trim_region_updated")`)
  - All dynamic text (current time, trim times, "keeping X of Y") managed entirely by JS in the hook
- LiveView events: `trim_region_updated` (store assigns), `confirm_trim` (spawn Task → `Uploads.trim_session/3`)
- On trim success: status → `trimmed`, trim values persisted. On failure: status stays `uploaded`, error flash, `trimmed/` cleaned up
- Reuses `Prep.find_flac_files/1`, `Prep.resolve_character/2`, `Uploads.session_dir/1`, existing background Task pattern

## Phase 4 — Transcription Service Integration ✅

Send trimmed files to transcription API, stream SSE progress to UI.

**API:** `http://tycho.protogen.cloud:8000` (see `transcription-api-docs.md`)
- `POST /jobs` — multipart `files[]` (one FLAC per speaker + optional vocab.txt) → `{"job_id": "..."}`
- `GET /jobs/{job_id}/events` — SSE stream: `queued` → `file_start` → `progress` (pct 0-100 per file) → `file_done` → `done` (contains full result) or `error`
- `GET /jobs/{job_id}` — polling fallback, returns `{status, result, error}`
- Result object: `{speakers, duration, segments: [{start, end, text, speaker, words}], srt}`
- Overall progress: `(completed_files + current_pct / 100) / total_files * 100`

**Implementation:**
- Config: `:noter, :transcription_url` (default `http://tycho.protogen.cloud:8000`)
- `Noter.Transcription.submit_job/1` — POST trimmed FLACs from `trimmed/` dir + vocab.txt via Req multipart. Returns `{:ok, job_id}`
- `Noter.Transcription.SSEClient` — GenServer that connects to `/jobs/{job_id}/events` via Req streaming, parses SSE lines, broadcasts events via PubSub (`"transcription:#{session_id}"`)
- Session schema already has `transcription_job_id`, `transcript_json`, `transcript_srt` columns
- LiveView "Transcribe" button: submits job, stores `job_id`, sets status `trimmed → transcribing`, starts SSEClient, subscribes to PubSub
- LiveView renders progress UI: current file name, per-file progress bar, overall progress
- On `done` event: store `transcript_json` (JSON-encoded segments) and `transcript_srt` on session, status → `transcribed`
- On `error` event: flash error, status stays `transcribing` (allow retry)
- On page reload during transcription: check `transcription_job_id`, poll `/jobs/{job_id}` for current state, reconnect SSE if still running
- Files to send: trimmed FLACs in `uploads/<session_id>/trimmed/` (filenames are already speaker labels like `Adam.flac`)

## Phase 5a — Transcription Cleanup ✅

Remove SRT storage from transcription ingest; SRT is fully derivable from JSON segments and should only be generated at finalize time.

- Stop saving `transcript_srt` during transcription (SSE `done` handler, poll fallback)
- Clear any existing `transcript_srt` values if desired (migration or manual)
- Verify `transcript_json` contains all necessary data: `segments: [{start, end, text, speaker, words}]`
- Remove any UI that references raw SRT data in the transcription step

## Phase 5b — Transcript Viewer, Audio Playback & Replacements

Scrollable transcript viewer with audio playback and global find-and-replace corrections for TTRPG names/terms.

**Data model:**
- `corrections` map on session schema: `%{"replacements" => %{"Lys" => "Liss", ...}, "edits" => %{...}}`
- Replacements: whole-word, case-insensitive matching, replaces with exact casing as entered
- Persisted to database as changes are made (no separate "save" step) — user can close the page and resume later

**Transcript viewer:**
- Parse `transcript_json` segments into speaker turns (group consecutive same-speaker segments)
- Each turn shows: time range, speaker badge, combined text
- Scrollable list — sessions are 3-4 hours, so the transcript is long
- Replaced words are highlighted (e.g. background color) so corrections are visible in context
- Words have a subtle border on hover; clicking a word opens the replacements panel pre-filled with that word as the "find" value

**Audio playback:**
- Simple HTML `<audio>` element loaded with merged trimmed audio (already served at `/sessions/:id/audio/merged`)
- Each turn has a play/pause button — click to seek to `turn.start` and play, click again to pause
- Auto-stop at `turn.end`; button returns to play state
- No waveform needed — just click-to-hear for verification

**Replacements panel (sidebar):**
- List of find → replace pairs with add/remove
- Show match count per pair across the transcript
- Replacements apply live to the transcript viewer as a preview, with replaced words highlighted
- Whole-word matching only; possessives must be added as separate entries
- On first replacement or edit, transition status `transcribed → reviewing`

## Phase 5c — Per-Turn Editing & Finalize

Inline editing of individual speaker turns and final output generation.

**Per-turn editing:**
- Edit button on any turn → inline text editing of the full turn text
- Edits stored in `corrections.edits` keyed by segment range (e.g. `"0:14"`)
- Edited turns get a visual indicator distinguishing them from replacement-only changes
- Editing a turn means its underlying segments will be merged into one segment in the final JSON (sub-segment timing is lost only for hand-edited turns)

**Finalize & output generation:**
- "Finalize" button applies all corrections to produce final outputs:
  - **JSON**: apply replacements across all segments, merge segments for edited turns with corrected text, preserve original segment granularity for unedited turns
  - **SRT**: generate from corrected JSON, grouped by speaker turn (each entry = one speaker turn with speaker label, readable as a script)
  - `segments_to_srt/1` function builds SRT from corrected segment data
- Store corrected `transcript_json` and generated `transcript_srt` on session
- Transition status `reviewing → done`

## Phase 6 — Download & Polish

Package results into downloadable zip, UI polish.

- Build zip on the fly: trimmed audio, corrected transcripts, vocab
- Serve via controller endpoint (`GET /sessions/:id/download`)
- Session workspace "Done" step shows download button and summary
- Polish: step indicator/breadcrumb in session workspace, loading states, error handling
