defmodule Noter.LLM.Client do
  @moduledoc """
  OpenAI-compatible chat completions client.
  Reads configuration from `Noter.Settings` based on role (:extraction or :writing).
  """

  alias Noter.LLM.Structured
  alias Noter.Settings

  @default_timeouts %{extraction: 30_000, writing: 120_000}

  def chat(role, messages, opts \\ []) when role in [:extraction, :writing] do
    prefix = "llm_#{role}"
    base_url = Settings.get("#{prefix}_base_url")
    model = Settings.get("#{prefix}_model")
    api_key = Settings.get("#{prefix}_api_key")
    temperature = Settings.get("#{prefix}_temperature")

    max_tokens =
      case role do
        :writing -> Settings.get("#{prefix}_max_tokens")
        _ -> nil
      end

    if is_nil(base_url) or base_url == "" do
      {:error, "#{prefix}_base_url is not configured"}
    else
      timeout = Keyword.get(opts, :timeout, @default_timeouts[role])

      body =
        %{model: model, messages: messages}
        |> put_if("temperature", temperature)
        |> put_if("max_tokens", max_tokens)

      req_opts =
        [
          url: "#{base_url}/chat/completions",
          method: :post,
          json: body,
          headers: auth_headers(api_key),
          receive_timeout: timeout,
          retry: false
        ]
        |> maybe_put_plug(opts)

      case Req.request(req_opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
          {:ok, content}

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, exception} ->
          {:error, "Request failed: #{Exception.message(exception)}"}
      end
    end
  end

  def chat_json(role, messages, json_schema, opts \\ []) do
    body_extra = %{
      response_format: %{
        type: "json_schema",
        json_schema: %{name: "response", strict: true, schema: json_schema}
      }
    }

    prefix = "llm_#{role}"
    base_url = Settings.get("#{prefix}_base_url")
    model = Settings.get("#{prefix}_model")
    api_key = Settings.get("#{prefix}_api_key")
    temperature = Settings.get("#{prefix}_temperature")
    timeout = Keyword.get(opts, :timeout, @default_timeouts[role])

    if is_nil(base_url) or base_url == "" do
      {:error, "#{prefix}_base_url is not configured"}
    else
      body =
        %{model: model, messages: messages}
        |> put_if("temperature", temperature)
        |> Map.merge(body_extra)

      req_opts =
        [
          url: "#{base_url}/chat/completions",
          method: :post,
          json: body,
          headers: auth_headers(api_key),
          receive_timeout: timeout,
          retry: false
        ]
        |> maybe_put_plug(opts)

      case Req.request(req_opts) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
          case Jason.decode(content) do
            {:ok, parsed} ->
              {:ok, parsed}

            {:error, _} ->
              Structured.call(role, messages, json_schema, opts)
          end

        {:ok, %{status: status}} when status in [400, 422] ->
          Structured.call(role, messages, json_schema, opts)

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, exception} ->
          {:error, "Request failed: #{Exception.message(exception)}"}
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
