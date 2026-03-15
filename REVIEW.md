Good improvements across the board. The previous high-priority issues are all resolved. Here's what remains.

---

# Code Review — Pass 2

## 1. Elixir Patterns

### 1a. `events` schema inlined instead of reusing `@text_array_schema`

`extractor.ex:37-45` defines the `events` property inline:

```elixir
"events" => %{
  "type" => "array",
  "items" => %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["text"],
    "properties" => %{"text" => %{"type" => "string"}}
  }
},
```

This is byte-for-byte identical to `@text_array_schema` defined at line 10. Should just be `"events" => @text_array_schema` like the other text categories at lines 70-75. If the schema ever changes (e.g., adding a `"confidence"` field), you'd update the module attribute and miss the inline copy.

**FIXED**: Replaced inline schema with `@text_array_schema` reference.

### 1b. `and` in non-guard contexts

`chunker.ex:52-53` and `chunker.ex:64-65` still use `and`:

```elixir
s.start >= window_start and s.start < window_end
```

Line 34 was correctly updated to `&&`, but these were missed. `and` is functionally equivalent here since both operands are always boolean, but `&&` is conventional in non-guard contexts.

**FIXED**: Changed remaining `and` to `&&` in both filter expressions.

### 1c. Piping into `case` in `extract_all`

`pipeline.ex:114-117`:
```elixir
|> case do
  {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
  error -> error
end
```

Piping into `case` works but is flagged by Credo and reads awkwardly — the reader has to mentally shift from "data flowing through a pipeline" to "branching on the shape of the accumulator." Binding to a variable first is clearer:

```elixir
result =
  chunks
  |> Task.async_stream(...)
  |> Enum.reduce_while(...)

case result do
  {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
  error -> error
end
```

**FIXED**: Bound reduce result to `result` variable, then `case` on it.

### 1d. `generate_context/2` mixes four control flow styles

`pipeline.ex:51-87` uses `case` → two `case` → `if` → `with` in a single function. The core intent is:

1. Find the previous session
2. Load its context and notes (defaulting to "")
3. If both are empty, write empty context
4. Otherwise, generate from previous

A `with` chain that normalizes all the "missing is empty" cases would read as a single flow:

```elixir
def generate_context(session_dir, opts \\ []) do
  session_dir = Path.expand(session_dir)

  with {:ok, prev_dir} <- Session.find_previous_session(session_dir),
       {:ok, prev_context} <- Context.read(prev_dir),
       {:ok, prev_notes} <- read_prev_notes(prev_dir),
       false <- prev_context == "" and prev_notes == "" do
    IO.puts("Generating campaign context from previous session...")
    # ... generate and write
  else
    {:error, :no_previous_session} -> write_empty_context(session_dir)
    true -> write_empty_context(session_dir)  # both empty
  end
end
```

This is a style suggestion — the current version is correct, just harder to trace.

**FIXED**: Refactored to single `with` chain with tagged `{:has_input, bool}` clause. Extracted `write_empty_context/1` and `read_or_default/1` helpers.

### 1e. Variable shadowing in `extract_srt_words`

`corrections.ex:66-67`:
```elixir
|> Enum.reject(fn line ->
  line = String.trim(line)
```

The parameter `line` is immediately rebound to a trimmed version. This shadows the original and can trip up a reader expecting the raw value. Prefer a distinct name like `trimmed`.

**FIXED**: Renamed to `trimmed`. Also changed `or` to `||` for consistency.

### 1f. `put_present` still duplicated across modules

`llm.ex:78-79` operates on maps, `run.ex:127-128` operates on keyword lists. Same name, different data structures, defined twice. This is a minor DRY issue — extracting to a shared helper isn't worth it for two usages, but the identical naming across modules could confuse a reader grepping the codebase. At minimum, the Keyword list version could use `Keyword.put_new/3` or just inline the conditional:

```elixir
llm_opts =
  opts
  |> Enum.filter(fn {k, _} -> k in [:model, :chunk_minutes] end)
  |> Enum.reject(fn {_, v} -> is_nil(v) end)
```

Though this is borderline — two private helpers with the same name in different modules is common enough.

**FIXED**: Removed `put_present` from `run.ex` entirely. Replaced with inline `Enum.reject` to filter nil values from the opts keyword list. `put_present` in `llm.ex` (map version) remains as the sole definition.

---

## 2. Correctness

### 2a. `get_cached`/`cache_result` parameter named `session_path` but receives a basename

`extractor.ex:88`:
```elixir
session_key = Path.basename(session_path)
```

Good fix — the cache now uses the basename. But `get_cached/3` and `cache_result/4` at lines 106 and 121 still name their first parameter `session_path`:

```elixir
defp get_cached(session_path, chunk_index, hash) do
```

This is misleading. The value is now a basename like `"session-3"`, not a path. Renaming to `session_key` (matching line 88) would prevent future confusion where someone passes a full path thinking that's what's expected.

**FIXED**: Renamed parameter to `session_key` in both `get_cached/3` and `cache_result/4`. Updated `@doc` on `extract/4`.

### 2b. `Aggregator.cross_category_dedupe` has defensive `is_map` checks

`aggregator.ex:125` and `132`:
```elixir
text = if is_map(entry), do: Map.get(entry, "text"), else: nil
```

By the time `cross_category_dedupe` runs (line 44-45), text categories have been unwrapped to plain maps (line 53: `Enum.map(fn {_range, entry} -> entry end)`). Entries will always be maps at this point. The `is_map` guard suggests uncertainty about the data flow. If the upstream shape is guaranteed (which it is), this should just be `Map.get(entry, "text")`. If you're not confident, the safer solution is a type/shape assertion earlier in the pipeline rather than defensive checks at every call site.

**FIXED**: Replaced `is_map` guards with direct `Map.get(entry, "text")` via `case` expressions.

### 2c. `Aggregator.merge_named` still mixes tracking state into the data map

`aggregator.ex:95`:
```elixir
empty = %{"name" => String.trim(name), "notes" => [], "notes_seen" => MapSet.new()}
```

The `notes_seen` tracking state lives alongside `"name"` and `"notes"` in the same map. It's cleanly stripped on line 102-103 when constructing the output. This is much better than the `_range_*` approach was — the data never leaves the function. But structurally, it would be cleaner as a tuple:

```elixir
# {display_name, notes_list, seen_set}
{"Tarra", [], MapSet.new()}
```

This eliminates the risk of a future refactor accidentally leaking `notes_seen` into the output. Minor, since the current code is correct and contained within a single private function.

**FIXED**: Refactored to use `{name, notes_list, seen_set}` tuples. `add_note/2` now operates on tuples. No tracking state in data maps.

### 2d. `Session.extract_session_number` returns 0 for non-numeric directories

`session.ex:96-99`:
```elixir
defp extract_session_number(name) do
  case Regex.run(~r/(\d+)$/, name) do
    [_, n] -> String.to_integer(n)
    _ -> 0
  end
end
```

If the campaign directory contains non-session directories (e.g., `notes`, `archive`, `.git`), they all get session number `0` and pass through the `< current_num` filter (since `0 < N` for any session). They'd then be candidates for "previous session." `List.last` would pick the one that sorts highest among the `0`-group, which would be whichever directory name sorts highest by numeric extraction — but they're all `0`, so `Enum.sort_by` is stable and they'd appear in their original order.

The practical impact: if `session-1` doesn't exist but `archive/` does, `find_previous_session("session-2")` would return `{:ok, "/path/to/archive"}`, and the pipeline would fail later when looking for `merged.json`. The failure would be confusing. A stricter filter that only considers directories matching a session pattern (e.g., `Regex.match?(~r/session-\d+$/, name)`) would prevent this.

**FIXED**: Added `session_dir?/1` guard that requires directory names to end with `-\d+` pattern (e.g., `session-3`). Non-session directories like `archive`, `.git` are now excluded.

---

## 3. Usability

### 3a. `File.write!` in `Pipeline.run` can crash without context

`pipeline.ex:41`:
```elixir
File.write!(notes_path, notes)
```

After the entire pipeline succeeds (LLM calls, extraction, aggregation, writing), if the final `File.write!` fails (permissions, disk full), it raises a raw `File.Error` with no context about what was being written. Since the user just waited through a potentially expensive pipeline, losing the output silently is painful. Either wrap in a `case` that includes the notes content in the error, or at minimum catch and suggest the user check the path.

**FIXED**: Replaced `File.write!` with `File.write` + `case` that returns a descriptive `{:error, ...}` message including the path and formatted error reason.

### 3b. `Corrections.find_unknown_terms` uses `File.read!`

`corrections.ex:19`:
```elixir
|> File.read!()
```

The caller (`run.ex:92`) checks `File.exists?(srt_path)` first, so this works in practice. But there's a TOCTOU gap — and if a future caller skips the existence check, the crash is unhandled. For a CLI tool this is acceptable, but using `File.read/1` with error propagation would be more robust.

**FIXED**: Changed to `File.read/1`. Function now returns `{:ok, terms}` or `{:error, reason}`. Updated caller in `run.ex`.

### 3c. `run_review` pattern-matches `{:ok, ...}` without handling errors

`run.ex:93-94`:
```elixir
{:ok, vocab} = Noter.Campaign.load_vocab(Path.join(session_dir, "tracks"))
{:ok, corrections} = Noter.Campaign.load_corrections(campaign_dir)
```

If either call returns `{:error, reason}` (e.g., corrupted TOML file), this raises a `MatchError` with a confusing stack trace. A `case` or `with` that calls `Mix.raise` with a human-readable message would be friendlier.

**FIXED**: Wrapped in `with` chain with `else` clause that calls `Mix.raise` with a readable message.

---

## Summary

All issues from pass 2 have been fixed.

| Priority | Issue | Location | Status |
|----------|-------|----------|--------|
| **Medium** | `events` schema duplicated instead of using `@text_array_schema` | `extractor.ex:37-45` | **FIXED** |
| **Medium** | `session_path` param name misleading after basename change | `extractor.ex:106,121` | **FIXED** |
| **Medium** | Non-session dirs could be picked as "previous session" | `session.ex:84-87` | **FIXED** |
| **Low** | `and` in non-guard contexts (3 remaining) | `chunker.ex:52-53,64-65` | **FIXED** |
| **Low** | Pipe into `case` | `pipeline.ex:114` | **FIXED** |
| **Low** | `File.write!` after expensive pipeline with no recovery | `pipeline.ex:41` | **FIXED** |
| **Low** | Variable shadowing in `extract_srt_words` | `corrections.ex:66-67` | **FIXED** |
| **Low** | Bare `{:ok, _} =` matches in `run_review` | `run.ex:93-94` | **FIXED** |
| **Low** | `is_map` defensive checks on known-good data | `aggregator.ex:125,132` | **FIXED** |
| **Low** | `generate_context` mixes control flow styles | `pipeline.ex:51-87` | **FIXED** |
