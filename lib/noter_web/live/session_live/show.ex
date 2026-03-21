defmodule NoterWeb.SessionLive.Show do
  use NoterWeb, :live_view

  alias Noter.Sessions
  alias Noter.Uploads
  import NoterWeb.SessionLive.UploadHelpers

  @steps [
    {"uploading", "Upload"},
    {"uploaded", "Trim"},
    {"trimmed", "Transcribe"},
    {"transcribed", "Review"},
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
      |> assign(:has_merged_audio?, File.exists?(Path.join(session_dir, "merged.wav")))
      |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
      |> assign(:steps, @steps)
      |> assign(:processing?, false)
      |> assign(:trimming?, false)
      |> assign(:generating_peaks?, false)
      |> assign(:trim_start, session.trim_start_seconds)
      |> assign(:trim_end, session.trim_end_seconds)
      |> assign_audio_urls(session)
      |> retry_peaks_if_needed(session)

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

        <%!-- Generating waveform spinner --%>
        <%= if @generating_peaks? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="text-base-content/70">Generating waveform data...</p>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Trim card when status is "uploaded" --%>
        <%= if @session.status == "uploaded" and not @trimming? and not @generating_peaks? and @audio_url do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Audio Trimming</h2>
              <p class="text-sm text-base-content/60">
                Drag the region handles to set trim boundaries. The shaded region will be kept.
              </p>

              <div
                id="waveform"
                phx-hook=".Waveform"
                phx-update="ignore"
                data-audio-url={@audio_url}
                data-peaks-url={@peaks_url}
                data-duration={@session.duration_seconds}
                data-trim-start={@trim_start || 0}
                data-trim-end={@trim_end || @session.duration_seconds}
                class="mt-3"
              >
                <div
                  data-waveform
                  class="w-full rounded-lg overflow-x-auto bg-base-100 border border-base-content/10 p-2"
                >
                </div>

                <div class="flex items-center justify-between mt-3 gap-4">
                  <div class="flex items-center gap-2">
                    <button data-play-pause type="button" class="btn btn-primary btn-sm">
                      <span data-play-icon><.icon name="hero-play-solid" class="size-4" /> Play</span>
                      <span data-pause-icon class="hidden">
                        <.icon name="hero-pause-solid" class="size-4" /> Pause
                      </span>
                    </button>
                    <span class="font-mono text-sm">
                      <span data-current-time>00:00:00</span>
                    </span>
                  </div>
                  <div class="flex items-center gap-2 flex-1 max-w-xs">
                    <span class="text-xs text-base-content/60">Zoom</span>
                    <input
                      data-zoom
                      type="range"
                      min="0"
                      max="100"
                      value="0"
                      class="range range-xs range-primary flex-1"
                    />
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-x-6 gap-y-2 mt-3 text-sm">
                  <div>
                    <span class="text-base-content/60">Start:</span>
                    <span data-trim-start-display class="font-mono font-medium">00:00:00</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">End:</span>
                    <span data-trim-end-display class="font-mono font-medium">00:00:00</span>
                  </div>
                  <div data-keeping-display class="text-base-content/60"></div>
                </div>

                <div class="flex flex-wrap items-center gap-2 mt-4">
                  <button data-preview-start type="button" class="btn btn-outline btn-sm">
                    <.icon name="hero-play" class="size-4" /> Preview Start
                  </button>
                  <button data-preview-end type="button" class="btn btn-outline btn-sm">
                    Preview End <.icon name="hero-play" class="size-4" />
                  </button>
                </div>
              </div>

              <div class="flex justify-end mt-4">
                <button
                  id="confirm-trim-btn"
                  phx-click="confirm_trim"
                  class="btn btn-primary"
                  phx-disable-with="Trimming..."
                >
                  Confirm Trim
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Trimming spinner --%>
        <%= if @trimming? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="text-base-content/70">Trimming audio files...</p>
              </div>
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
                <.file_indicator label="Merged Audio" exists?={@has_merged_audio?} />
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
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Waveform">
      // TODO: implement per TRIM-SPEC.md
      export default {
        mounted() {},
        destroyed() {}
      }
    </script>
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

        with {:ok, updated_session} <- result do
          run_peak_pipeline(updated_session, lv)
        end
      end)

      {:noreply, assign(socket, :processing?, true)}
    end
  end

  def handle_event("trim_region_updated", %{"start" => start, "end" => end_val}, socket) do
    {:noreply,
     socket
     |> assign(:trim_start, start)
     |> assign(:trim_end, end_val)}
  end

  def handle_event("confirm_trim", _params, socket) do
    %{trim_start: start, trim_end: end_val, session: session} = socket.assigns

    cond do
      is_nil(start) or is_nil(end_val) ->
        {:noreply, put_flash(socket, :error, "Please set trim boundaries first.")}

      start >= end_val ->
        {:noreply, put_flash(socket, :error, "Trim start must be before trim end.")}

      true ->
        lv = self()
        session = Sessions.get_session_with_campaign!(session.id)

        Task.start(fn ->
          result = Uploads.trim_session(session, start, end_val)
          send(lv, {:trim_complete, result, start, end_val})
        end)

        {:noreply, assign(socket, :trimming?, true)}
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
     |> assign(:has_merged_audio?, File.exists?(Path.join(session_dir, "merged.wav")))
     |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
     |> assign(:trim_start, nil)
     |> assign(:trim_end, nil)
     |> assign(:processing?, false)
     |> assign(:generating_peaks?, true)
     |> put_flash(:info, "Files uploaded. Generating waveform...")}
  end

  def handle_info({:peaks_ready, session}, socket) do
    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:generating_peaks?, false)
     |> assign_audio_urls(session)
     |> put_flash(:info, "Waveform ready.")}
  end

  def handle_info({:peaks_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:generating_peaks?, false)
     |> put_flash(:error, "Waveform generation failed: #{reason}")}
  end

  def handle_info({:trim_complete, :ok, start, end_val}, socket) do
    session = socket.assigns.session

    case Sessions.update_session(session, %{
           status: "trimmed",
           trim_start_seconds: start,
           trim_end_seconds: end_val
         }) do
      {:ok, session} ->
        Uploads.cleanup_wav(session.id)

        {:noreply,
         socket
         |> assign(:session, session)
         |> assign(:trimming?, false)
         |> put_flash(:info, "Audio trimmed successfully.")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:trimming?, false)
         |> put_flash(:error, "Trim succeeded but failed to update session.")}
    end
  end

  def handle_info({:trim_complete, {:error, reason}, _start, _end_val}, socket) do
    {:noreply,
     socket
     |> assign(:trimming?, false)
     |> put_flash(:error, "Trimming failed: #{reason}")}
  end

  def handle_info({:upload_processed, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:processing?, false)
     |> put_flash(:error, "File processing failed: #{reason}")}
  end

  defp retry_peaks_if_needed(socket, session) do
    has_aac? = File.exists?(Path.join(Uploads.session_dir(session.id), "merged.aac"))
    needs_pipeline? = is_nil(session.duration_seconds) or not socket.assigns.has_merged_audio?

    if session.status == "uploaded" and needs_pipeline? and has_aac? do
      lv = self()

      Task.start(fn ->
        run_peak_pipeline(session, lv)
      end)

      assign(socket, :generating_peaks?, true)
    else
      socket
    end
  end

  defp run_peak_pipeline(session, lv) do
    with {:ok, _peaks_path} <- Uploads.generate_peaks(session.id),
         {:ok, duration} <- Uploads.get_duration(session.id),
         {:ok, updated_session} <- Sessions.update_session(session, %{duration_seconds: duration}) do
      send(lv, {:peaks_ready, updated_session})
    else
      {:error, reason} -> send(lv, {:peaks_failed, reason})
    end
  end

  defp assign_audio_urls(socket, session) do
    if session.status in ~w(uploaded trimmed transcribing transcribed reviewing done) and
         session.duration_seconds do
      socket
      |> assign(:audio_url, ~p"/sessions/#{session.id}/audio/merged")
      |> assign(:peaks_url, ~p"/sessions/#{session.id}/audio/peaks")
    else
      socket
      |> assign(:audio_url, nil)
      |> assign(:peaks_url, nil)
    end
  end
end
