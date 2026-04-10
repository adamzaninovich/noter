defmodule NoterWeb.SessionLive.New do
  use NoterWeb, :live_view

  alias Noter.Campaigns
  alias Noter.Jobs
  alias Noter.Sessions
  import NoterWeb.SessionLive.UploadHelpers

  @steps [
    {"uploading", "Upload"},
    {"trimming", "Trim"},
    {"transcribing", "Transcribe"},
    {"reviewing", "Review"},
    {"noting", "Notes"},
    {"done", "Done"}
  ]

  @impl true
  def mount(%{"campaign_slug" => campaign_slug}, _session, socket) do
    campaign = Campaigns.get_campaign_by_slug!(campaign_slug)
    changeset = Sessions.change_session(%Noter.Sessions.Session{campaign_id: campaign.id})

    if connected?(socket), do: Jobs.subscribe_uploads(campaign.id)

    {:ok,
     socket
     |> assign(:page_title, "New Session")
     |> assign(:campaign, campaign)
     |> assign(:form, to_form(changeset))
     |> assign(:steps, @steps)
     |> assign(:processing?, false)
     |> assign(:processing_status, nil)
     |> allow_upload(:zip_file,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: 2_000_000_000,
       chunk_size: 512_000
     )
     |> allow_upload(:vocab_file, accept: ~w(.txt), max_entries: 1, max_file_size: 1_000_000)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/campaigns/#{@campaign.slug}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <div>
            <div class="text-sm text-base-content/60 breadcrumbs p-0">
              <ul>
                <li><.link navigate={~p"/campaigns/#{@campaign.slug}"}>{@campaign.name}</.link></li>
                <li>New Session</li>
              </ul>
            </div>
            <h1 class="text-3xl font-bold">New Session</h1>
          </div>
        </div>

        <ul class="steps w-full">
          <%= for {status_key, label} <- @steps do %>
            <li class={["step", status_key == "uploading" && "step-primary"]}>{label}</li>
          <% end %>
        </ul>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <%= if @processing? do %>
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="text-base-content/70">
                  {@processing_status || "Processing uploaded files..."}
                </p>
              </div>
            <% else %>
              <.form
                for={@form}
                id="session-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-6"
              >
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Session Name"
                  placeholder="e.g. Session 42 — The Dragon's Lair"
                />

                <div class="divider">Files</div>

                <div class="space-y-4">
                  <%!-- Zip Upload --%>
                  <div>
                    <label class="label font-medium">
                      Discord Recording (ZIP)
                    </label>
                    <div class="flex flex-col gap-2" phx-drop-target={@uploads.zip_file.ref}>
                      <.live_file_input
                        upload={@uploads.zip_file}
                        class="file-input file-input-bordered w-full"
                      />
                      <.upload_entries
                        entries={@uploads.zip_file.entries}
                        upload_ref={@uploads.zip_file.ref}
                        upload={@uploads.zip_file}
                      />
                    </div>
                  </div>

                  <%!-- Vocab Upload --%>
                  <div>
                    <label class="label font-medium">Vocabulary File (TXT)</label>
                    <div class="flex flex-col gap-2" phx-drop-target={@uploads.vocab_file.ref}>
                      <.live_file_input
                        upload={@uploads.vocab_file}
                        class="file-input file-input-bordered w-full"
                      />
                      <.upload_entries
                        entries={@uploads.vocab_file.entries}
                        upload_ref={@uploads.vocab_file.ref}
                        upload={@uploads.vocab_file}
                      />
                    </div>
                  </div>
                </div>

                <div class="flex justify-end gap-3 pt-2">
                  <.link navigate={~p"/campaigns/#{@campaign.slug}"} class="btn btn-ghost">
                    Cancel
                  </.link>
                  <.button
                    type="submit"
                    class="btn btn-primary"
                    phx-disable-with="Uploading..."
                    disabled={
                      @form[:name].value in [nil, ""] or
                        @uploads.zip_file.entries == []
                    }
                  >
                    Create Session
                  </.button>
                </div>
              </.form>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"session" => session_params}, socket) do
    changeset =
      %Noter.Sessions.Session{campaign_id: socket.assigns.campaign.id}
      |> Sessions.change_session(session_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("cancel-upload", %{"ref" => ref, "upload-ref" => upload_ref}, socket) do
    {:noreply, cancel_upload_by_ref(socket, ref, upload_ref)}
  end

  def handle_event("save", %{"session" => session_params}, socket) do
    campaign = socket.assigns.campaign

    if socket.assigns.uploads.zip_file.entries == [] do
      {:noreply, put_flash(socket, :error, "A ZIP file is required.")}
    else
      changeset =
        %Noter.Sessions.Session{campaign_id: campaign.id}
        |> Sessions.change_session(session_params)

      if changeset.valid? do
        zip_paths = consume_uploaded_entries(socket, :zip_file, &consume_to_tmp/2)
        vocab_paths = consume_uploaded_entries(socket, :vocab_file, &consume_to_tmp/2)

        Jobs.start_upload_processing(
          session_params,
          campaign,
          List.first(zip_paths),
          List.first(vocab_paths)
        )

        {:noreply, assign(socket, processing?: true, processing_status: "Creating session...")}
      else
        {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}))}
      end
    end
  end

  @impl true
  def handle_info({:processing_status, status}, socket) do
    {:noreply, assign(socket, :processing_status, status)}
  end

  def handle_info({:upload_processed, {:ok, session}}, socket) do
    campaign = socket.assigns.campaign

    {:noreply,
     socket
     |> put_flash(:info, "Session created and files processed.")
     |> push_navigate(to: ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")}
  end

  def handle_info({:upload_processed, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    {:noreply,
     socket
     |> assign(:processing?, false)
     |> assign(:form, to_form(changeset))}
  end

  def handle_info({:upload_processed, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:processing?, false)
     |> put_flash(:error, "File processing failed: #{reason}")}
  end
end
