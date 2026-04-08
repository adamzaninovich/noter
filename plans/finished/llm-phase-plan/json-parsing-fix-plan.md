# Plan: Fix JSON Parsing and Error Logging

## Problem

1. The LLM is returning JSON wrapped in markdown code fences (` ```json ... ``` `)
2. The current `strip_markdown_fences` regex is too brittle - doesn't handle extra whitespace, multiple newlines, or other variations
3. When parsing fails, the fallback path (`structured_fallback`) uses `Client.chat` directly and tries `Jason.decode` without any stripping
4. Errors are logged at WARNING level instead of ERROR, hiding the issue

## Goal

- Robustly extract JSON from LLM responses regardless of what text surrounds it
- Log at ERROR level when parsing fails so issues are visible
- Single location for parsing logic (Client module)

## Changes

### 1. `lib/noter/llm/client.ex` - `strip_to_json/1`

Replace `strip_markdown_fences/1` with a simpler, more robust approach:

```elixir
defp strip_to_json(content) do
  content
  |> String.trim()
  |> then(fn c ->
    first_brace = String.index(c, "{")
    last_brace = String.last_index(c, "}")

    if first_brace && last_brace && last_brace > first_brace do
      String.slice(c, first_brace..last_brace)
    else
      c
    end
  end)
  |> String.trim()
end
```

This strips everything before the first `{` and after the last `}` - works for any pre/post content.

### 2. `lib/noter/llm/client.ex` - `chat_json/4`

Update to use `strip_to_json/1` and log errors properly:

```elixir
def chat_json(role, messages, json_schema, opts \\ []) when role in [:extraction, :writing] do
  with {:ok, config} <- load_config(role) do
    case do_chat_json_request(config, messages, json_schema, opts) do
      {:ok, content} ->
        stripped = strip_to_json(content)

        case Jason.decode(stripped) do
          {:ok, parsed} ->
            {:ok, parsed}

          {:error, decode_error} ->
            Logger.error(
              "LLM returned unparseable JSON after stripping. " <>
                "raw_content=#{inspect(content, limit: :infinity, printable_limit: :infinity)} " <>
                "stripped=#{inspect(stripped)} " <>
                "error=#{inspect(decode_error)}"
            )

            structured_fallback(role, messages, json_schema, content, opts)
        end

      {:error, {:api_error, status, body}} when status in [400, 404, 422, 500] ->
        Logger.error(
          "LLM API error (HTTP #{status}): #{inspect(body)}. Using structured fallback."
        )

        Structured.call(role, messages, json_schema, opts)

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end
end
```

### 3. `lib/noter/llm/client.ex` - `structured_fallback/5`

Log at ERROR level:

```elixir
defp structured_fallback(role, messages, json_schema, original_content, opts) do
  Logger.error(
    "Using structured fallback after initial parse failure. " <>
      "original_content=#{inspect(original_content, limit: :infinity, printable_limit: :infinity)}"
  )

  Structured.call(role, messages, json_schema, opts)
end
```

### 4. `lib/noter/llm/structured.ex` - `attempt/4`

Use `Client.parse_json/1` (to be created) so all parsing happens in Client:

```elixir
defp attempt(role, messages, opts, attempts) do
  case Client.chat(role, messages, opts) do
    {:ok, content} ->
      case Client.parse_json(content) do
        {:ok, parsed} ->
          {:ok, parsed}

          {:error, decode_error} ->
            Logger.error(
              "Structured fallback decode failed. " <>
                "attempt=#{attempts + 1} " <>
                "content=#{inspect(content, limit: :infinity, printable_limit: :infinity)} " <>
                "error=#{inspect(decode_error)}"
            )

          retry_messages =
            messages ++
              [
                %{"role" => "assistant", "content" => content},
                %{
                  "role" => "user",
                  "content" =>
                    "That was not valid JSON. Please respond with ONLY valid JSON, no markdown fences or other text."
                }
              ]

          attempt(role, retry_messages, opts, attempts + 1)
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

### 5. `lib/noter/llm/client.ex` - Add `parse_json/1`

Public function so Structured can use it:

```elixir
def parse_json(content) do
  stripped = strip_to_json(content)

  case Jason.decode(stripped) do
    {:ok, parsed} -> {:ok, parsed}
    {:error, error} -> {:error, error}
  end
end
```

## Summary of Changes

| File | Change |
|------|--------|
| `client.ex` | Replace `strip_markdown_fences` with `strip_to_json` (first `{` to last `}`) |
| `client.ex` | Add public `parse_json/1` function for use by Structured |
| `client.ex` | Update `chat_json/4` to use `strip_to_json` and log errors at ERROR level |
| `client.ex` | Update `structured_fallback/5` to log at ERROR level |
| `structured.ex` | Use `Client.parse_json/1` instead of `Jason.decode/1` directly |
| `structured.ex` | Update error messages and include full content in logs |

## DaisyUI Components

None needed - this is a backend fix only.

## Verification

1. `mix precommit` passes
2. LLM calls that previously triggered "Structured fallback" warnings should now work directly
3. If fallback is still triggered, error logs should show exactly what the LLM returned
