# noter — Session Processing Web App

Phoenix LiveView application for processing TTRPG session recordings: upload
multitrack audio, trim, transcribe via external service, review/correct
transcripts, and download a packaged result.

## Workflow

```
1. Select/create campaign (player mapping lives in DB)
2. Create new session → upload zip of per-player FLACs + merged AAC + vocab.txt
3. Rename FLACs: discord usernames → character names via campaign player map
4. Trim audio: waveform UI on merged AAC to set start/end, apply to all FLACs
5. Transcribe: send trimmed files + vocab to transcription service, stream progress
6. Review: inspect SRT/JSON transcripts, make corrections
7. Download: zip of trimmed audio, corrected transcripts, vocab
```

## Data Model

### campaigns

| Column       | Type    | Notes                               |
|--------------|---------|-------------------------------------|
| id           | integer | PK                                  |
| name         | string  | e.g. "Stonewalkers"                 |
| player_map   | map     | `%{"discord_name" => "Character"}`  |
| inserted_at  | utc_dt  |                                     |
| updated_at   | utc_dt  |                                     |

### sessions

| Column              | Type    | Notes                                         |
|---------------------|---------|-----------------------------------------------|
| id                  | integer | PK                                            |
| campaign_id         | integer | FK → campaigns                                |
| name                | string  | e.g. "Session 3"                              |
| status              | string  | `uploading` → `uploaded` → `trimmed` → `transcribing` → `transcribed` → `reviewing` → `done` |
| trim_start_seconds  | float   | set during trim step                          |
| trim_end_seconds    | float   | set during trim step                          |
| transcription_job_id| string  | from transcription service                    |
| transcript_json     | text    | raw JSON result from transcription service    |
| transcript_srt      | text    | raw SRT result from transcription service     |
| corrections         | map     | `%{"wrong" => "right"}` applied during review |
| inserted_at         | utc_dt  |                                                |
| updated_at          | utc_dt  |                                                |

Uploaded files (zip, AAC, vocab, individual FLACs) are stored on disk under
`priv/uploads/<session_id>/`. Trimmed files go under
`priv/uploads/<session_id>/trimmed/`.

## Pages / LiveViews

### Campaign management
- `GET /` — list campaigns, create new
- `GET /campaigns/:id` — edit campaign (name, player map), list sessions

### Session workflow (single LiveView with step navigation)
- `GET /campaigns/:campaign_id/sessions/new` — create session + upload files
- `GET /campaigns/:campaign_id/sessions/:id` — session workspace

The session workspace is a single LiveView that walks through the workflow
steps. Each step is a component rendered based on `session.status`:

1. **Upload** — drag-and-drop zip + AAC + vocab.txt, extract zip, rename FLACs
2. **Trim** — waveform player for merged AAC, set start/end, apply trim to all files
3. **Transcribe** — kick off job, show live SSE progress
4. **Review** — scrollable SRT with inline editing, corrections map
5. **Done** — download button

## Key Implementation Details

### File handling
- Uploads use `allow_upload` with `:live_file_input` — zip, AAC, and vocab
- On upload complete: extract zip, identify FLAC files, rename using campaign
  player map, store in session upload dir
- Trimming calls ffmpeg to clip all FLACs and convert the merged AAC to M4A

### Audio trimming UI
- Use a JS audio waveform library (wavesurfer.js) via phx-hook
- Load the merged AAC file, let user drag/click to set start and end markers
- Push start/end times to server, server stores on session record
- When confirmed, run ffmpeg to clip all files server-side

### Transcription
- POST trimmed FLAC files + vocab.txt to `POST /jobs` on the transcription service
- Connect to `GET /jobs/{job_id}/events` SSE stream from the server (Elixir process)
- Broadcast progress events via PubSub to the LiveView
- On `done` event, store result JSON and SRT on the session record

### Transcript review
- Render SRT segments in a scrollable list
- Each segment shows timestamp, speaker, text — text is editable inline
- Corrections accumulate in the session's corrections map
- Apply corrections to both SRT and JSON before download

### Download
- Build zip on the fly containing:
  ```
  <Campaign> <Session>/
  ├── <Campaign> <Session> Merged.m4a
  ├── tracks/
  │   ├── GM.flac
  │   ├── Kai.flac
  │   └── ...
  ├── transcripts/
  │   ├── merged.json
  │   └── merged.srt
  └── vocab.txt
  ```
- Corrections are applied to transcript files in the zip

### Transcription service
- Base URL configured in app config (e.g. `config :noter, :transcription_url`)
- See `transcription-api-docs.md` for full API spec

## Dependencies

Already have:
- `phoenix`, `phoenix_live_view`, `ecto_sqlite3`, `req`, `jason`

Need to add:
- wavesurfer.js (npm, for audio waveform UI)

## Future work (out of scope now)

- LLM pipeline: chunking → fact extraction → aggregation → note writing
- Campaign context generation across sessions
- These would slot in after the review step, adding a "Process" step before "Done"
- The final download zip would then also include context.md and session notes
