# Plan: Extract Banter as a Fact Category

## Context

The fact extractor currently silently discards table talk, jokes, banter, and side conversations. This is lossy — the LLM makes a hard keep/drop decision and borderline content may get lost. By capturing banter as an explicit fact category, we:

1. Make the classification task easier for the LLM (classify, don't decide)
2. Prevent banter from leaking into session notes (filter before writing)
3. Preserve the content for potential future use

## Changes

### 1. Add `banter` to extraction schema — `lib/noter/notes/extractor.ex`

Add `"banter"` to `@extraction_schema`:
- Add to `"required"` list
- Add property with same shape as `events` (array of `{text: string}` objects)

### 2. Update extraction prompt — `lib/noter/notes/prompts.ex`

In `extraction_messages/3`, change the "Exclude table talk..." rule to instead instruct the LLM to capture that content in the `banter` category. Something like:

> Capture table talk, jokes, banter, sarcasm, pop-culture references, out-of-character asides, and side conversations in the `banter` category. Do not include banter content in any other category unless it clearly results in an in-fiction action or party decision.

### 3. Add `banter` to aggregator keys — `lib/noter/notes/aggregator.ex`

Add `"banter"` to `@text_keys` on line 8. This gives us dedup and aggregation for free.

### 4. Filter banter before writing — `lib/noter/notes/pipeline.ex`

On line 77, strip the `"banter"` key from `aggregated` before passing to the writer:

```elixir
aggregated = chunk_facts |> Enum.sort_by(&elem(&1, 0)) |> Aggregator.aggregate()
{_banter, facts_for_writer} = Map.pop(aggregated, "banter", [])
write_and_persist(session, facts_for_writer, context, opts, notify_pid)
```

The `_banter` value is discarded for now. Future work could persist it.

### 5. Tests

- **Aggregator test** (`test/noter/notes/aggregator_test.exs`): Add a test that `banter` items are aggregated and deduped like other text keys. Uses the existing `facts/1` helper.
- **Extractor test** (`test/noter/notes/extractor_test.exs`): Verify `banter` is in the JSON schema sent to the LLM.
- **Pipeline test** (`test/noter/notes/pipeline_test.exs`): Verify banter is stripped from facts before reaching the writer.

## Files to modify

1. `lib/noter/notes/extractor.ex` — add schema field
2. `lib/noter/notes/prompts.ex` — update extraction prompt
3. `lib/noter/notes/aggregator.ex` — add to `@text_keys`
4. `lib/noter/notes/pipeline.ex` — filter before writer
5. `test/noter/notes/aggregator_test.exs` — banter dedup test
6. `test/noter/notes/extractor_test.exs` — schema inclusion test
7. `test/noter/notes/pipeline_test.exs` — banter filtering test

## Verification

1. `mix precommit` — all tests pass, no warnings
2. Review the extraction prompt to ensure the banter instruction is clear and doesn't encourage over-classification
3. Optionally: run the pipeline on an existing session transcript and inspect the extracted banter facts to validate LLM classification quality
