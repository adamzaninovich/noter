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

## Phase 3 — Audio Trimming

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

## Phase 4 — Transcription Service Integration

Send files to transcription API, stream SSE progress to UI.

- Config: `:noter, :transcription_url`
- `Noter.Transcription` module — POST job with multipart files, parse response
- `Noter.Transcription.SSEClient` — GenServer that connects to SSE endpoint, broadcasts progress via PubSub
- LiveView subscribes to PubSub topic for the job, renders live progress (file name, percentage)
- On `done` event: store `transcript_json` and `transcript_srt` on session
- Transition session status `trimmed → transcribing → transcribed`

## Phase 5 — Transcript Review & Corrections

Inline editing UI for SRT segments, corrections map.

- Parse SRT into list of segments (index, timestamp, speaker, text)
- Render scrollable segment list — each segment has editable text field
- On edit: store correction in session `corrections` map
- Show diff/highlight for corrected segments
- "Finalize" button applies corrections and transitions to `done`
- Transition session status `transcribed → reviewing → done`

## Phase 6 — Download & Polish

Package results into downloadable zip, UI polish.

- Build zip on the fly: trimmed audio, corrected transcripts, vocab
- Apply corrections to SRT and JSON content before writing to zip
- Serve via controller endpoint (`GET /sessions/:id/download`)
- Session workspace "Done" step shows download button and summary
- Polish: step indicator/breadcrumb in session workspace, loading states, error handling
