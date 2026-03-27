defmodule NoterWeb.SettingsLive do
  use NoterWeb, :live_view

  alias Noter.Settings

  @api_key_fields ~w(llm_extraction_api_key llm_writing_api_key)
  @numeric_fields ~w(llm_extraction_temperature llm_extraction_concurrency llm_writing_temperature)

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.all()

    keys_set =
      @api_key_fields
      |> Map.new(fn key -> {key, Settings.configured?(key)} end)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:keys_set, keys_set)
     |> assign(:extraction_models, [])
     |> assign(:writing_models, [])
     |> assign(:form, to_form(settings, as: :settings))}
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    result =
      Noter.Repo.transaction(fn ->
        Enum.reduce_while(params, :ok, fn {key, value}, :ok ->
          if key in @api_key_fields and value == "" and socket.assigns.keys_set[key] do
            {:cont, :ok}
          else
            val = if key in @numeric_fields, do: parse_numeric(value), else: value

            case Settings.set(key, val) do
              {:ok, _setting} -> {:cont, :ok}
              {:error, changeset} -> {:halt, Noter.Repo.rollback({:failed, key, changeset})}
            end
          end
        end)
      end)

    case result do
      {:ok, :ok} ->
        settings = Settings.all()

        keys_set =
          @api_key_fields
          |> Map.new(fn key -> {key, Settings.configured?(key)} end)

        {:noreply,
         socket
         |> assign(:keys_set, keys_set)
         |> assign(:form, to_form(settings, as: :settings))
         |> put_flash(:info, "Settings saved.")}

      {:error, {:failed, key, _changeset}} ->
        {:noreply, put_flash(socket, :error, "Failed to save setting: #{key}")}
    end
  end

  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :settings))}
  end

  def handle_event("test_transcription", _params, socket) do
    url = socket.assigns.form[:transcription_url].value

    if is_binary(url) and url != "" do
      case Req.get(url <> "/health", receive_timeout: 5_000) do
        {:ok, %{status: 200, body: %{"status" => "ok"}}} ->
          {:noreply, put_flash(socket, :info, "Connection successful!")}

        {:ok, %{status: status, body: body}} ->
          {:noreply,
           put_flash(socket, :error, "Health check failed (#{status}): #{inspect(body)}")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Connection failed.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No transcription URL configured.")}
    end
  end

  def handle_event("fetch_models", %{"role" => role}, socket)
      when role in ~w(extraction writing) do
    form = socket.assigns.form
    prefix = "llm_#{role}"

    base_url = form[String.to_existing_atom("#{prefix}_base_url")].value
    form_key = form[String.to_existing_atom("#{prefix}_api_key")].value

    api_key =
      if is_binary(form_key) and form_key != "",
        do: form_key,
        else: Settings.get("#{prefix}_api_key")

    if is_nil(base_url) or base_url == "" do
      {:noreply, put_flash(socket, :error, "Set a Base URL first.")}
    else
      headers = if api_key, do: [{"authorization", "Bearer #{api_key}"}], else: []

      case Req.get("#{base_url}/models", headers: headers, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: %{"data" => models}}} ->
          ids = models |> Enum.map(& &1["id"]) |> Enum.sort()
          models_key = String.to_existing_atom("#{role}_models")

          {:noreply,
           socket
           |> assign(models_key, ids)
           |> put_flash(:info, "Found #{length(ids)} model(s).")}

        {:ok, %{status: status, body: body}} ->
          {:noreply,
           put_flash(socket, :error, "Failed to fetch models (#{status}): #{inspect(body)}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to fetch models: #{inspect(reason)}")}
      end
    end
  end

  defp parse_numeric(""), do: nil

  defp parse_numeric(val) when is_binary(val) do
    case Float.parse(val) do
      {num, ""} -> if trunc(num) == num, do: trunc(num), else: num
      _ -> val
    end
  end

  defp parse_numeric(val), do: val

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center gap-3 mb-6">
        <.link navigate="/" class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-arrow-left" class="size-5" />
        </.link>
        <h1 class="text-2xl font-bold">Settings</h1>
      </div>

      <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">Transcription Service</h2>

            <div class="fieldset">
              <label for="settings_transcription_url" class="label">Transcription URL</label>
              <div class="join w-full">
                <input
                  type="text"
                  name="settings[transcription_url]"
                  id="settings_transcription_url"
                  value={@form[:transcription_url].value}
                  placeholder="http://host:port"
                  class="input join-item flex-1"
                />
                <button
                  type="button"
                  phx-click="test_transcription"
                  class="btn btn-soft btn-accent join-item"
                >
                  Test Connection
                </button>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">LLM — Extraction Model</h2>

            <.input
              field={@form[:llm_extraction_base_url]}
              type="text"
              label="Base URL"
              placeholder="https://api.openai.com/v1"
            />
            <.input
              field={@form[:llm_extraction_api_key]}
              type="password"
              label="API Key"
              placeholder={if @keys_set["llm_extraction_api_key"], do: "Key is set", else: ""}
              value=""
            />

            <div class="fieldset">
              <label class="label">Model</label>
              <div class="join w-full">
                <%= if @extraction_models != [] do %>
                  <select
                    name="settings[llm_extraction_model]"
                    id="settings_llm_extraction_model"
                    class="select select-bordered join-item flex-1"
                  >
                    <option value="">Select a model...</option>
                    <%= for model <- @extraction_models do %>
                      <option value={model} selected={@form[:llm_extraction_model].value == model}>
                        {model}
                      </option>
                    <% end %>
                  </select>
                <% else %>
                  <input
                    type="text"
                    name="settings[llm_extraction_model]"
                    id="settings_llm_extraction_model"
                    value={@form[:llm_extraction_model].value}
                    placeholder="gpt-4o"
                    class="input join-item flex-1"
                  />
                <% end %>
                <button
                  type="button"
                  phx-click="fetch_models"
                  phx-value-role="extraction"
                  phx-disable-with="Fetching..."
                  class="btn btn-soft btn-accent join-item"
                >
                  Fetch Models
                </button>
              </div>
            </div>

            <div class="flex gap-4">
              <div class="flex-1">
                <.input
                  field={@form[:llm_extraction_temperature]}
                  type="number"
                  label="Temperature"
                  step="0.1"
                />
              </div>
              <div class="flex-1">
                <.input
                  field={@form[:llm_extraction_concurrency]}
                  type="number"
                  label="Concurrency"
                  placeholder="4"
                />
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">LLM — Writing Model</h2>

            <.input
              field={@form[:llm_writing_base_url]}
              type="text"
              label="Base URL"
              placeholder="https://api.openai.com/v1"
            />
            <.input
              field={@form[:llm_writing_api_key]}
              type="password"
              label="API Key"
              placeholder={if @keys_set["llm_writing_api_key"], do: "Key is set", else: ""}
              value=""
            />

            <div class="fieldset">
              <label class="label">Model</label>
              <div class="join w-full">
                <%= if @writing_models != [] do %>
                  <select
                    name="settings[llm_writing_model]"
                    id="settings_llm_writing_model"
                    class="select select-bordered join-item flex-1"
                  >
                    <option value="">Select a model...</option>
                    <%= for model <- @writing_models do %>
                      <option value={model} selected={@form[:llm_writing_model].value == model}>
                        {model}
                      </option>
                    <% end %>
                  </select>
                <% else %>
                  <input
                    type="text"
                    name="settings[llm_writing_model]"
                    id="settings_llm_writing_model"
                    value={@form[:llm_writing_model].value}
                    placeholder="gpt-4o"
                    class="input join-item flex-1"
                  />
                <% end %>
                <button
                  type="button"
                  phx-click="fetch_models"
                  phx-value-role="writing"
                  phx-disable-with="Fetching..."
                  class="btn btn-soft btn-accent join-item"
                >
                  Fetch Models
                </button>
              </div>
            </div>

            <.input
              field={@form[:llm_writing_temperature]}
              type="number"
              label="Temperature"
              step="0.1"
            />
          </div>
        </div>

        <button type="submit" class="btn btn-primary w-full">Save Settings</button>
      </.form>
    </Layouts.app>
    """
  end
end
