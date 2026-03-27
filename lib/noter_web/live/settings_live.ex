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

  def handle_event("test_transcription", _params, socket) do
    url = Settings.get("transcription_url")

    if url && url != "" do
      case Req.get(url, receive_timeout: 5_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:noreply, put_flash(socket, :info, "Connection successful!")}

        {:ok, %{status: status}} ->
          {:noreply, put_flash(socket, :error, "Server responded with status #{status}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Connection failed: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No transcription URL configured.")}
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
      <h1 class="text-2xl font-bold mb-6">Settings</h1>

      <.form for={@form} id="settings-form" phx-submit="save" class="space-y-6">
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">Transcription Service</h2>

            <div class="flex items-center gap-2">
              <div class="flex-1 [&_.fieldset]:mb-0">
                <.input
                  field={@form[:transcription_url]}
                  type="text"
                  label="Transcription URL"
                  placeholder="http://host:port"
                />
              </div>
              <button type="button" phx-click="test_transcription" class="btn btn-outline btn-sm mt-4">
                Test Connection
              </button>
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
            <.input
              field={@form[:llm_extraction_model]}
              type="text"
              label="Model"
              placeholder="gpt-4o"
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
            <.input field={@form[:llm_writing_model]} type="text" label="Model" placeholder="gpt-4o" />
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
