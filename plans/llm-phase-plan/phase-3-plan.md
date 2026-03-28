# Phase 3: Notes Pipeline (Backend)

## Context

The noter app processes TTRPG session recordings through upload → trim → transcribe → review → finalize. Phases 1-2 added a settings system and LLM client. Phase 3 builds the notes generation pipeline: take a finalized transcript + campaign context, extract structured facts via parallel LLM calls, merge/dedup them, then produce markdown session notes via a second LLM call. This replaces an external n8n workflow.

## New Files

All under `lib/noter/notes/`:

### 1. `chunker.ex` — Pure function, no deps

```elixir
def chunk_turns(corrected_turns, window_seconds \\ 600)
  :: [%{index: int, range_start: String.t(), range_end: String.t(), text: String.t()}]
```

- Input: output of `Transcript.apply_corrections/3` — list of `%{speaker, start, end, text}`
- Window from first turn's `start` to last turn's `end` in `window_seconds` intervals
- Format each turn as `[HH:MM:SS] Speaker: text`, dedup identical lines per chunk
- Skip empty windows, 0-based index
- `range_start`/`range_end` as `"HH:MM:SS"` strings

### 2. `prompts.ex` — Pure function, no deps

```elixir
def extraction_messages(chunk_text, chunk_range, context) :: [map()]
def writing_messages(aggregated_facts, context) :: [map()]
```

- Returns lists of `%{"role" => ..., "content" => ...}` maps (string keys)
- Port prompts verbatim from n8n workflow (`plans/llm-phase-plan/Process Transcript.json`):
  - **Extraction system**: fact extractor persona
  - **Extraction user**: context + chunk text + range + strict rules
  - **Writing system**: chronicler persona with accuracy/style/omission/failsafe rules
  - **Writing user**: context + JSON-encoded facts + output template (Summary, Major Events, Locations, NPCs, Info Learned, Combat, Decisions, Character Moments, Loose Threads, Inventory/Rewards)

### 3. `extractor.ex` — Depends on Prompts, LLM.Client

```elixir
def extract(chunk, context, opts \\ []) :: {:ok, map()} | {:error, String.t()}
```

- Module attribute `@extraction_schema` holds the JSON schema (from n8n's Output Schema node)
- Calls `Prompts.extraction_messages/3` then `Client.chat_json(:extraction, messages, @extraction_schema, opts)`
- `opts` passed through for test plug injection

### 4. `aggregator.ex` — Pure function, no deps

```elixir
def aggregate(chunk_facts) :: map()
```

- Input: list of `{chunk_index, facts_map}` tuples, ordered by index
- Port logic from n8n's "Aggregate Facts" JavaScript node:
  - **Text categories** (events, info_learned, combat, decisions, character_moments, loose_threads, inventory_rewards): dedup by `normalize(text)` (trim + downcase + strip punctuation + collapse whitespace), preserve first occurrence casing
  - **Named entities** (npcs, locations): merge by `normalize(name)`, combine notes (dedup notes too), keep first name casing
  - **Cross-category dedup**: remove from `decisions` anything in `events`; remove from `combat` anything in `events`

### 5. `writer.ex` — Depends on Prompts, LLM.Client

```elixir
def write(aggregated_facts, context, opts \\ []) :: {:ok, String.t()} | {:error, String.t()}
```

- Calls `Prompts.writing_messages/2` then `Client.chat(:writing, messages, opts)` (plain chat, output is markdown)

### 6. `pipeline.ex` — Orchestrator, depends on all above

```elixir
def run(session_id, opts \\ [])
```

Steps:
1. Fetch session, validate `Session.finalized?/1`
2. Set `notes_status: "running"`, clear `notes_error`
3. `Transcript.parse_turns/1` → `Transcript.apply_corrections/3` → `Chunker.chunk_turns/1`
4. `Task.async_stream` over chunks with `Extractor.extract/3`, concurrency from `Settings.get("llm_extraction_concurrency", 4)`, `timeout: :infinity`, `ordered: true`
5. Broadcast `{:notes_progress, %{stage: :extracting, completed: n, total: total}}` per chunk
6. On any extraction failure → abort, set error state
7. `Aggregator.aggregate/1`
8. `Writer.write/3`
9. Success: `update_session_notes(session, %{notes_status: "complete", session_notes: markdown})` then `update_session(session, %{status: "done"})`, broadcast `{:notes_progress, %{stage: :complete}}`
10. Failure: `update_session_notes(session, %{notes_status: "error", notes_error: reason})`, broadcast `{:notes_progress, %{stage: :error, error: reason}}`
11. Wrap entire body in `try/rescue` for unexpected crashes

## Modified Files

### `lib/noter/jobs.ex` — Add `start_notes_generation/2`

```elixir
def start_notes_generation(session, opts \\ [])
```

Follow existing pattern (check `running?/2`, register in `JobRegistry`, start via `Task.Supervisor`). Pass `opts` through to `Pipeline.run/2` for test plug injection.

## Implementation Order

1. **Chunker** + **Prompts** + **Aggregator** (parallel — all pure, no deps)
2. **Extractor** + **Writer** (parallel — both depend on Prompts + Client)
3. **Pipeline** (depends on all above)
4. **Jobs.start_notes_generation** (small addition to existing file)

## Tests

| File | Type | Key Cases |
|------|------|-----------|
| `test/noter/notes/chunker_test.exs` | `ExUnit.Case, async: true` | Empty turns, single window, multi-window, gap skipping, dedup, timestamp formatting, custom window size |
| `test/noter/notes/prompts_test.exs` | `ExUnit.Case, async: true` | Messages have string keys, context included/omitted, chunk text present, facts JSON-encoded |
| `test/noter/notes/aggregator_test.exs` | `ExUnit.Case, async: true` | Text dedup, named entity merge, cross-category dedup, empty arrays preserved, order by chunk |
| `test/noter/notes/extractor_test.exs` | `DataCase, async: false` | Success via Req plug, error handling, schema sent in request |
| `test/noter/notes/writer_test.exs` | `DataCase, async: false` | Success via Req plug, error handling |
| `test/noter/notes/pipeline_test.exs` | `DataCase, async: false` | Full success (session → "done"), extraction failure → error state, writing failure → error state, progress broadcasts received |

Pipeline tests: create a session with `status: "reviewed"`, `transcript_json`, and `corrections`. Use Req plug that returns extraction JSON for requests with `response_format` and markdown for plain chat requests.

## Verification

1. `mix precommit` — all tests pass, no credo/format issues
2. Manual test against running LLM server:
   - Create a session, transcribe, review, finalize to "reviewed"
   - Add campaign context
   - Call `Jobs.start_notes_generation(session)` from Tidewave
   - Verify `session.notes_status` transitions: running → complete
   - Verify `session.session_notes` contains markdown
   - Verify `session.status` is "done"
