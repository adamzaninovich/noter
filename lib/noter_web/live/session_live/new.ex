defmodule NoterWeb.SessionLive.New do
  use NoterWeb, :live_view

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  @impl true
  def mount(%{"campaign_slug" => campaign_slug}, _session, socket) do
    campaign = Campaigns.get_campaign_by_slug!(campaign_slug)
    changeset = Sessions.change_session(%Noter.Sessions.Session{campaign_id: campaign.id})

    {:ok,
     socket
     |> assign(:page_title, "New Session")
     |> assign(:campaign, campaign)
     |> assign(:form, to_form(changeset))
     |> allow_upload(:zip_file,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: 2_000_000_000,
       chunk_size: 512_000
     )
     |> allow_upload(:aac_file,
       accept: ~w(.aac),
       max_entries: 1,
       max_file_size: 1_000_000_000,
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

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
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
                  <label class="label font-medium">Discord Recording (ZIP)</label>
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

                <%!-- AAC Upload --%>
                <div>
                  <label class="label font-medium">Merged Audio (AAC)</label>
                  <div class="flex flex-col gap-2" phx-drop-target={@uploads.aac_file.ref}>
                    <.live_file_input
                      upload={@uploads.aac_file}
                      class="file-input file-input-bordered w-full"
                    />
                    <.upload_entries
                      entries={@uploads.aac_file.entries}
                      upload_ref={@uploads.aac_file.ref}
                      upload={@uploads.aac_file}
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
                <.button type="submit" class="btn btn-primary" phx-disable-with="Uploading...">
                  Create Session
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp upload_entries(assigns) do
    ~H"""
    <div :for={entry <- @entries} class="flex items-center gap-3">
      <div class="flex-1">
        <div class="flex items-center justify-between text-sm mb-1">
          <span class="truncate max-w-xs">{entry.client_name}</span>
          <button
            type="button"
            phx-click="cancel-upload"
            phx-value-ref={entry.ref}
            phx-value-upload-ref={@upload_ref}
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <progress class="progress progress-primary w-full" value={entry.progress} max="100">
          {entry.progress}%
        </progress>
        <div :for={err <- upload_errors(@upload, entry)} class="text-error text-sm mt-1">
          {upload_error_to_string(err)}
        </div>
      </div>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(:too_many_files), do: "Too many files"
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"

  @impl true
  def handle_event("validate", %{"session" => session_params}, socket) do
    changeset =
      %Noter.Sessions.Session{campaign_id: socket.assigns.campaign.id}
      |> Sessions.change_session(session_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("cancel-upload", %{"ref" => ref, "upload-ref" => upload_ref}, socket) do
    upload_name =
      case upload_ref do
        r when r == socket.assigns.uploads.zip_file.ref -> :zip_file
        r when r == socket.assigns.uploads.aac_file.ref -> :aac_file
        r when r == socket.assigns.uploads.vocab_file.ref -> :vocab_file
      end

    {:noreply, cancel_upload(socket, upload_name, ref)}
  end

  def handle_event("save", %{"session" => session_params}, socket) do
    campaign = socket.assigns.campaign

    case Sessions.create_session(campaign, session_params) do
      {:ok, session} ->
        # Consume uploads
        [zip_path] = consume_uploaded_entries(socket, :zip_file, &consume_to_tmp/2)

        aac_paths = consume_uploaded_entries(socket, :aac_file, &consume_to_tmp/2)
        aac_path = List.first(aac_paths)

        vocab_paths = consume_uploaded_entries(socket, :vocab_file, &consume_to_tmp/2)
        vocab_path = List.first(vocab_paths)

        case Uploads.process_uploads(session, campaign, zip_path, aac_path, vocab_path) do
          {:ok, _renamed} ->
            {:ok, _} = Sessions.update_session(session, %{status: "uploaded"})

            {:noreply,
             socket
             |> put_flash(:info, "Session created and files processed.")
             |> push_navigate(to: ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "File processing failed: #{reason}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp consume_to_tmp(meta, entry) do
    tmp_path =
      Path.join(System.tmp_dir!(), "noter-upload-#{entry.uuid}#{Path.extname(entry.client_name)}")

    File.cp!(meta.path, tmp_path)
    {:ok, tmp_path}
  end
end
