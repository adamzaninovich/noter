defmodule Noter.LLM.Client do
  @moduledoc """
  OpenAI-compatible chat completions client.
  Reads configuration from `Noter.Settings` based on role (:extraction or :writing).
  """

  alias Noter.LLM.Structured
  alias Noter.Settings

  @default_timeouts %{extraction: 30_000, writing: 120_000}

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
      body_extra = %{
        response_format: %{
          type: "json_schema",
          json_schema: %{name: "response", strict: true, schema: json_schema}
        }
      }

      body =
        build_chat_body(config, messages)
        |> Map.merge(body_extra)

      case do_request(config, body, opts) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, parsed} -> {:ok, parsed}
            {:error, _} -> Structured.call(role, messages, json_schema, opts)
          end

        {:error, {:api_error, status, _body}} when status in [400, 422] ->
          Structured.call(role, messages, json_schema, opts)

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  def list_models(role, opts \\ []) when role in [:extraction, :writing] do
    prefix = "llm_#{role}"
    base_url = Settings.get("#{prefix}_base_url")
    api_key = Settings.get("#{prefix}_api_key")

    if is_nil(base_url) or base_url == "" do
      {:error, "#{prefix}_base_url is not configured"}
    else
      req_opts =
        [
          url: "#{base_url}/models",
          method: :get,
          headers: auth_headers(api_key),
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
