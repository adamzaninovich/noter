defmodule NoterWeb.SessionLive.Show do
  use NoterWeb, :live_view

  alias Noter.Sessions
  alias Noter.Uploads
  import NoterWeb.SessionLive.UploadHelpers

  @steps [
    {"uploaded", "Upload"},
    {"trimmed", "Trim"},
    {"transcribed", "Transcribe"},
    {"reviewing", "Review"},
    {"done", "Done"}
  ]

  @impl true
  def mount(%{"campaign_slug" => campaign_slug, "session_slug" => session_slug}, _session, socket) do
    campaign = Noter.Campaigns.get_campaign_by_slug!(campaign_slug)
    session = Sessions.get_session_by_slug!(campaign.id, session_slug)

    renamed_files = Uploads.list_renamed_files(session.id)
    session_dir = Uploads.session_dir(session.id)

    socket =
      socket
      |> assign(:page_title, session.name)
      |> assign(:session, session)
      |> assign(:campaign, session.campaign)
      |> assign(:renamed_files, renamed_files)
      |> assign(:has_aac?, File.exists?(Path.join(session_dir, "merged.aac")))
      |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
      |> assign(:steps, @steps)
      |> assign(:processing?, false)

    socket =
      if session.status == "uploading" do
        socket
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
        |> allow_upload(:vocab_file, accept: ~w(.txt), max_entries: 1, max_file_size: 1_000_000)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <%!-- Header with breadcrumb --%>
        <div class="flex items-center gap-3">
          <.link navigate={~p"/campaigns/#{@campaign.slug}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <div>
            <div class="text-sm text-base-content/60 breadcrumbs p-0">
              <ul>
                <li><.link navigate={~p"/campaigns/#{@campaign.slug}"}>{@campaign.name}</.link></li>
                <li>{@session.name}</li>
              </ul>
            </div>
            <div class="flex items-center gap-3">
              <h1 class="text-3xl font-bold">{@session.name}</h1>
              <span class={["badge", status_badge_class(@session.status)]}>{@session.status}</span>
            </div>
          </div>
        </div>

        <%!-- Step indicator --%>
        <ul class="steps w-full">
          <%= for {status_key, label} <- @steps do %>
            <li class={["step", step_complete?(@session.status, status_key) && "step-primary"]}>
              {label}
            </li>
          <% end %>
        </ul>

        <%!-- Processing spinner --%>
        <%= if @processing? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="text-base-content/70">Processing uploaded files...</p>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Upload form when status is "uploading" --%>
        <%= if @session.status == "uploading" and not @processing? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Upload Files</h2>
              <p class="text-sm text-base-content/60">
                Upload your Discord recording zip, merged audio, and vocabulary file to continue.
              </p>

              <.form for={%{}} id="upload-form" phx-submit="upload" class="space-y-4 mt-2">
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

                <div class="flex justify-end pt-2">
                  <.button type="submit" class="btn btn-primary" phx-disable-with="Uploading...">
                    Upload Files
                  </.button>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

        <%!-- Uploaded files display --%>
        <%= if @session.status in ~w(uploaded trimmed transcribing transcribed reviewing done) do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Uploaded Files</h2>

              <%= if @renamed_files != [] do %>
                <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-100 mt-2">
                  <table class="table" id="renamed-files-table">
                    <thead>
                      <tr>
                        <th>Character</th>
                        <th>File</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={file <- @renamed_files}>
                        <td class="font-medium">{Path.basename(file, ".flac")}</td>
                        <td class="font-mono text-sm text-base-content/70">{file}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% else %>
                <p class="text-base-content/50">No renamed FLAC files found.</p>
              <% end %>

              <div class="flex gap-4 mt-3 text-sm text-base-content/60">
                <.file_indicator label="Merged Audio" exists?={@has_aac?} />
                <.file_indicator label="Vocabulary" exists?={@has_vocab?} />
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Danger Zone --%>
        <div class="card bg-base-200 shadow-sm border border-error/20">
          <div class="card-body">
            <h2 class="card-title text-lg text-error">Danger Zone</h2>
            <p class="text-sm text-base-content/60">
              Deleting this session will also remove all its uploaded files.
            </p>
            <div class="mt-2">
              <button
                id="delete-session-btn"
                phx-click="delete_session"
                data-confirm="Are you sure you want to delete this session and all its files?"
                class="btn btn-error btn-sm"
              >
                Delete Session
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp file_indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <%= if @exists? do %>
        <.icon name="hero-check-circle" class="size-4 text-success" />
      <% else %>
        <.icon name="hero-x-circle" class="size-4 text-base-content/30" />
      <% end %>
      <span>{@label}</span>
    </div>
    """
  end

  @status_order ~w(uploading uploaded trimmed transcribing transcribed reviewing done)

  defp step_complete?(current_status, step_status) do
    current_idx = Enum.find_index(@status_order, &(&1 == current_status)) || 0
    step_idx = Enum.find_index(@status_order, &(&1 == step_status)) || 0
    current_idx >= step_idx
  end

  defp status_badge_class(status) do
    case status do
      "done" -> "badge-success"
      "reviewing" -> "badge-warning"
      "transcribing" -> "badge-info"
      "transcribed" -> "badge-info"
      "uploaded" -> "badge-primary"
      _ -> "badge-ghost"
    end
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref, "upload-ref" => upload_ref}, socket) do
    {:noreply, cancel_upload_by_ref(socket, ref, upload_ref)}
  end

  def handle_event("upload", _params, socket) do
    if socket.assigns.uploads.zip_file.entries == [] do
      {:noreply, put_flash(socket, :error, "A ZIP file is required.")}
    else
      session = socket.assigns.session
      campaign = socket.assigns.campaign

      zip_paths = consume_uploaded_entries(socket, :zip_file, &consume_to_tmp/2)
      aac_paths = consume_uploaded_entries(socket, :aac_file, &consume_to_tmp/2)
      vocab_paths = consume_uploaded_entries(socket, :vocab_file, &consume_to_tmp/2)

      lv = self()

      Task.start(fn ->
        result =
          case Uploads.process_uploads(
                 session,
                 campaign,
                 List.first(zip_paths),
                 List.first(aac_paths),
                 List.first(vocab_paths)
               ) do
            {:ok, _renamed} ->
              Sessions.update_session(session, %{status: "uploaded"})

            {:error, reason} ->
              {:error, reason}
          end

        send(lv, {:upload_processed, result})
      end)

      {:noreply, assign(socket, :processing?, true)}
    end
  end

  def handle_event("delete_session", _params, socket) do
    session = socket.assigns.session
    campaign = socket.assigns.campaign

    File.rm_rf(Uploads.session_dir(session.id))
    {:ok, _} = Sessions.delete_session(session)

    {:noreply,
     socket
     |> put_flash(:info, "Session deleted.")
     |> push_navigate(to: ~p"/campaigns/#{campaign.slug}")}
  end

  @impl true
  def handle_info({:upload_processed, {:ok, session}}, socket) do
    renamed_files = Uploads.list_renamed_files(session.id)
    session_dir = Uploads.session_dir(session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:renamed_files, renamed_files)
     |> assign(:has_aac?, File.exists?(Path.join(session_dir, "merged.aac")))
     |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
     |> assign(:processing?, false)
     |> put_flash(:info, "Files uploaded and processed.")}
  end

  def handle_info({:upload_processed, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:processing?, false)
     |> put_flash(:error, "File processing failed: #{reason}")}
  end
end
