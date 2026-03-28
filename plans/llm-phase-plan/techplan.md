# Session Notes Generation — Tech Plan

## Overview

Replace the external n8n pipeline with an in-app map-reduce pipeline that takes a finalized transcript and campaign context document, and produces polished Markdown session notes using LLM calls. Support both OpenAI and any OpenAI-compatible endpoint (LM Studio, ollama, etc).

As part of this, introduce an app-level settings system to manage LLM provider configuration, transcription service URL, and other operational settings through the UI rather than environment variables.

## Current State

- Transcripts go through: upload → trim → transcribe → review (corrections) → finalize (SRT)
- The finalized transcript with corrections already exists as `session.transcript_json` + `session.corrections`
- `Transcript.apply_corrections/3` produces corrected turns with `{speaker, start, end, text}`
- The n8n corrections dictionary is redundant — our review step already handles this
- Session context is currently a static string manually pasted into n8n
- The n8n pipeline uses GPT-5.2 at two stages: extraction (low effort, parallelized per chunk) and writing (normal effort, single call)
- All app config is currently hardcoded in `config/*.exs` or read from env vars at boot — no runtime-editable settings exist

## Data Model Changes

### Settings (new table)

A key-value settings table for app-wide configuration. Single-row-per-key design — simple, no user accounts to scope to.

```
create table settings (
  id integer primary key,
  key text not null unique,
  value text,              -- JSON-encoded value
  inserted_at utc_datetime,
  updated_at utc_datetime
)
```

Settings managed through this system:

| Key | Type | Description |
|-----|------|-------------|
| `transcription_url` | string | Transcription service endpoint |
| `llm_extraction_base_url` | string | Extraction model API endpoint |
| `llm_extraction_model` | string | Extraction model name |
| `llm_extraction_api_key` | string | Extraction model API key (blank for local) |
| `llm_extraction_temperature` | float | Extraction temperature (null = omit from request, let provider decide) |
| `llm_extraction_max_tokens` | integer | Extraction max tokens (null = omit) |
| `llm_writing_base_url` | string | Writing model API endpoint |
| `llm_writing_model` | string | Writing model name |
| `llm_writing_api_key` | string | Writing model API key (blank for local) |
| `llm_writing_temperature` | float | Writing temperature (null = omit from request) |
| `llm_writing_max_tokens` | integer | Writing max tokens (null = omit) |
| `llm_extraction_concurrency` | integer | Max parallel extraction calls |

All settings start as null. The app redirects to `/settings` if `transcription_url` is not configured.

The `Noter.Settings` context module provides a simple interface:

```elixir
Noter.Settings.get("transcription_url")            # => "http://..."
Noter.Settings.get("transcription_url", "default")  # => with fallback
Noter.Settings.set("transcription_url", "http://...") # => {:ok, setting}
Noter.Settings.all()                                 # => %{"key" => "value", ...}
```

Values are stored as JSON-encoded strings so we can handle strings, integers, booleans, and maps uniformly. The context module handles encoding/decoding.

**Migration path for existing config**: None — all settings start null. On first visit the app redirects to `/settings` until required settings are configured.

### Session

Add fields for notes generation and campaign context:

```
alter table sessions add column context text             -- campaign context document (markdown) for this session
alter table sessions add column session_notes text       -- generated markdown output
alter table sessions add column notes_status text        -- null | generating | done | error
alter table sessions add column notes_error text         -- error message if generation failed
```

The `context` field holds the campaign world document for this specific session. It changes between sessions as the campaign progresses. Not required to create a session — can be added/edited at any time before generating notes. In the future, the app will auto-generate an updated context from the previous session's context + notes, but for now it's manually pasted in.

## Architecture

### Settings System (`Noter.Settings`)

```
Noter.Settings
├── setting.ex       — Ecto schema (key/value)
├── settings.ex      — Context module (get/set/all, JSON encode/decode, defaults)
```

Design decisions:
- **No caching layer initially** — SQLite reads are fast enough for the access patterns here (settings read at job start, not per-request hot path). Can add ETS cache later if needed.
- **No defaults** — all settings start as null on a fresh app. The app redirects to `/settings` if required settings (like `transcription_url`) are not configured. `get/1` returns `nil` for unset keys.
- **No env var override** — settings come from the DB only. The migration seeds from env vars as a one-time import, then env vars are no longer consulted for these keys.
- **Sensitive values (API keys)** — stored in DB as-is. This is a single-user self-hosted app, so DB-level storage is acceptable. The settings UI masks API key display.

### LLM Client (`Noter.LLM`)

A thin wrapper around `Req` that speaks the OpenAI chat completions API. Both OpenAI and LM Studio/ollama expose the same `/v1/chat/completions` endpoint, so one client works for all.

```
Noter.LLM
├── client.ex        — Req-based HTTP client for /v1/chat/completions
└── structured.ex    — JSON schema enforcement (response_format for OpenAI,
                       or parse-and-retry fallback for local models)
```

The client reads its config from `Noter.Settings` at call time:

```elixir
Noter.LLM.Client.chat(:extraction, messages)  # reads llm_extraction_* settings
Noter.LLM.Client.chat(:writing, messages)     # reads llm_writing_* settings
```

Key design decisions:
- Use `Req` (already a dependency) — no new HTTP library needed
- Structured output: use OpenAI's `response_format: {type: "json_schema", ...}` when talking to OpenAI. For local models that may not support it, fall back to prompting for JSON + `Jason.decode!/1` with a retry on parse failure
- Streaming not needed — these are batch calls, we track progress at the chunk level
- Timeouts: extraction calls should be fast (~30s), writing call may take longer (~120s)
- **Optional parameters** (temperature, max_tokens): only included in the API request when set to a non-null value in settings. This lets OpenAI use its own defaults while giving full control when pointing at LM Studio or other local servers.

### Notes Pipeline (`Noter.Notes`)

```
Noter.Notes
├── pipeline.ex      — orchestrates the full pipeline as a background job
├── chunker.ex       — splits corrected turns into time-windowed text blocks
├── extractor.ex     — LLM call per chunk → structured facts JSON
├── aggregator.ex    — pure-code dedup + merge of extracted facts
├── writer.ex        — LLM call: facts JSON → markdown prose
└── prompts.ex       — system/user prompt templates for both LLM stages
```

### Pipeline Flow

```
Session (status: "reviewed")
  │
  ├─ 1. Transcript.apply_corrections(raw_turns, replacements, edits)
  │     → [{speaker, start, end, text}, ...]
  │
  ├─ 2. Chunker.chunk(corrected_turns, chunk_minutes: 10)
  │     → [%{index: 1, range_start: "00:00:00", range_end: "00:10:00", text: "..."}, ...]
  │     Each chunk: deduped, formatted as "[HH:MM:SS] Speaker: text" lines
  │
  ├─ 3. Task.async_stream — for each chunk:
  │     Extractor.extract(chunk, session_context)
  │     → %{events: [...], locations: [...], npcs: [...], ...}
  │     Uses :extraction model settings (cheap/fast)
  │     Concurrency from llm_extraction_concurrency setting
  │     Progress broadcast per completed chunk
  │
  ├─ 4. Aggregator.aggregate(chunk_results)
  │     Pure code — no LLM call
  │     - Text categories: dedup by normalized string
  │     - Named entities (NPCs, locations): merge by name, combine notes
  │     - Cross-category dedup (events vs decisions/combat)
  │     - Sort chronologically by source chunk
  │
  ├─ 5. Writer.write(aggregated_facts, session_context)
  │     Single LLM call with :writing model settings
  │     → markdown string
  │
  └─ 6. Store session_notes, set notes_status = "done"
```

### Background Job Integration

Use the existing `Noter.Jobs` infrastructure (JobRegistry, JobSupervisor, PubSub).

```elixir
# New job type
Noter.Jobs.start_notes_generation(session)
```

Progress broadcasts on `"session:#{session.id}"`:
- `{:notes_progress, %{stage: :extracting, completed: 3, total: 12}}`
- `{:notes_progress, %{stage: :writing}}`
- `{:notes_complete, session}`
- `{:notes_error, reason}`

### Structured Output Schema

Same schema as the n8n workflow, enforced via JSON Schema:

```json
{
  "type": "object",
  "required": ["range", "events", "locations", "npcs", "info_learned",
               "combat", "decisions", "character_moments", "loose_threads",
               "inventory_rewards"],
  "properties": {
    "range": {"type": "string"},
    "events": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "locations": {"type": "array", "items": {"type": "object", "required": ["name", "notes"], "properties": {"name": {"type": "string"}, "notes": {"type": "string"}}}},
    "npcs": {"type": "array", "items": {"type": "object", "required": ["name", "notes"], "properties": {"name": {"type": "string"}, "notes": {"type": "string"}}}},
    "info_learned": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "combat": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "decisions": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "character_moments": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "loose_threads": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    "inventory_rewards": {"type": "array", "items": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}}
  }
}
```

### Prompts

Port directly from the n8n workflow nodes:

**Extraction system prompt**: "You extract structured, transcript-grounded facts from a TTRPG session chunk. You do not write prose notes. You do not invent events. Return valid JSON only."

**Extraction user prompt**: Session context + chunk text + strict rules (no invention, no table talk, omit rather than guess)

**Writing system prompt**: Detailed chronicler instructions — accuracy rules, style rules, omission rules, failsafe

**Writing user prompt**: Session context + aggregated facts JSON + output format template (Summary, Major Events, Locations, NPCs, Info Learned, Combat, Party Decisions, Character Moments, Loose Threads, Inventory/Rewards)

## Phases

### Phase 1: App Settings System DONE

**Goal**: Database-backed settings with UI, replacing env var configuration

1. Migration: create `settings` table (key/value with timestamps)
2. `Noter.Settings.Setting` — Ecto schema
3. `Noter.Settings` — context module with `get/1`, `get/2`, `set/2`, `all/0`
4. Replace `Application.fetch_env!(:noter, :transcription_url)` in `Noter.Transcription` with `Noter.Settings.get("transcription_url")`
5. Remove the `TRANSCRIPTION_URL` env var handling from `runtime.exs` (keep `UPLOADS_DIR` — it stays as env/config)
6. Plug/hook to redirect to `/settings` if `transcription_url` is not configured
7. Settings LiveView page at `/settings`:
   - Grouped sections: "Transcription Service", "LLM — Extraction Model", "LLM — Writing Model"
   - Text inputs for URLs, model names; password-masked inputs for API keys
   - Number input for concurrency
   - Save per-section or all at once
   - "Test Connection" button for transcription URL (GET request to the service)
8. Nav link to settings page
9. Tests: settings context CRUD, redirect when unconfigured

### Phase 2: LLM Client + Data Model DONE

**Goal**: Working LLM client, session context + notes fields, status flow update

1. Migration: add `context`, `session_notes`, `notes_status`, `notes_error` to sessions; rename existing `status: "done"` rows to `"reviewed"`
2. Schema + changeset updates; update `@valid_statuses` to include `"reviewed"` and redefine `"done"` as post-notes
3. `Noter.LLM.Client` — Req-based OpenAI-compatible chat completions client
   - `chat(:extraction | :writing, messages, opts)` — reads settings, makes request, returns `{:ok, content}` or `{:error, reason}`
   - `chat_json(:extraction | :writing, messages, schema, opts)` — structured output variant with JSON schema enforcement + parse-retry fallback
4. "Fetch Models" button for LLM endpoints on settings page — calls `GET /v1/models` on the configured base URL, validates connectivity, and populates the model field as a dropdown with the returned model list
5. Tests: client with Req test adapter/plug, structured output parsing

### Phase 3: Notes Pipeline (Backend) DONE

**Goal**: Full pipeline that takes a session and produces markdown notes

1. `Noter.Notes.Chunker` — time-window splitter
   - Input: corrected turns list
   - Output: list of chunk maps with formatted text
   - Reuse existing `Transcript.apply_corrections/3` for the input
2. `Noter.Notes.Prompts` — prompt templates (ported from n8n)
3. `Noter.Notes.Extractor` — single chunk → facts struct via LLM
4. `Noter.Notes.Aggregator` — merge + dedup logic (pure code, port from n8n)
5. `Noter.Notes.Writer` — facts → markdown via LLM
6. `Noter.Notes.Pipeline` — orchestrator
   - Runs as background job via `Noter.Jobs`
   - `Task.async_stream` for parallel extraction, concurrency from settings
   - Progress broadcasts via PubSub
7. `Noter.Sessions` context functions:
   - `generate_notes/1` — kicks off pipeline
   - `update_notes/2` — stores result
   - `clear_notes/1` — reset for re-generation
8. Tests: chunker, aggregator (pure code), pipeline integration

### Phase 4: UI — Campaign Context + Notes Generation

**Goal**: Session context editing + notes generation trigger + progress + display

1. **Session context editor** (on session show page)
   - Textarea for editing the session's campaign context markdown document
   - Can be added/updated at any time before or after transcript finalization
   - In the future, auto-populated from previous session's context + notes
2. **Session show page — notes step** (visible when status is "reviewed")
   - "Generate Notes" button → kicks off pipeline
   - Progress indicator during generation (chunk X of Y extracting, then writing)
   - Display generated markdown (rendered)
   - "Regenerate" button to re-run
   - Error display with retry
3. **Update download ZIP structure** — download available from `reviewed` or `done`. The ZIP should have this structure:
   ```
   {Campaign} {Session}/
   ├── campaign-context.md          -- session.context (if present)
   ├── {session-name}-notes.md      -- session.session_notes (if present)
   ├── {Campaign} {Session} - Merged.m4a
   ├── tracks/
   │   ├── GM.flac
   │   ├── Kai.flac
   │   └── ...
   ├── transcripts/
   │   ├── merged.json
   │   └── merged.srt
   └── vocab.txt
   ```
   Update `DownloadController` to:
   - Allow download from `reviewed` (not just `done`)
   - Add `campaign-context.md` entry from `session.context`
   - Add `{session-slug}-notes.md` entry from `session.session_notes`
   - Both new files are optional — only included when present

### Phase 5: Context Auto-Update (Future/Optional)

**Goal**: After generating session notes, auto-generate the next session's context document

This mirrors the between-session workflow: take the current session's context + generated notes, and produce an updated context for the next session via a third LLM call. The updated context would be pre-populated on the next session created in the campaign.

Not in initial scope — the user currently does this manually between sessions and can continue to do so via the session context editor.

## Dependencies

No new Hex packages needed:
- `Req` (already included) handles all HTTP to OpenAI / LM Studio
- `Jason` (already included) handles JSON encoding/decoding
- `Task.async_stream` (stdlib) handles parallel extraction

## Resolved Questions

1. **Chunk size**: Fixed at 10 minutes. Working well in the current pipeline.
2. **Re-generation**: Overwrite previous notes. Transcript + context are the source of truth.
3. **Status flow change**: "done" moves to the very end (after notes generation). New status `reviewed` inserted for "transcript finalized, SRT generated." Full flow becomes:

```
uploading → uploaded → trimming → trimmed → transcribing → transcribed → reviewing → reviewed → <writing notes status> → done
```

we need a new status for when its actively writing notes between transcribed and done. not sure what to call that.

- `reviewed` = transcript corrections locked, SRT generated (what "done" means today)
- `done` = notes generated, full pipeline complete
- Notes generation available from `reviewed` status
- Download available from `reviewed` or `done` (includes notes in ZIP when present)
