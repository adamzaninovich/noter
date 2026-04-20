defmodule NoterWeb.SettingsLive do
  use NoterWeb, :live_view

  alias Noter.LLM.Client
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

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :settings))}
  end

  @impl true
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

  @impl true
  def handle_event("fetch_models", %{"role" => role}, socket)
      when role in ~w(extraction writing) do
    base_url_key = "llm_#{role}_base_url"
    api_key_key = "llm_#{role}_api_key"

    base_url = socket.assigns.form[String.to_existing_atom(base_url_key)].value
    form_api_key = socket.assigns.form[String.to_existing_atom(api_key_key)].value

    api_key =
      case form_api_key do
        val when is_binary(val) and val != "" -> val
        _ -> Settings.get(api_key_key)
      end

    plug = Application.get_env(:noter, :fetch_models_plug, [])

    case Client.list_models(base_url, api_key, plug) do
      {:ok, ids} ->
        models_key = String.to_existing_atom("#{role}_models")

        {:noreply,
         socket
         |> assign(models_key, ids)
         |> put_flash(:info, "Found #{length(ids)} model(s).")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to fetch models: #{reason}")}
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

  attr :models, :list, required: true
  attr :role, :string, required: true
  attr :field, :any, required: true
  attr :placeholder, :string, default: "gpt-4o"

  defp model_selector(assigns) do
    assigns =
      assigns
      |> assign(:field_name, assigns.field.name)
      |> assign(:field_id, assigns.field.id)
      |> assign(:field_value, assigns.field.value)

    ~H"""
    <div class="fieldset">
      <label class="label">Model</label>
      <div class="join w-full">
        <%= if @models != [] do %>
          <select name={@field_name} id={@field_id} class="select select-bordered join-item flex-1">
            <option value="">Select a model...</option>
            <%= for model <- @models do %>
              <option value={model} selected={@field_value == model}>
                {model}
              </option>
            <% end %>
          </select>
        <% else %>
          <input
            type="text"
            name={@field_name}
            id={@field_id}
            value={@field_value}
            placeholder={@placeholder}
            class="input join-item flex-1"
          />
        <% end %>
        <button
          type="button"
          phx-click="fetch_models"
          phx-value-role={@role}
          phx-disable-with="Fetching..."
          class="btn btn-soft btn-accent join-item"
        >
          Fetch Models
        </button>
      </div>
    </div>
    """
  end

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

            <.model_selector
              field={@form[:llm_extraction_model]}
              models={@extraction_models}
              role="extraction"
            />

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

            <.model_selector
              field={@form[:llm_writing_model]}
              models={@writing_models}
              role="writing"
            />

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
