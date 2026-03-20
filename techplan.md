# Technical Implementation Plan

See PLAN.md for full feature spec and data model.

## Phase 1 — Data Model & Campaign CRUD

DB schemas, context modules, and campaign management UI.

- Migration: `campaigns` table (name, player_map as JSON)
- Migration: `sessions` table (all columns from PLAN.md)
- `Noter.Campaigns` context — CRUD for campaigns, player map management
- `Noter.Sessions` context — create/update/get sessions, status transitions
- `NoterWeb.CampaignLive.Index` — list campaigns, inline create form
- `NoterWeb.CampaignLive.Show` — edit name, edit player map (add/remove rows), list sessions with status badges
- Routes: `/ → campaigns`, `/campaigns/:id`
- Wire up the home page route to the campaign list

## Phase 2 — File Upload & Rename

Session creation, file uploads, FLAC extraction and renaming.

- `NoterWeb.SessionLive.Show` — session workspace LiveView (step-based UI)
- Upload step: `allow_upload` for zip, AAC, vocab.txt (large file limits for audio)
- On upload complete: extract zip, rename FLACs using campaign player map (reuse `Prep` logic)
- Store files under `priv/uploads/<session_id>/`
- Show uploaded file list with character name mapping
- Transition session status `uploading → uploaded`
- Route: `/campaigns/:campaign_id/sessions/new` and `/campaigns/:campaign_id/sessions/:id`

## Phase 3 — Audio Trimming

Waveform UI for setting trim points, ffmpeg clipping.

- Install wavesurfer.js (npm in assets/)
- `phx-hook` for waveform player — load merged AAC, region selection for start/end
- Push trim timestamps to server via `phx-submit` or `pushEvent`
- Server: store `trim_start_seconds` / `trim_end_seconds` on session
- On confirm: run ffmpeg to clip all FLACs and convert merged AAC → M4A
- Store trimmed files under `priv/uploads/<session_id>/trimmed/`
- Transition session status `uploaded → trimmed`

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
