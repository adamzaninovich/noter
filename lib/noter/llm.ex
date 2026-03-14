defmodule Noter.LLM do
  @moduledoc """
  Thin wrapper over the OpenAI Chat Completions API via Req.
  """

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-4.1"

  @doc """
  Sends a chat completion request.

  Options:
    - `:model` - model ID (default: "gpt-4.1")
    - `:system` - system message string
    - `:response_format` - map for structured output, e.g. `%{type: "json_schema", json_schema: ...}`
    - `:reasoning_effort` - "low" | "medium" | "high" (for reasoning models)

  Returns `{:ok, content_string}` or `{:error, reason}`.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, @default_model)
    api_key = api_key!()

    body =
      %{model: model, messages: messages}
      |> maybe_put(:response_format, Keyword.get(opts, :response_format))
      |> maybe_put(:reasoning_effort, Keyword.get(opts, :reasoning_effort))

    case Req.post("#{@base_url}/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        content =
          body
          |> Map.fetch!("choices")
          |> hd()
          |> get_in(["message", "content"])

        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, "OpenAI API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Like `chat/2` but raises on error.
  """
  def chat!(messages, opts \\ []) do
    case chat(messages, opts) do
      {:ok, content} -> content
      {:error, reason} -> raise "LLM error: #{inspect(reason)}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp api_key! do
    System.get_env("OPENAI_API_KEY") ||
      raise "OPENAI_API_KEY environment variable is not set"
  end
end
