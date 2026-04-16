# Plan: Resilient Fact Extraction with Chunk Caching

## Context

The notes extraction pipeline runs LLM calls for each transcript chunk in parallel, but holds all results in memory. If any chunk hangs or fails (e.g., OpenAI API hanging on a structured output request), the entire pipeline dies and all successful chunk results are lost. The LLM client timeout is also 30 minutes per chunk, which is way too long — a single extraction should take under a minute.

**Goal**: Make extraction resumable so retrying only re-extracts failed/missing chunks, and reduce the timeout so hangs fail fast with automatic retry.

## Approach

### 1. Add `chunk_facts` column to sessions table

Store completed extraction results as JSON on the session. Each time a chunk succeeds, persist it immediately.

- New migration: add `chunk_facts` column (`:map`, default `%{}`)
- Update `Session.notes_changeset/2` to cast `chunk_facts`
- Add `Sessions.save_chunk_fact/3` helper that does a targeted update

**Schema shape**: `%{"0" => %{...facts...}, "2" => %{...facts...}}` — string-keyed by chunk index.

### 2. Pipeline resumes from cached chunks

Modify `Pipeline.run_pipeline/3`:
- After chunking, load `session.chunk_facts` (the cached results)
- Filter out chunks whose index already has a cached result
- Only send remaining chunks through `Task.async_stream`
- Merge cached + new results before aggregation
- Update progress tracking to reflect pre-completed chunks

### 3. Lower extraction timeout + per-chunk retry

In `pipeline.ex`, wrap `Extractor.extract/3` with retry logic:
- Set a 3-minute timeout per extraction call (override the client default)
- Retry up to 2 times on timeout/error before giving up on that chunk
- This handles transient OpenAI hangs without losing the whole pipeline

### 4. Clear chunk cache on success

When pipeline completes successfully and notes are saved, clear `chunk_facts` to avoid stale data on future re-runs.

## Files to modify

1. **New migration** — add `chunk_facts :map` to sessions
2. **`lib/noter/sessions/session.ex`** — add field, update `notes_changeset`
3. **`lib/noter/sessions.ex`** — add `save_chunk_fact/3`
4. **`lib/noter/notes/pipeline.ex`** — resume logic, retry wrapper, lower timeout, clear cache on success
5. **`lib/noter/notes/runner.ex`** — update progress init to account for pre-cached chunks

## Verification

- `mix test` — existing pipeline tests should pass
- `mix precommit` — clean compile, no warnings
- Manual test: start notes generation, let some chunks complete, kill the process, retry — should skip completed chunks
