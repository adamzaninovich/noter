defmodule Noter.LLM.Structured do
  @moduledoc """
  Fallback for models without native JSON schema support.
  Appends schema instructions to the system prompt and retries on parse failure.
  """

  require Logger

  alias Noter.LLM.Client

  @max_retries 2

  def call(role, messages, json_schema, opts \\ []) do
    schema_instruction = """
    You MUST respond with valid JSON matching this schema. Output ONLY the JSON, no other text.

    Schema: #{Jason.encode!(json_schema)}
    """

    augmented_messages = append_schema_instruction(messages, schema_instruction)

    attempt(role, augmented_messages, opts, 0)
  end

  defp attempt(_role, _messages, _opts, attempts) when attempts > @max_retries do
    {:error, "Failed to parse JSON after #{@max_retries + 1} attempts"}
  end

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

  defp append_schema_instruction(messages, instruction) do
    case messages do
      [%{role: "system", content: system_content} | rest] ->
        [%{"role" => "system", "content" => system_content <> "\n\n" <> instruction} | rest]

      [%{"role" => "system", "content" => system_content} | rest] ->
        [%{"role" => "system", "content" => system_content <> "\n\n" <> instruction} | rest]

      other ->
        [%{"role" => "system", "content" => instruction} | other]
    end
  end
end
