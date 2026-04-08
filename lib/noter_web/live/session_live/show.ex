defmodule NoterWeb.SessionLive.Show do
  use NoterWeb, :live_view

  require Logger

  alias Noter.Jobs
  alias Noter.Sessions
  alias Noter.Transcription
  alias Noter.Transcription.SSEClient
  alias Noter.Transcription.Transcript
  alias Noter.Uploads

  import NoterWeb.SessionLive.Components
  import NoterWeb.SessionLive.ReviewState

  @steps [
    {"uploading", "Upload"},
    {"trimming", "Trim"},
    {"transcribing", "Transcribe"},
    {"reviewing", "Review"},
    {"noting", "Notes"},
    {"done", "Done"}
  ]

  @impl true
  def mount(%{"campaign_slug" => campaign_slug, "session_slug" => session_slug}, _session, socket) do
    campaign = Noter.Campaigns.get_campaign_by_slug!(campaign_slug)
    session = Sessions.get_session_by_slug!(campaign.id, session_slug)

    renamed_files = Uploads.list_renamed_files(session.id)
    session_dir = Uploads.session_dir(session.id)
    active_job = active_job(session)

    socket =
      socket
      |> assign(:page_title, session.name)
      |> assign(:session, session)
      |> assign(:campaign, session.campaign)
      |> assign(:renamed_files, renamed_files)
      |> assign(:has_merged_audio?, File.exists?(Path.join(session_dir, "merged.aac")))
      |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
      |> assign(:steps, @steps)
      |> assign(:active_job, active_job)
      |> assign_trim_files(renamed_files, active_job == :trimming)
      |> assign(:trim_start, session.trim_start_seconds)
      |> assign(:trim_end, session.trim_end_seconds)
      |> assign(:transcription_progress, nil)
      |> assign(:transcription_status, nil)
      |> assign(:upload_progress, nil)
      |> assign(:notes_progress, nil)
      |> assign_audio_urls(session)

    socket =
      if connected?(socket) do
        Jobs.subscribe(session.id)

        socket
        |> retry_peaks_if_needed(session)
        |> reconnect_transcription(session)
        |> reconnect_notes_progress(session)
        |> assign_review_state(session)
      else
        assign_review_state_defaults(socket, session)
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide={@reviewing?}>
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
        <ul class="steps w-full text-xs sm:text-sm">
          <%= for {status_key, label} <- @steps do %>
            <li class={["step", step_complete?(@session.status, status_key) && "step-primary"]}>
              {label}
            </li>
          <% end %>
        </ul>

        <%!-- Generating waveform spinner --%>
        <%= if @active_job == :peaks do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="text-base-content/70">Generating waveform data...</p>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Trim editor: session is in trim stage, no active job, audio ready --%>
        <%= if @session.status == "trimming" and is_nil(@active_job) and @audio_url do %>
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
                  <button data-set-start type="button" class="btn btn-outline btn-sm">
                    <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Set Start
                  </button>
                  <button data-preview-start type="button" class="btn btn-outline btn-sm">
                    <.icon name="hero-play" class="size-4" /> Preview Start
                  </button>
                  <button data-preview-end type="button" class="btn btn-outline btn-sm">
                    Preview End <.icon name="hero-play" class="size-4" />
                  </button>
                  <button data-set-end type="button" class="btn btn-outline btn-sm">
                    Set End <.icon name="hero-arrow-left-end-on-rectangle" class="size-4" />
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

        <%!-- Trimming progress --%>
        <%= if @active_job == :trimming do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Trimming Audio</h2>
              <div class="space-y-2 mt-3">
                <div :for={{file, pct} <- @trim_files} class="flex items-center gap-3">
                  <span class="text-sm w-44 truncate shrink-0">{trim_file_label(file)}</span>
                  <progress class="progress progress-primary flex-1 h-2" value={pct} max="100">
                  </progress>
                  <span class="w-8 shrink-0 flex justify-end">
                    <.icon
                      :if={pct == 100}
                      name="hero-check-circle-solid"
                      class="w-5 h-5 text-success"
                    />
                    <span :if={pct < 100} class="text-xs text-base-content/50">
                      {pct}%
                    </span>
                  </span>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Transcription is now auto-started after trim completes --%>

        <%!-- Transcription progress --%>
        <%= if @active_job == :transcribing do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Transcription in Progress</h2>
              <%= if @transcription_progress do %>
                <div class="space-y-3 mt-2">
                  <div class="flex items-center justify-between text-sm">
                    <span class="text-base-content/70">
                      Transcribing:
                      <span class="font-medium text-base-content">
                        {@transcription_progress.file}
                      </span>
                    </span>
                    <span class="font-mono">
                      <%= if @transcription_progress.file_pct > 0 do %>
                        {Float.round(@transcription_progress.file_pct * 1.0, 1)}%
                      <% end %>
                    </span>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/60 mb-1">Current file</div>
                    <progress
                      class="progress progress-primary w-full"
                      value={
                        if(@transcription_progress.file_pct > 0, do: @transcription_progress.file_pct)
                      }
                      max="100"
                    >
                    </progress>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/60 mb-1">Overall</div>
                    <progress
                      class="progress progress-accent w-full"
                      value={@transcription_progress.overall_pct}
                      max="100"
                    >
                    </progress>
                  </div>
                </div>
              <% else %>
                <div class="flex flex-col items-center py-8 gap-4">
                  <span class="loading loading-spinner loading-lg text-primary"></span>
                  <p class="text-base-content/70">
                    {transcription_wait_message(@transcription_status)}
                  </p>
                  <%= if @upload_progress do %>
                    <div class="w-full max-w-md space-y-2">
                      <progress
                        class="progress progress-primary w-full"
                        value={@upload_progress.bytes_sent}
                        max={@upload_progress.total_bytes}
                      >
                      </progress>
                      <div class="flex justify-between text-xs text-base-content/60">
                        <span>
                          {format_bytes(@upload_progress.bytes_sent)} / {format_bytes(
                            @upload_progress.total_bytes
                          )}
                        </span>
                        <span>{upload_speed(@upload_progress)}</span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Done summary skeleton --%>
        <%= if @session.status in ~w(noting done) and not @review_loaded? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="skeleton h-6 w-48"></div>
              <div class="flex gap-6 mt-4">
                <div :for={_i <- 1..5} class="flex flex-col items-center gap-1">
                  <div class="skeleton h-8 w-12"></div>
                  <div class="skeleton h-3 w-16"></div>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Notes generation card --%>
        <div :if={@session.status == "noting" and @review_loaded?} class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <%= if @active_job == :notes do %>
              <div class="flex flex-col items-center py-8 gap-4">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p :if={@notes_progress} class="text-base-content/70">
                  Extracting facts... ({@notes_progress.completed}/{@notes_progress.total} chunks)
                </p>
                <p :if={is_nil(@notes_progress)} class="text-base-content/70">
                  Generating notes...
                </p>
              </div>
            <% else %>
              <h2 class="card-title text-lg">
                <.icon name="hero-document-text" class="size-5" /> Generate Notes
              </h2>
              <div :if={@session.notes_error} class="alert alert-error text-sm mt-1">
                <.icon name="hero-exclamation-triangle-mini" class="size-4" />
                <span>Previous attempt failed: {@session.notes_error}</span>
              </div>
              <p class="text-sm text-base-content/60">
                Add any context the LLM should know about (character names, prior events, etc.)
                before generating notes.
              </p>
              <.form for={%{}} id="notes-form" phx-submit="generate_notes" class="mt-2">
                <textarea
                  name="context"
                  rows="4"
                  placeholder="Optional context for the LLM..."
                  class="textarea textarea-bordered w-full text-sm"
                  id="notes-context"
                >{@session.context}</textarea>
                <div class="mt-3">
                  <button type="submit" id="generate-notes-btn" class="btn btn-primary btn-sm">
                    <.icon name="hero-sparkles" class="size-4" /> Generate Notes
                  </button>
                </div>
              </.form>
            <% end %>
          </div>
        </div>

        <%!-- Done summary card --%>
        <%= if @done_stats do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex items-center justify-between gap-2">
                <h2 class="card-title text-lg whitespace-nowrap">
                  <.icon name="hero-check-circle-solid" class="size-6 text-success" />
                  Session Complete
                </h2>
                <button
                  :if={@session.status in ~w(noting done) and @active_job != :notes}
                  id="edit-session-btn"
                  phx-click="edit_session"
                  class="btn btn-outline btn-sm shrink-0"
                  phx-disable-with="Reverting..."
                >
                  Edit Session
                </button>
              </div>

              <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mt-3 gap-4">
                <div class="flex flex-col items-center gap-4 sm:flex-row sm:gap-6">
                  <div class="flex justify-center gap-6">
                    <div class="flex flex-col items-center">
                      <span class="text-2xl font-bold">{@done_stats.duration}</span>
                      <span class="text-xs text-base-content/60">Duration</span>
                    </div>
                    <div class="flex flex-col items-center">
                      <span class="text-2xl font-bold">{@done_stats.speaker_count}</span>
                      <span class="text-xs text-base-content/60">Speakers</span>
                    </div>
                    <div class="flex flex-col items-center">
                      <span class="text-2xl font-bold">{@done_stats.turn_count}</span>
                      <span class="text-xs text-base-content/60">Turns</span>
                    </div>
                  </div>
                  <div class="flex justify-center gap-6">
                    <div class="flex flex-col items-center">
                      <span class="text-2xl font-bold">{@done_stats.replacement_count}</span>
                      <span class="text-xs text-base-content/60">Replacements</span>
                    </div>
                    <div class="flex flex-col items-center">
                      <span class="text-2xl font-bold">{@done_stats.edit_count}</span>
                      <span class="text-xs text-base-content/60">Edits</span>
                    </div>
                  </div>
                </div>
                <a
                  href={~p"/sessions/#{@session.id}/download"}
                  class="btn btn-primary"
                  id="download-btn"
                >
                  <.icon name="hero-arrow-down-tray" class="size-5" /> Download ZIP
                </a>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Notes card --%>
        <div
          :if={@session.status == "done" and @session.session_notes}
          class="card bg-base-200 shadow-sm"
        >
          <div class="card-body">
            <h2 class="card-title text-lg">
              <.icon name="hero-document-text" class="size-5" /> Session Notes
            </h2>
            <div class="prose prose-sm max-w-none mt-2">
              {render_markdown(@session.session_notes)}
            </div>
          </div>
        </div>

        <%!-- Transcript review skeleton --%>
        <%= if @reviewing? and not @review_loaded? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="skeleton h-6 w-48"></div>
              <div class="skeleton h-4 w-96 mt-2"></div>
              <div class="flex flex-col lg:flex-row gap-6 mt-4">
                <div class="flex-1 min-w-0 space-y-3">
                  <div :for={_i <- 1..8} class="flex gap-3">
                    <div class="skeleton h-4 w-20 shrink-0"></div>
                    <div class="skeleton h-4 w-full"></div>
                  </div>
                </div>
                <div class="w-full lg:w-80 shrink-0 space-y-3">
                  <div class="skeleton h-10 w-full"></div>
                  <div class="skeleton h-10 w-full"></div>
                  <div class="skeleton h-8 w-24"></div>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Transcript review card --%>
        <%= if @review_loaded? and @reviewing? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title text-lg">
                  {if(@session.status in ~w(noting done),
                    do: "Transcript",
                    else: "Transcript Review"
                  )}
                </h2>
                <div class="flex items-center gap-2">
                  <%= if @session.status in ~w(noting done) do %>
                    <span class="badge badge-success gap-1">
                      <.icon name="hero-check-circle-mini" class="size-4" /> Finalized
                    </span>
                  <% else %>
                    <button
                      id="finalize-btn"
                      phx-click="finalize"
                      class="btn btn-success btn-sm"
                      phx-disable-with="Finalizing..."
                    >
                      <.icon name="hero-check-circle-mini" class="size-4" /> Finalize
                    </button>
                  <% end %>
                </div>
              </div>
              <p class="text-sm text-base-content/60 mb-2">
                <%= if @session.status in ~w(noting done) do %>
                  Read-only view of the finalized transcript.
                <% else %>
                  Click any word to prefill the find field. Add replacements to fix transcription errors.
                <% end %>
              </p>
              <div class="flex flex-col lg:flex-row gap-6">
                <%!-- Left: transcript viewer --%>
                <div class="flex-1 min-w-0 space-y-3">
                  <div
                    :if={@session.status not in ~w(noting done)}
                    id="transcript-audio"
                    phx-hook=".TranscriptAudio"
                    phx-update="ignore"
                  >
                    <audio id="trimmed-audio" preload="metadata" src={@trimmed_audio_url}></audio>
                  </div>

                  <div
                    id="turns"
                    phx-update="stream"
                    class="space-y-2 max-h-[70vh] overflow-y-auto pr-1"
                  >
                    <div
                      :for={{id, turn} <- @streams.turns}
                      id={id}
                      class={["group", @read_only? && turn.deleted? && "hidden"]}
                    >
                      {turn_row(%{
                        turn: turn,
                        speaker_colors: @speaker_colors,
                        read_only?: @read_only?
                      })}
                    </div>
                  </div>
                </div>

                <%!-- Right: replacements panel --%>
                <div
                  class="w-full lg:w-80 shrink-0 flex flex-col lg:max-h-[70vh]"
                  id="replacements-panel"
                  phx-hook=".DownloadJson"
                >
                  <%= if @session.status not in ~w(noting done) do %>
                    <.form
                      for={@replacement_form}
                      id="replacement-form"
                      phx-hook=".ReplacementForm"
                      phx-submit="add_replacement"
                      phx-change="validate_replacement"
                      class="shrink-0 mb-4"
                    >
                      <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-2 [&_.fieldset]:mb-0">
                        <.input
                          field={@replacement_form[:find]}
                          placeholder="Find..."
                          class="input input-sm input-bordered flex-1"
                        />
                        <.input
                          field={@replacement_form[:replace]}
                          id="replacement-replace"
                          placeholder="Replace..."
                          class="input input-sm input-bordered flex-1"
                        />
                        <button type="submit" class="btn btn-primary btn-sm">Add</button>
                      </div>
                    </.form>
                  <% end %>

                  <%= if @replacements != %{} do %>
                    <div class="flex items-center justify-between shrink-0 mb-1">
                      <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">
                        {if(@session.status in ~w(noting done),
                          do: "Replacements",
                          else: "Active Replacements"
                        )}
                      </div>
                      <div :if={@session.status not in ~w(noting done)} class="flex gap-1">
                        <button
                          type="button"
                          phx-click="export_replacements"
                          class="btn btn-ghost btn-xs"
                          title="Export as JSON"
                        >
                          <.icon name="hero-arrow-down-tray-micro" class="size-4" />
                        </button>
                        <button
                          type="button"
                          phx-click="toggle_import"
                          class="btn btn-ghost btn-xs"
                          title="Import from JSON"
                        >
                          <.icon name="hero-arrow-up-tray-micro" class="size-4" />
                        </button>
                      </div>
                    </div>
                    <div class="overflow-y-auto space-y-1 pr-1">
                      <%= for {find, replace} <- Enum.sort_by(@replacements, fn {f, _} -> Map.get(@match_counts, f, 0) end, :desc) do %>
                        <div class="flex items-center gap-2 bg-base-100 rounded-lg px-3 py-2 text-sm">
                          <span class="font-mono text-error/70">{find}</span>
                          <.icon
                            name="hero-arrow-right-micro"
                            class="size-4 text-base-content/40 shrink-0"
                          />
                          <span class="font-mono font-medium text-success">{replace}</span>
                          <span class="badge badge-xs badge-ghost ml-auto">
                            {Map.get(@match_counts, find, 0)}
                          </span>
                          <%= if @session.status not in ~w(noting done) do %>
                            <button
                              type="button"
                              phx-click="remove_replacement"
                              phx-value-find={find}
                              class="btn btn-ghost btn-xs text-error"
                            >
                              <.icon name="hero-x-mark-micro" class="size-4" />
                            </button>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div
                      :if={@session.status not in ~w(noting done)}
                      class="flex justify-end shrink-0 mb-1"
                    >
                      <button
                        type="button"
                        phx-click="toggle_import"
                        class="btn btn-ghost btn-xs"
                        title="Import from JSON"
                      >
                        <.icon name="hero-arrow-up-tray-micro" class="size-4" /> Import
                      </button>
                    </div>
                  <% end %>

                  <%= if @import_open? do %>
                    <.form for={%{}} id="import-form" phx-submit="import_replacements" class="mt-2">
                      <textarea
                        name="json"
                        rows="6"
                        placeholder={"{\n  \"find\": \"replace\",\n  ...\n}"}
                        class="textarea textarea-bordered w-full font-mono text-sm"
                        id="import-json-textarea"
                        phx-hook="DropJson"
                      ></textarea>
                      <div class="flex gap-2 mt-2">
                        <button type="submit" class="btn btn-primary btn-sm">Import</button>
                        <button type="button" phx-click="toggle_import" class="btn btn-ghost btn-sm">
                          Cancel
                        </button>
                      </div>
                    </.form>
                  <% end %>

                  <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadJson">
                    export default {
                      mounted() {
                        this.handleEvent("download-json", ({content, filename}) => {
                          const blob = new Blob([content], {type: "application/json"})
                          const url = URL.createObjectURL(blob)
                          const a = document.createElement("a")
                          a.href = url; a.download = filename; a.click()
                          URL.revokeObjectURL(url)
                        })
                      }
                    }
                  </script>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Uploaded files display --%>
        <%= if @session.status in ~w(trimming transcribing reviewing noting done) do %>
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
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReplacementForm">
      export default {
        mounted() {
          this.handleEvent("focus-replace", () => {
            const input = this.el.querySelector("#replacement-replace")
            if (input) requestAnimationFrame(() => input.focus())
          })
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Waveform">
      import WaveSurfer from "wavesurfer.js"
      import RegionsPlugin from "wavesurfer.js/dist/plugins/regions.esm.js"

      function formatTime(seconds) {
        const h = Math.floor(seconds / 3600)
        const m = Math.floor((seconds % 3600) / 60)
        const s = Math.floor(seconds % 60)
        return [h, m, s].map(v => String(v).padStart(2, "0")).join(":")
      }

      function updateLabels(el, region, duration) {
        el.querySelector("[data-trim-start-display]").textContent = formatTime(region.start)
        el.querySelector("[data-trim-end-display]").textContent = formatTime(region.end)
        const keeping = region.end - region.start
        el.querySelector("[data-keeping-display]").textContent =
          `Keeping ${formatTime(keeping)} of ${formatTime(duration)}`
      }

      export default {
        mounted() {
          const el = this.el
          const audioUrl = el.dataset.audioUrl
          const peaksUrl = el.dataset.peaksUrl
          const trimStart = parseFloat(el.dataset.trimStart)
          const trimEnd = parseFloat(el.dataset.trimEnd)
          const container = el.querySelector("[data-waveform]")

          fetch(peaksUrl)
            .then(r => r.json())
            .then(peaksData => {
              const divisor = 1 << (peaksData.bits - 1)
              const normalized = peaksData.data.map(v => v / divisor)
              const duration = (peaksData.length * peaksData.samples_per_pixel) / peaksData.sample_rate

              const regions = RegionsPlugin.create()
              const fitZoom = (container.clientWidth - 16) / duration
              const maxZoom = 50

              const ws = WaveSurfer.create({
                container,
                url: audioUrl,
                peaks: [normalized],
                duration,
                plugins: [regions],
                minPxPerSec: fitZoom,
                waveColor: "#a0aec0",
                progressColor: "#667eea",
                cursorColor: "#667eea",
                height: 128,
              })

              this.ws = ws
              this.regions = regions

              ws.on("decode", () => {
                const region = regions.addRegion({
                  start: trimStart,
                  end: trimEnd,
                  color: "rgba(102, 126, 234, 0.2)",
                  drag: true,
                  resize: true,
                })
                this.region = region
                updateLabels(el, region, duration)
              })

              regions.on("region-update", (region) => {
                updateLabels(el, region, duration)
              })

              regions.on("region-updated", (region) => {
                this.pushEvent("trim_region_updated", {
                  start: region.start,
                  end: region.end,
                })
              })

              // Zoom slider
              const zoomSlider = el.querySelector("[data-zoom]")
              zoomSlider.oninput = (e) => {
                const pct = Number(e.target.value) / 100
                const zoom = fitZoom + pct * (maxZoom - fitZoom)
                ws.zoom(zoom)
              }

              // Play/pause
              const playPauseBtn = el.querySelector("[data-play-pause]")
              const playIcon = el.querySelector("[data-play-icon]")
              const pauseIcon = el.querySelector("[data-pause-icon]")

              const doPlayPause = () => {
                if (this.region && !ws.isPlaying()) {
                  const current = ws.getCurrentTime()
                  if (current < this.region.start || current >= this.region.end) {
                    ws.setTime(this.region.start)
                  }
                }
                ws.playPause()
              }

              playPauseBtn.addEventListener("click", doPlayPause)

              this._keyHandler = (e) => {
                if (e.code === "Space" && !["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)) {
                  e.preventDefault()
                  doPlayPause()
                }
              }
              document.addEventListener("keydown", this._keyHandler)

              ws.on("play", () => {
                playIcon.classList.add("hidden")
                pauseIcon.classList.remove("hidden")
              })

              ws.on("pause", () => {
                playIcon.classList.remove("hidden")
                pauseIcon.classList.add("hidden")
              })

              ws.on("timeupdate", (currentTime) => {
                el.querySelector("[data-current-time]").textContent = formatTime(currentTime)
                if (this.region && currentTime >= this.region.end && ws.isPlaying()) {
                  ws.pause()
                }
              })

              // Preview buttons
              el.querySelector("[data-preview-start]").addEventListener("click", () => {
                if (this.region) {
                  ws.setTime(this.region.start)
                  ws.play()
                }
              })

              el.querySelector("[data-preview-end]").addEventListener("click", () => {
                if (this.region) {
                  const seekTo = Math.max(this.region.start, this.region.end - 3)
                  ws.setTime(seekTo)
                  ws.play()
                }
              })

              // Set region start/end to current playhead
              el.querySelector("[data-set-start]").addEventListener("click", () => {
                if (this.region) {
                  const t = ws.getCurrentTime()
                  if (t < this.region.end) {
                    this.region.setOptions({ start: t })
                    updateLabels(el, this.region, duration)
                    this.pushEvent("trim_region_updated", { start: this.region.start, end: this.region.end })
                  }
                }
              })

              el.querySelector("[data-set-end]").addEventListener("click", () => {
                if (this.region) {
                  const t = ws.getCurrentTime()
                  if (t > this.region.start) {
                    this.region.setOptions({ end: t })
                    updateLabels(el, this.region, duration)
                    this.pushEvent("trim_region_updated", { start: this.region.start, end: this.region.end })
                  }
                }
              })
            })
        },

        destroyed() {
          if (this.ws) this.ws.destroy()
          if (this._keyHandler) document.removeEventListener("keydown", this._keyHandler)
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptAudio">
      export default {
        mounted() {
          const audio = document.getElementById("trimmed-audio")
          if (!audio) return

          this.audio = audio
          this.currentTurnEnd = null
          this.activeBtn = null

          // Delegate clicks on play-turn buttons (event delegation on document
          // since the turns container is a LiveView stream that gets re-rendered)
          this._clickHandler = (e) => {
            const btn = e.target.closest("[data-play-turn]")
            if (!btn) return

            const start = parseFloat(btn.dataset.turnStart)
            const end = parseFloat(btn.dataset.turnEnd)

            if (this.activeBtn === btn && !audio.paused) {
              audio.pause()
              this._setIcon(btn, "play")
              this.activeBtn = null
              return
            }

            // Pause previous
            if (this.activeBtn && this.activeBtn !== btn) {
              this._setIcon(this.activeBtn, "play")
            }

            audio.currentTime = start
            this.currentTurnEnd = end
            this.activeBtn = btn
            this._setIcon(btn, "pause")
            audio.play()
          }
          document.addEventListener("click", this._clickHandler)

          audio.addEventListener("timeupdate", () => {
            if (this.currentTurnEnd !== null && audio.currentTime >= this.currentTurnEnd) {
              audio.pause()
              if (this.activeBtn) {
                this._setIcon(this.activeBtn, "play")
                this.activeBtn = null
              }
              this.currentTurnEnd = null
            }
          })

          audio.addEventListener("pause", () => {
            if (this.activeBtn) {
              this._setIcon(this.activeBtn, "play")
            }
          })
        },

        _setIcon(btn, state) {
          const icon = btn.querySelector("[data-play-icon]")
          if (!icon) return
          if (state === "pause") {
            icon.classList.remove("hero-play-solid")
            icon.classList.add("hero-pause-solid")
          } else {
            icon.classList.remove("hero-pause-solid")
            icon.classList.add("hero-play-solid")
          }
        },

        destroyed() {
          if (this._clickHandler) document.removeEventListener("click", this._clickHandler)
        }
      }
    </script>
    """
  end

  @status_order ~w(uploading trimming transcribing reviewing noting done)

  defp render_markdown(markdown) do
    markdown
    |> MDEx.to_html!()
    |> Phoenix.HTML.raw()
  end

  defp step_complete?(current_status, step_status) do
    current_idx = Enum.find_index(@status_order, &(&1 == current_status)) || 0
    step_idx = Enum.find_index(@status_order, &(&1 == step_status)) || 0
    current_idx >= step_idx
  end

  defp trim_file_label("merged.wav"), do: "Trimming Merged"
  defp trim_file_label("merged.m4a"), do: "Converting to M4A"
  defp trim_file_label(file), do: "Trimming #{Path.basename(file, Path.extname(file))}"

  defp transcription_wait_message(:uploading), do: "Uploading files to transcription service..."
  defp transcription_wait_message(:queued), do: "Waiting in queue..."
  defp transcription_wait_message(_), do: "Waiting in queue..."

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_speed(%{bytes_sent: bytes, started_at: started_at}) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    if elapsed_ms > 100 do
      bytes_per_sec = bytes / (elapsed_ms / 1_000)
      "#{format_bytes(round(bytes_per_sec))}/s"
    else
      ""
    end
  end

  # Derives the active background job from the Registry and session status.
  # Returns :peaks, :trimming, :transcribing, :notes, or nil.
  defp active_job(session) do
    cond do
      Jobs.running?(session.id, :peaks) -> :peaks
      Jobs.running?(session.id, :trim) -> :trimming
      Jobs.running?(session.id, :transcription_submit) -> :transcribing
      session.status == "transcribing" -> :transcribing
      Jobs.running?(session.id, :notes) -> :notes
      true -> nil
    end
  end

  @impl true
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
        Jobs.start_trim(session, start, end_val)

        renamed = socket.assigns.renamed_files

        trim_files =
          Enum.sort(renamed)
          |> Enum.map(&{&1, 0})
          |> Kernel.++([{"merged.wav", 0}, {"merged.m4a", 0}])

        {:noreply,
         socket
         |> assign(:active_job, :trimming)
         |> assign(:trim_files, trim_files)}
    end
  end

  def handle_event("add_replacement", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event(
        "add_replacement",
        %{"replacement" => %{"find" => find, "replace" => replace}},
        socket
      ) do
    find = find |> String.trim() |> String.downcase()
    replace = String.trim(replace)

    cond do
      find == "" ->
        {:noreply, put_flash(socket, :error, "Find field cannot be empty.")}

      find == replace ->
        {:noreply, put_flash(socket, :error, "Find and replace values must be different.")}

      true ->
        session = socket.assigns.session

        case Sessions.add_replacement(session, find, replace) do
          {:ok, session} ->
            {:noreply, recompute_review(socket, session)}

          {:error, changeset} ->
            Logger.error("Failed to save replacement: #{inspect(changeset)}")
            {:noreply, put_flash(socket, :error, "Failed to save replacement.")}
        end
    end
  end

  def handle_event("remove_replacement", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("remove_replacement", %{"find" => find}, socket) do
    session = socket.assigns.session

    case Sessions.remove_replacement(session, find) do
      {:ok, session} ->
        {:noreply, recompute_review(socket, session)}

      {:error, changeset} ->
        Logger.error("Failed to remove replacement: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to remove replacement.")}
    end
  end

  def handle_event("export_replacements", _params, socket) do
    json = Jason.encode!(socket.assigns.replacements, pretty: true)

    {:noreply,
     push_event(socket, "download-json", %{content: json, filename: "replacements.json"})}
  end

  def handle_event("toggle_import", _params, socket) do
    {:noreply, assign(socket, import_open?: !socket.assigns.import_open?)}
  end

  def handle_event("import_replacements", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("import_replacements", %{"json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          case Sessions.add_replacements(socket.assigns.session, map) do
            {:ok, session} ->
              {:noreply,
               socket
               |> assign(import_open?: false)
               |> recompute_review(session)
               |> put_flash(:info, "Imported #{map_size(map)} replacement(s).")}

            {:error, reason} ->
              Logger.error("Failed to import replacements: #{inspect(reason)}")
              {:noreply, put_flash(socket, :error, "Failed to import.")}
          end
        else
          {:noreply, put_flash(socket, :error, "All keys and values must be strings.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid JSON object.")}
    end
  end

  def handle_event("validate_replacement", %{"replacement" => params}, socket) do
    form = to_form(params, as: :replacement)
    {:noreply, assign(socket, :replacement_form, form)}
  end

  def handle_event("prefill_replacement", %{"word" => word}, socket) do
    form = to_form(%{"find" => word, "replace" => ""}, as: :replacement)

    {:noreply,
     socket
     |> assign(:replacement_form, form)
     |> push_event("focus-replace", %{})}
  end

  def handle_event("start_edit", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("start_edit", %{"turn-id" => id_str}, socket) do
    turn_id = String.to_integer(id_str)
    edits = socket.assigns.edits

    text =
      case Map.fetch(edits, id_str) do
        {:ok, edited_text} ->
          edited_text

        :error ->
          socket.assigns.raw_turns
          |> Enum.find(&(&1.id == turn_id))
          |> then(fn turn ->
            replacements = socket.assigns.replacements

            {[replaced_turn], _counts} =
              Transcript.apply_replacements(
                [turn],
                replacements,
                socket.assigns.compiled_patterns
              )

            replaced_turn
            |> Map.get(:display_words)
            |> Enum.map_join(fn w -> w.word end)
            |> String.trim()
          end)
      end

    edit_form = to_form(%{"text" => text}, as: :edit)
    turn = find_display_turn(socket, turn_id)
    editing_turn = Map.merge(turn, %{editing?: true, edit_form: edit_form})

    {:noreply,
     socket
     |> assign(:editing_turn_id, turn_id)
     |> stream_insert(:turns, editing_turn)}
  end

  def handle_event("cancel_edit", _params, socket) do
    turn_id = socket.assigns.editing_turn_id
    turn = find_display_turn(socket, turn_id)
    normal_turn = Map.merge(turn, %{editing?: false, edit_form: nil})

    {:noreply,
     socket
     |> assign(:editing_turn_id, nil)
     |> stream_insert(:turns, normal_turn)}
  end

  def handle_event("save_edit", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("save_edit", %{"edit" => %{"text" => text}}, socket) do
    session = socket.assigns.session
    turn_id = socket.assigns.editing_turn_id

    case Sessions.add_edit(session, turn_id, String.trim(text)) do
      {:ok, session} ->
        {:noreply, recompute_review(socket, session)}

      {:error, changeset} ->
        Logger.error("Failed to save edit: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to save edit.")}
    end
  end

  def handle_event("delete_turn", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("delete_turn", %{"turn-id" => id_str}, socket) do
    session = socket.assigns.session

    case Sessions.add_edit(session, String.to_integer(id_str), "") do
      {:ok, session} ->
        {:noreply, recompute_review(socket, session)}

      {:error, changeset} ->
        Logger.error("Failed to delete turn: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to delete turn.")}
    end
  end

  def handle_event("remove_edit", _, %{assigns: %{session: %{status: status}}} = socket)
      when status in ["noting", "done"] do
    {:noreply, socket}
  end

  def handle_event("remove_edit", %{"turn-id" => id_str}, socket) do
    session = socket.assigns.session
    turn_id = String.to_integer(id_str)

    case Sessions.remove_edit(session, turn_id) do
      {:ok, session} ->
        {:noreply, recompute_review(socket, session)}

      {:error, changeset} ->
        Logger.error("Failed to remove edit: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to remove edit.")}
    end
  end

  def handle_event("finalize", _params, socket) do
    session = socket.assigns.session

    case Sessions.finalize(session) do
      {:ok, session} ->
        %{raw_turns: raw_turns, replacements: replacements, edits: edits} = socket.assigns
        done_stats = compute_done_stats(session, raw_turns, replacements, edits)

        {:noreply,
         socket
         |> assign(:session, session)
         |> assign(:done_stats, done_stats)
         |> assign(:read_only?, true)}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Session is not in the reviewing state.")}

      {:error, changeset} ->
        Logger.error("Failed to finalize session: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to finalize.")}
    end
  end

  def handle_event("generate_notes", %{"context" => context}, socket) do
    session = socket.assigns.session
    context = String.trim(context)
    context_value = if context == "", do: nil, else: context

    case Sessions.update_session_notes(session, %{context: context_value, notes_error: nil}) do
      {:ok, session} ->
        case Jobs.start_notes_generation(session) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> assign(:session, session)
             |> assign(:active_job, :notes)
             |> put_flash(:info, "Generating notes...")}

          {:error, :already_running} ->
            {:noreply,
             socket
             |> assign(:session, session)
             |> assign(:active_job, :notes)}
        end

      {:error, changeset} ->
        Logger.error("Failed to save context: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to save context.")}
    end
  end

  def handle_event("edit_session", _params, socket) do
    session = socket.assigns.session

    case Sessions.edit_session(session) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:session, session)
         |> assign(:done_stats, nil)
         |> assign(:read_only?, false)}

      {:error, :invalid_status} ->
        {:noreply, put_flash(socket, :error, "Session is not in the done state.")}

      {:error, changeset} ->
        Logger.error("Failed to edit session: #{inspect(changeset)}")
        {:noreply, put_flash(socket, :error, "Failed to edit session.")}
    end
  end

  def handle_event("delete_session", _params, socket) do
    session = socket.assigns.session
    campaign = socket.assigns.campaign

    Jobs.cancel_existing_transcription(session)
    File.rm_rf(Uploads.session_dir(session.id))
    {:ok, _} = Sessions.delete_session(session)

    {:noreply,
     socket
     |> put_flash(:info, "Session deleted.")
     |> push_navigate(to: ~p"/campaigns/#{campaign.slug}")}
  end

  @impl true
  def handle_info({:peaks_ready, session}, socket) do
    {:noreply,
     socket
     |> assign(:session, %{socket.assigns.session | duration_seconds: session.duration_seconds})
     |> assign(:active_job, nil)
     |> assign_audio_urls(session)
     |> put_flash(:info, "Waveform ready.")}
  end

  def handle_info({:peaks_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:active_job, nil)
     |> put_flash(:error, "Waveform generation failed: #{reason}")}
  end

  def handle_info({:trim_progress, file, percent}, socket) do
    trim_files =
      Enum.map(socket.assigns.trim_files, fn
        {^file, _} -> {file, percent}
        other -> other
      end)

    {:noreply, assign(socket, :trim_files, trim_files)}
  end

  def handle_info({:trim_complete, :ok, _session}, socket) do
    {:noreply, put_flash(socket, :info, "Audio trimmed. Starting transcription...")}
  end

  def handle_info({:transcription_status_changed, _status}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)
    Phoenix.PubSub.subscribe(Noter.PubSub, "transcription:#{session.id}")

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, active_job(session))
     |> assign(:transcription_progress, nil)
     |> assign(:transcription_status, :uploading)}
  end

  def handle_info({:trim_complete, {:error, reason}}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> put_flash(:error, "Trimming failed: #{reason}")}
  end

  def handle_info({:upload_progress, bytes_sent, total_bytes}, socket) do
    upload_progress = socket.assigns.upload_progress

    started_at =
      case upload_progress do
        %{started_at: t} -> t
        _ -> System.monotonic_time(:millisecond)
      end

    {:noreply,
     assign(socket, :upload_progress, %{
       bytes_sent: bytes_sent,
       total_bytes: total_bytes,
       started_at: started_at
     })}
  end

  def handle_info({:transcription_submitted, _job_id}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    Phoenix.PubSub.subscribe(Noter.PubSub, "transcription:#{session.id}")

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:upload_progress, nil)
     |> assign(:transcription_status, :queued)}
  end

  def handle_info({:transcription_submit_failed, reason}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:upload_progress, nil)
     |> put_flash(:error, "Failed to start transcription: #{reason}")}
  end

  def handle_info({:transcription, :progress, data}, socket) do
    {:noreply, assign(socket, :transcription_progress, data)}
  end

  def handle_info({:transcription, :queued, _}, socket) do
    {:noreply,
     socket
     |> assign(:transcription_progress, nil)
     |> assign(:transcription_status, :queued)}
  end

  def handle_info({:transcription, :file_start, data}, socket) do
    progress = %{overall_pct: prev_overall_pct(socket), file: data.file, file_pct: 0}
    {:noreply, assign(socket, :transcription_progress, progress)}
  end

  def handle_info({:transcription, :file_done, _data}, socket) do
    {:noreply, socket}
  end

  def handle_info({:transcription, :done, _}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:transcription_progress, nil)
     |> assign_review_state(session)
     |> put_flash(:info, "Transcription complete.")}
  end

  def handle_info({:transcription, :error, %{error: msg}}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:transcription_progress, nil)
     |> put_flash(:error, "Transcription failed: #{msg}")}
  end

  def handle_info({:transcription, :cancelled, _}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:transcription_progress, nil)}
  end

  def handle_info({:notes_progress, %{stage: :extracting} = progress}, socket) do
    {:noreply, assign(socket, :notes_progress, progress)}
  end

  def handle_info({:notes_progress, %{stage: :complete}}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:notes_progress, nil)
     |> put_flash(:info, "Notes generated successfully.")}
  end

  def handle_info({:notes_progress, %{stage: :error, error: reason}}, socket) do
    session = Sessions.get_session_with_campaign!(socket.assigns.session.id)

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:active_job, nil)
     |> assign(:notes_progress, nil)
     |> put_flash(:error, "Notes generation failed: #{reason}")}
  end

  defp reconnect_notes_progress(socket, session) do
    if session.status == "noting" do
      assign(socket, :notes_progress, Jobs.get_notes_progress(session.id))
    else
      socket
    end
  end

  defp reconnect_transcription(socket, session) do
    cond do
      # Upload to transcription service still in progress
      session.status == "transcribing" and Jobs.running?(session.id, :transcription_submit) ->
        socket
        |> assign(:active_job, :transcribing)
        |> assign(:transcription_status, :uploading)

      # Transcription job submitted, check its status
      session.status == "transcribing" and session.transcription_job_id != nil ->
        Phoenix.PubSub.subscribe(Noter.PubSub, "transcription:#{session.id}")
        reconnect_transcription_job(socket, session)

      # Status is transcribing but nothing is running and no job was submitted — restart
      session.status == "transcribing" and session.transcription_job_id == nil ->
        Jobs.start_transcription_submit(session)

        socket
        |> assign(:active_job, :transcribing)
        |> assign(:transcription_status, :uploading)

      true ->
        socket
    end
  end

  defp reconnect_transcription_job(socket, session) do
    if SSEClient.running?(session.id) do
      progress = SSEClient.get_progress(session.id)

      socket
      |> assign(:active_job, :transcribing)
      |> assign(:transcription_progress, progress)
      |> assign(:transcription_status, :transcribing)
    else
      case Transcription.poll_job(session.transcription_job_id) do
        {:ok, %{"status" => "done", "result" => result}} ->
          Sessions.update_transcription(session, %{
            status: "reviewing",
            transcript_json: Jason.encode!(result)
          })

          session = Sessions.get_session_with_campaign!(session.id)
          assign(socket, :session, session)

        {:ok, %{"status" => status}} when status in ~w(failed cancelled) ->
          Sessions.update_transcription(session, %{status: "trimming"})
          session = Sessions.get_session_with_campaign!(session.id)

          socket
          |> assign(:session, session)
          |> put_flash(:error, "Transcription #{status}.")

        {:ok, _} ->
          {:ok, _pid} =
            DynamicSupervisor.start_child(
              Noter.TranscriptionSupervisor,
              {Noter.Transcription.SSEClient,
               session_id: session.id, job_id: session.transcription_job_id}
            )

          assign(socket, :active_job, :transcribing)

        {:error, reason} ->
          put_flash(socket, :error, "Failed to check transcription status: #{reason}")
      end
    end
  end

  defp retry_peaks_if_needed(socket, session) do
    has_aac? = File.exists?(Path.join(Uploads.session_dir(session.id), "merged.aac"))
    needs_pipeline? = is_nil(session.duration_seconds) or not socket.assigns.has_merged_audio?
    already_running? = Jobs.running?(session.id, :peaks)

    if session.status == "trimming" and needs_pipeline? and has_aac? and not already_running? do
      Jobs.start_peaks(session)
      assign(socket, :active_job, :peaks)
    else
      socket
    end
  end

  defp prev_overall_pct(socket) do
    case socket.assigns.transcription_progress do
      %{overall_pct: pct} -> pct
      _ -> 0.0
    end
  end

  defp assign_audio_urls(socket, session) do
    if session.status in ~w(trimming transcribing reviewing noting done) and
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

  defp assign_trim_files(socket, renamed_files, true = _trimming?) do
    trim_files =
      Enum.sort(renamed_files)
      |> Enum.map(&{&1, 0})
      |> Kernel.++([{"merged.wav", 0}, {"merged.m4a", 0}])

    assign(socket, :trim_files, trim_files)
  end

  defp assign_trim_files(socket, _renamed_files, false = _trimming?), do: socket
end
