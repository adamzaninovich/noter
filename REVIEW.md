The codebase has improved substantially across all three passes. The aggregator tuple refactor, the `generate_context` `with` chain, the `cross_category_dedupe` cleanup, and the `run_review` error handling are all well done. Here's what I found on this pass.

---

# Code Review — Pass 3

## 1. Elixir Patterns

### 1a. `npcs` and `locations` schemas are identical — should share a module attribute

`extractor.ex:38-61` — same pattern as the `events` duplication you just fixed. The `npcs` and `locations` schemas are structurally identical (`name` + `notes`):

```elixir
# These two blocks are the same structure
"locations" => %{
  "type" => "array",
  "items" => %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["name", "notes"],
    "properties" => %{
      "name" => %{"type" => "string"},
      "notes" => %{"type" => "string"}
    }
  }
},
"npcs" => %{ ... identical ... }
```

Extract a `@named_entity_schema` to match the pattern of `@text_array_schema`.

### 1b. `read_or_default` silently swallows genuine errors

`pipeline.ex:88-89`:
```elixir
defp read_or_default({:ok, content}), do: content
defp read_or_default(_), do: ""
```

`Context.read/1` already returns `{:ok, ""}` for missing files. So the only `{:error, _}` reaching `read_or_default` would be real filesystem failures (permission denied, disk error). Silently defaulting to `""` on a real error masks a problem — the user gets empty context when they should get a diagnostic. Either log the error, or propagate it up into the `with` chain by changing the catch-all to:

```elixir
defp read_or_default({:ok, content}), do: {:ok, content}
defp read_or_default({:error, _} = err), do: err
```

and updating the `with` to match on `{:ok, prev_context} <- read_or_default(...)`.

## 2. Correctness

### 2a. `Jason.decode!` on cached data raises on corrupt cache

`extractor.ex:109`:
```elixir
json -> {:ok, Jason.decode!(json)}
```

If a cached `result` row contains invalid JSON (database corruption, partial write during a crash), `Jason.decode!` raises an unhandled exception. Since this function returns `{:ok, ...} | :miss`, a corrupt cache entry should be treated as a miss rather than crashing:

```elixir
case Repo.one(query) do
  nil -> :miss
  json ->
    case Jason.decode(json) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> :miss
    end
end
```

### 2b. `hd()` on potentially empty `choices` list

`llm.ex:44-46`:
```elixir
resp_body
|> Map.fetch!("choices")
|> hd()
```

If the API returns `"choices": []` (content filtering, safety refusal, billing issue), `hd([])` raises `ArgumentError` with no context. A pattern match gives a clear error:

```elixir
case Map.fetch!(resp_body, "choices") do
  [first | _] -> {:ok, get_in(first, ["message", "content"])}
  [] -> {:error, "OpenAI returned no choices"}
end
```

### 2c. `File.ls!` in `find_previous_session` can raise outside error handling

`session.ex:83`:
```elixir
|> File.ls!()
```

The caller is `Pipeline.generate_context` which uses `with {:ok, prev_dir} <- Session.find_previous_session(...)`. If the parent directory doesn't exist (path typo, moved campaign), `File.ls!` raises `File.Error`, bypassing the `else` clause that expects `{:error, :no_previous_session}`. The pipeline crashes with an ugly stack trace instead of a helpful message. Using `File.ls/1`:

```elixir
case File.ls(parent) do
  {:ok, entries} -> # filter and sort
  {:error, reason} -> {:error, :no_previous_session}
end
```

---

That's it. The remaining issues are narrow — a crash on corrupt cache, a crash on empty API choices, one `File.ls!` that can bypass error handling, one silent error swallow, and one DRY opportunity. The code is clean, functional, and well-structured.
