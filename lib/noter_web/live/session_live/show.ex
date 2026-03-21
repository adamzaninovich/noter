defmodule NoterWeb.SessionLive.Show do
  use NoterWeb, :live_view

  alias Noter.Sessions
  alias Noter.Uploads
  alias Noter.Transcription
  alias Noter.Transcription.Transcript

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
      |> assign(:has_merged_audio?, File.exists?(Path.join(session_dir, "merged.aac")))
      |> assign(:has_vocab?, File.exists?(Path.join(session_dir, "vocab.txt")))
      |> assign(:steps, @steps)
      |> assign(:trimming?, false)
      |> assign(:generating_peaks?, false)
      |> assign(:trim_start, session.trim_start_seconds)
      |> assign(:trim_end, session.trim_end_seconds)
      |> assign(:transcribing?, false)
      |> assign(:transcription_progress, nil)
      |> assign(:transcription_status, nil)
      |> assign_audio_urls(session)
      |> retry_peaks_if_needed(session)
      |> reconnect_transcription(session)
      |> assign_review_state(session)

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
        <ul class="steps w-full">
          <%= for {status_key, label} <- @steps do %>
            <li class={["step", step_complete?(@session.status, status_key) && "step-primary"]}>
              {label}
            </li>
          <% end %>
        </ul>

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
        <%= if @trimming? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Trimming Audio</h2>
              <div class="space-y-3 mt-2">
                <div class="flex items-center justify-between text-sm">
                  <span class="text-base-content/70">
                    {trim_step_label(@trim_current_file)}
                  </span>
                  <span class="font-mono text-base-content/70">
                    {@trim_completed + 1}/{@trim_total}
                  </span>
                </div>
                <progress
                  class="progress progress-primary w-full"
                  value={@trim_completed}
                  max={@trim_total}
                >
                </progress>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Transcription card --%>
        <%= if @session.status == "trimmed" and not @transcribing? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Transcription</h2>
              <p class="text-sm text-base-content/60">
                Send trimmed audio files to the transcription service.
              </p>
              <div class="flex justify-end mt-2">
                <button
                  id="start-transcription-btn"
                  phx-click="start_transcription"
                  class="btn btn-primary"
                  phx-disable-with="Submitting..."
                >
                  Start Transcription
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Transcription progress --%>
        <%= if @transcribing? do %>
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
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Transcript review card --%>
        <%= if @reviewing? do %>
          <div class="card bg-base-200 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-lg">Transcript Review</h2>
              <p class="text-sm text-base-content/60 mb-2">
                Click any word to prefill the find field. Add replacements to fix transcription errors.
              </p>
              <div class="flex gap-6">
                <%!-- Left: transcript viewer --%>
                <div class="flex-1 min-w-0 space-y-3">
                  <div
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
                    <div :for={{id, turn} <- @streams.turns} id={id}>
                      {turn_row(%{turn: turn, speaker_colors: @speaker_colors})}
                    </div>
                  </div>
                </div>

                <%!-- Right: replacements panel --%>
                <div class="w-80 shrink-0 flex flex-col max-h-[70vh]">
                  <.form
                    for={@replacement_form}
                    id="replacement-form"
                    phx-submit="add_replacement"
                    phx-change="validate_replacement"
                    class="shrink-0 mb-4"
                  >
                    <div class="flex items-center gap-2 [&_.fieldset]:mb-0">
                      <.input
                        field={@replacement_form[:find]}
                        placeholder="Find..."
                        class="input input-sm input-bordered flex-1"
                      />
                      <.input
                        field={@replacement_form[:replace]}
                        placeholder="Replace..."
                        class="input input-sm input-bordered flex-1"
                      />
                      <button type="submit" class="btn btn-primary btn-sm">Add</button>
                    </div>
                  </.form>

                  <%= if @replacements != %{} do %>
                    <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wide shrink-0 mb-1">
                      Active Replacements
                    </div>
                    <div class="overflow-y-auto space-y-1 pr-1">
                      <%= for {find, replace} <- @replacements do %>
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
                          <button
                            type="button"
                            phx-click="remove_replacement"
                            phx-value-find={find}
                            class="btn btn-ghost btn-xs text-error"
                          >
                            <.icon name="hero-x-mark-micro" class="size-4" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
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

  defp turn_row(assigns) do
    ~H"""
    <div class="flex items-start gap-2 py-2 px-2 rounded-lg hover:bg-base-100 transition-colors">
      <button
        type="button"
        data-play-turn
        data-turn-start={@turn.start}
        data-turn-end={@turn.end}
        class="btn btn-ghost btn-xs mt-0.5 shrink-0"
      >
        <span data-play-icon class="hero-play-solid size-3"></span>
      </button>
      <span class="badge badge-ghost badge-sm font-mono mt-0.5 shrink-0">
        {format_time(@turn.start)}
      </span>
      <span class={[
        "badge badge-sm mt-0.5 shrink-0",
        Map.get(@speaker_colors, @turn.speaker, "badge-neutral")
      ]}>
        {@turn.speaker}
      </span>
      <p class="text-sm leading-relaxed flex-1">
        <%= for word <- @turn.display_words do %>
          {leading_space(word.word)}<span
            class={[
              "cursor-pointer hover:outline hover:outline-1 hover:outline-base-content/20 rounded-sm",
              word.replaced? && "bg-success/20 text-success font-medium"
            ]}
            phx-click="prefill_replacement"
            phx-value-word={strip_display_word(word.word)}
          >{String.trim_leading(word.word)}</span>
        <% end %>
      </p>
    </div>
    """
  end

  defp format_time(seconds) when is_number(seconds) do
    total = trunc(seconds)
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    [h, m, s]
    |> Enum.map(&String.pad_leading(Integer.to_string(&1), 2, "0"))
    |> Enum.join(":")
  end

  defp format_time(_), do: "00:00:00"

  defp leading_space(word) do
    case Regex.run(~r/\A(\s+)/, word) do
      [_, ws] -> ws
      _ -> ""
    end
  end

  defp strip_display_word(word) do
    word
    |> String.trim_leading()
    |> String.replace(~r/[.,;:!?\-"')\]]+\z/, "")
  end

  @speaker_palette ~w(badge-primary badge-secondary badge-accent badge-info badge-success badge-warning badge-error)

  @status_order ~w(uploading uploaded trimmed transcribing transcribed reviewing done)

  defp step_complete?(current_status, step_status) do
    current_idx = Enum.find_index(@status_order, &(&1 == current_status)) || 0
    step_idx = Enum.find_index(@status_order, &(&1 == step_status)) || 0
    current_idx >= step_idx
  end

  defp trim_step_label("merged.wav"), do: "Trimming merged audio"
  defp trim_step_label("merged.m4a"), do: "Converting to M4A for playback"

  defp trim_step_label(file) do
    name = Path.basename(file, Path.extname(file))
    "Trimming speaker: #{name}"
  end

  defp transcription_wait_message(:uploading), do: "Uploading files to transcription service..."
  defp transcription_wait_message(:queued), do: "Waiting in queue..."
  defp transcription_wait_message(_), do: "Waiting in queue..."

  defp status_badge_class(status) do
    case status do
      "done" -> "badge-success"
      status when status in ~w(uploading transcribing reviewing) -> "badge-info"
      _ -> "badge-soft badge-info"
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
        lv = self()
        session = Sessions.get_session_with_campaign!(session.id)

        Task.start(fn ->
          on_progress = fn file, {completed, total} ->
            send(lv, {:trim_progress, file, completed, total})
          end

          result = Uploads.trim_session(session, start, end_val, on_progress)
          send(lv, {:trim_complete, result, start, end_val})
        end)

        {:noreply,
         socket
         |> assign(:trimming?, true)
         |> assign(:trim_current_file, "...")
         |> assign(:trim_completed, 0)
         |> assign(:trim_total, 0)}
    end
  end

  def handle_event("start_transcription", _params, socket) do
    session = socket.assigns.session
    lv = self()

    Phoenix.PubSub.subscribe(Noter.PubSub, "transcription:#{session.id}")

    Task.start(fn ->
      case Transcription.submit_job(session.id) do
        {:ok, job_id} -> send(lv, {:transcription_submitted, job_id})
        {:error, reason} -> send(lv, {:transcription_submit_failed, reason})
      end
    end)

    {:noreply,
     socket
     |> assign(:transcribing?, true)
     |> assign(:transcription_progress, nil)
     |> assign(:transcription_status, :uploading)}
  end

  def handle_event(
        "add_replacement",
        %{"replacement" => %{"find" => find, "replace" => replace}},
        socket
      ) do
    find = String.trim(find)
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

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to save replacement.")}
        end
    end
  end

  def handle_event("remove_replacement", %{"find" => find}, socket) do
    session = socket.assigns.session

    case Sessions.remove_replacement(session, find) do
      {:ok, session} ->
        {:noreply, recompute_review(socket, session)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to remove replacement.")}
    end
  end

  def handle_event("validate_replacement", %{"replacement" => params}, socket) do
    form = to_form(params, as: :replacement)
    {:noreply, assign(socket, :replacement_form, form)}
  end

  def handle_event("prefill_replacement", %{"word" => word}, socket) do
    form = to_form(%{"find" => word, "replace" => ""}, as: :replacement)
    {:noreply, assign(socket, :replacement_form, form)}
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

  def handle_info({:trim_progress, file, completed, total}, socket) do
    {:noreply,
     socket
     |> assign(:trim_current_file, file)
     |> assign(:trim_completed, completed)
     |> assign(:trim_total, total)}
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

  def handle_info({:transcription_submitted, job_id}, socket) do
    session = socket.assigns.session

    {:ok, session} =
      Sessions.update_transcription(session, %{
        status: "transcribing",
        transcription_job_id: job_id
      })

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Noter.TranscriptionSupervisor,
        {Noter.Transcription.SSEClient, session_id: session.id, job_id: job_id}
      )

    {:noreply,
     socket
     |> assign(:session, session)
     |> assign(:transcription_status, :queued)}
  end

  def handle_info({:transcription_submit_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:transcribing?, false)
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
     |> assign(:transcribing?, false)
     |> assign(:transcription_progress, nil)
     |> assign_review_state(session)
     |> put_flash(:info, "Transcription complete.")}
  end

  def handle_info({:transcription, :error, %{error: msg}}, socket) do
    {:noreply,
     socket
     |> assign(:transcribing?, false)
     |> assign(:transcription_progress, nil)
     |> put_flash(:error, "Transcription failed: #{msg}")}
  end

  defp reconnect_transcription(socket, session) do
    if session.status == "transcribing" and session.transcription_job_id do
      Phoenix.PubSub.subscribe(Noter.PubSub, "transcription:#{session.id}")

      if Noter.Transcription.SSEClient.running?(session.id) do
        progress = Noter.Transcription.SSEClient.get_progress(session.id)

        socket
        |> assign(:transcribing?, true)
        |> assign(:transcription_progress, progress)
        |> assign(:transcription_status, :transcribing)
      else
        case Transcription.poll_job(session.transcription_job_id) do
          {:ok, %{"status" => "done", "result" => result}} ->
            Sessions.update_transcription(session, %{
              status: "transcribed",
              transcript_json: Jason.encode!(result)
            })

            session = Sessions.get_session_with_campaign!(session.id)
            assign(socket, :session, session)

          {:ok, %{"status" => "failed", "error" => error}} ->
            put_flash(socket, :error, "Transcription failed: #{error}")

          {:ok, _} ->
            {:ok, _pid} =
              DynamicSupervisor.start_child(
                Noter.TranscriptionSupervisor,
                {Noter.Transcription.SSEClient,
                 session_id: session.id, job_id: session.transcription_job_id}
              )

            assign(socket, :transcribing?, true)

          {:error, reason} ->
            put_flash(socket, :error, "Failed to check transcription status: #{reason}")
        end
      end
    else
      socket
    end
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

  defp prev_overall_pct(socket) do
    case socket.assigns.transcription_progress do
      %{overall_pct: pct} -> pct
      _ -> 0.0
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

  defp assign_review_state(socket, session) do
    if session.status in ~w(transcribed reviewing) do
      raw_turns = Transcript.parse_turns(session.transcript_json)
      replacements = Map.get(session.corrections, "replacements", %{})
      display_turns = Transcript.apply_replacements(raw_turns, replacements)
      match_counts = Transcript.match_counts(raw_turns, replacements)
      speakers = raw_turns |> Enum.map(& &1.speaker) |> Enum.uniq()
      speaker_colors = build_speaker_colors(speakers)

      socket
      |> assign(:reviewing?, true)
      |> assign(:raw_turns, raw_turns)
      |> assign(:replacements, replacements)
      |> assign(:match_counts, match_counts)
      |> assign(:speaker_colors, speaker_colors)
      |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
      |> assign(:trimmed_audio_url, ~p"/sessions/#{session.id}/audio/trimmed")
      |> stream(:turns, display_turns, reset: true)
    else
      socket
      |> assign(:reviewing?, false)
      |> assign(:raw_turns, [])
      |> assign(:replacements, %{})
      |> assign(:match_counts, %{})
      |> assign(:speaker_colors, %{})
      |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
      |> assign(:trimmed_audio_url, nil)
    end
  end

  defp recompute_review(socket, session) do
    raw_turns = socket.assigns.raw_turns
    replacements = Map.get(session.corrections, "replacements", %{})
    display_turns = Transcript.apply_replacements(raw_turns, replacements)
    match_counts = Transcript.match_counts(raw_turns, replacements)

    socket
    |> assign(:session, session)
    |> assign(:replacements, replacements)
    |> assign(:match_counts, match_counts)
    |> assign(:replacement_form, to_form(%{"find" => "", "replace" => ""}, as: :replacement))
    |> stream(:turns, display_turns, reset: true)
  end

  defp build_speaker_colors(speakers) do
    speakers
    |> Enum.with_index()
    |> Enum.into(%{}, fn {speaker, idx} ->
      {speaker, Enum.at(@speaker_palette, rem(idx, length(@speaker_palette)))}
    end)
  end
end
