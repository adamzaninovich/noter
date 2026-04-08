defmodule Noter.LLM.Client do
  @moduledoc """
  OpenAI-compatible LLM client.
  Uses Chat Completions (`/v1/chat/completions`) for both plain text and
  structured JSON output (via `response_format: json_schema`).
  """

  require Logger

  alias Noter.LLM.Structured
  alias Noter.Settings

  @default_timeouts %{extraction: 1_800_000, writing: 1_800_000}

  def chat(role, messages, opts \\ []) when role in [:extraction, :writing] do
    with {:ok, config} <- load_config(role) do
      body =
        build_chat_body(config, messages)
        |> put_if("max_tokens", config.max_tokens)

      case do_request(config, body, opts) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def chat_json(role, messages, json_schema, opts \\ []) when role in [:extraction, :writing] do
    with {:ok, config} <- load_config(role) do
      case do_chat_json_request(config, messages, json_schema, opts) do
        {:ok, content} ->
          content
          |> strip_markdown_fences()
          |> Jason.decode()
          |> case do
            {:ok, parsed} -> {:ok, parsed}
            {:error, _} -> structured_fallback(role, messages, json_schema, content, opts)
          end

        {:error, {:api_error, status, body}} when status in [400, 404, 422, 500] ->
          Logger.warning(
            "Chat Completions JSON failed (HTTP #{status}): #{inspect(body)}, using structured fallback"
          )

          Structured.call(role, messages, json_schema, opts)

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  defp structured_fallback(role, messages, json_schema, original_content, opts) do
    Logger.warning(
      "Chat Completions returned unparseable JSON, using structured fallback: " <>
        inspect(String.slice(original_content, 0..200))
    )

    Structured.call(role, messages, json_schema, opts)
  end

  defp do_chat_json_request(config, messages, json_schema, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeouts[config.role])

    body =
      %{
        model: config.model,
        messages: messages,
        response_format: %{
          type: "json_schema",
          json_schema: %{name: "response", strict: true, schema: json_schema}
        }
      }
      |> put_if("temperature", config.temperature)

    req_opts =
      [
        url: "#{config.base_url}/chat/completions",
        method: :post,
        json: body,
        headers: auth_headers(config.api_key),
        receive_timeout: timeout,
        pool_timeout: timeout,
        retry: false
      ]
      |> maybe_put_plug(opts)

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => message} | _]}}} ->
        extract_content(message)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp extract_content(message) do
    case message do
      %{"content" => c} when is_binary(c) and c != "" -> {:ok, c}
      %{"reasoning_content" => c} when is_binary(c) and c != "" -> {:ok, c}
      _ -> {:error, {:api_error, 200, "No content in response"}}
    end
  end

  defp strip_markdown_fences(content) do
    content = String.trim(content)

    if String.starts_with?(content, "```") do
      content
      |> String.replace(~r/\A```(?:json)?\n?/, "")
      |> String.replace(~r/\n?```\z/, "")
      |> String.trim()
    else
      content
    end
  end

  def list_models(role, opts \\ []) when role in [:extraction, :writing] do
    with {:ok, config} <- load_config(role) do
      req_opts =
        [
          url: "#{config.base_url}/models",
          method: :get,
          headers: auth_headers(config.api_key),
          receive_timeout: 10_000,
          retry: false
        ]
        |> maybe_put_plug(opts)

      case Req.request(req_opts) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          ids = models |> Enum.map(& &1["id"]) |> Enum.sort()
          {:ok, ids}

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, exception} ->
          {:error, "Request failed: #{Exception.message(exception)}"}
      end
    end
  end

  defp load_config(role) do
    prefix = "llm_#{role}"
    base_url = Settings.get("#{prefix}_base_url")

    if is_nil(base_url) or base_url == "" do
      {:error, "#{prefix}_base_url is not configured"}
    else
      max_tokens =
        case role do
          :writing -> Settings.get("#{prefix}_max_tokens")
          _ -> nil
        end

      {:ok,
       %{
         base_url: base_url,
         model: Settings.get("#{prefix}_model"),
         api_key: Settings.get("#{prefix}_api_key"),
         temperature: Settings.get("#{prefix}_temperature"),
         max_tokens: max_tokens,
         role: role
       }}
    end
  end

  defp build_chat_body(config, messages) do
    %{model: config.model, messages: messages}
    |> put_if("temperature", config.temperature)
  end

  defp do_request(config, body, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeouts[config.role])

    req_opts =
      [
        url: "#{config.base_url}/chat/completions",
        method: :post,
        json: body,
        headers: auth_headers(config.api_key),
        receive_timeout: timeout,
        pool_timeout: timeout,
        retry: false
      ]
      |> maybe_put_plug(opts)

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp format_error({:api_error, status, body}), do: "API error #{status}: #{inspect(body)}"

  defp format_error({:request_failed, exception}),
    do: "Request failed: #{Exception.message(exception)}"

  defp format_error(message) when is_binary(message), do: message

  defp auth_headers(nil), do: []
  defp auth_headers(""), do: []
  defp auth_headers(key), do: [{"authorization", "Bearer #{key}"}]

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end
end
