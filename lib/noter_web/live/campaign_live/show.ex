defmodule NoterWeb.CampaignLive.Show do
  use NoterWeb, :live_view

  alias Noter.Campaigns

  @impl true
  def mount(%{"campaign_slug" => slug}, _session, socket) do
    campaign = Campaigns.get_campaign_by_slug!(slug)
    name_changeset = Campaigns.change_campaign(campaign)

    if connected?(socket), do: Noter.Sessions.subscribe(campaign.id)

    player_rows =
      campaign.player_map
      |> Enum.map(fn {discord, character} ->
        %{id: System.unique_integer([:positive]), discord: discord, character: character}
      end)

    replacement_rows =
      campaign.common_replacements
      |> Enum.map(fn {find, replace} ->
        %{id: System.unique_integer([:positive]), find: find, replace: replace}
      end)

    {:ok,
     socket
     |> assign(:page_title, campaign.name)
     |> assign(:campaign, campaign)
     |> assign(:name_form, to_form(name_changeset))
     |> assign(:player_rows, player_rows)
     |> assign(:editing_player_map, false)
     |> assign(:replacement_rows, replacement_rows)
     |> assign(:editing_replacements, false)
     |> assign(:importing_replacements?, false)
     |> assign(:sessions_empty?, campaign.sessions == [])
     |> assign(:settings_open?, campaign.sessions == [] and campaign.player_map == %{})
     |> stream(:sessions, campaign.sessions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <h1 class="text-3xl font-bold">{@campaign.name}</h1>
        </div>

        <%!-- Sessions Section --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-lg">Sessions</h2>
              <.link
                navigate={~p"/campaigns/#{@campaign.slug}/sessions/new"}
                class="btn btn-sm btn-primary"
                id="new-session-btn"
              >
                <.icon name="hero-plus" class="size-4" /> New Session
              </.link>
            </div>

            <div :if={@sessions_empty?} class="text-center py-6 text-base-content/50">
              No sessions yet.
            </div>
            <div id="sessions" phx-update="stream" class="space-y-2 mt-2">
              <.link
                :for={{id, session} <- @streams.sessions}
                id={id}
                navigate={~p"/campaigns/#{@campaign.slug}/sessions/#{session.slug}"}
                class="flex items-center justify-between p-3 bg-base-100 rounded-lg border border-base-300 hover:border-primary/40 transition-colors cursor-pointer"
              >
                <div class="flex items-center gap-3">
                  <span class="font-medium">{session.name}</span>
                  <span class={["badge badge-sm", status_badge_class(session.status)]}>
                    {session.status}
                  </span>
                </div>
                <.icon name="hero-chevron-right" class="size-5 text-base-content/30" />
              </.link>
            </div>
          </div>
        </div>

        <%!-- Campaign Settings (collapsible) --%>
        <div class="collapse collapse-arrow bg-base-200 shadow-sm" id="campaign-settings">
          <input type="checkbox" checked={@settings_open?} phx-click="toggle_settings" />
          <div class="collapse-title font-medium flex items-center gap-2">
            <.icon name="hero-cog-6-tooth" class="size-5" /> Campaign Settings
          </div>
          <div class="collapse-content space-y-6">
            <%!-- Edit Name --%>
            <div>
              <h3 class="text-sm font-semibold text-base-content/70 mb-2">Campaign Name</h3>
              <.form for={@name_form} id="name-form" phx-submit="save_name">
                <div class="flex gap-3 items-center">
                  <div class="flex-1 [&_.fieldset]:mb-0">
                    <.input field={@name_form[:name]} type="text" />
                  </div>
                  <.button type="submit" class="btn btn-primary btn-sm">Save</.button>
                </div>
              </.form>
            </div>

            <%!-- Player Map --%>
            <div class="card bg-base-100 border border-base-content/5 mt-2">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="card-title text-sm">Player Map</h3>
                    <p class="text-sm text-base-content/60">
                      Map Discord usernames to character names for transcript processing.
                    </p>
                  </div>
                  <%= if !@editing_player_map do %>
                    <button type="button" phx-click="edit_player_map" class="btn btn-sm btn-ghost">
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                  <% end %>
                </div>

                <%= if @editing_player_map do %>
                  <.form
                    for={%{}}
                    id="player-map-form"
                    phx-change="update_players"
                    phx-submit="save_player_map"
                  >
                    <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2">
                      <table class="table" id="player-map-table">
                        <thead>
                          <tr>
                            <th>Discord Name</th>
                            <th>Character Name</th>
                            <th></th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= if @player_rows == [] do %>
                            <tr>
                              <td colspan="3" class="text-center text-base-content/50 py-6">
                                No players added yet.
                              </td>
                            </tr>
                          <% end %>
                          <tr :for={row <- @player_rows} id={"player-row-#{row.id}"}>
                            <td>
                              <input
                                type="text"
                                value={row.discord}
                                name={"player[#{row.id}][discord]"}
                                placeholder="Discord username"
                                class="input input-bordered input-sm w-full"
                                id={"player-discord-#{row.id}"}
                                phx-hook=".PlayerInput"
                              />
                            </td>
                            <td>
                              <input
                                type="text"
                                value={row.character}
                                name={"player[#{row.id}][character]"}
                                placeholder="Character name"
                                class="input input-bordered input-sm w-full"
                                id={"player-character-#{row.id}"}
                                phx-hook=".PlayerInput"
                              />
                            </td>
                            <td>
                              <button
                                type="button"
                                phx-click="remove_player"
                                phx-value-id={row.id}
                                class="btn btn-ghost btn-sm btn-square text-error"
                              >
                                <.icon name="hero-x-mark" class="size-4" />
                              </button>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>

                    <div class="flex gap-2 mt-2">
                      <button type="button" phx-click="add_player" class="btn btn-sm btn-outline">
                        <.icon name="hero-plus" class="size-4" /> Add Player
                      </button>
                      <.button type="submit" class="btn btn-sm btn-primary">Save</.button>
                      <button
                        type="button"
                        phx-click="cancel_edit_player_map"
                        class="btn btn-sm btn-ghost"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".PlayerInput">
                    export default {
                      mounted() {
                        this.el.addEventListener("keydown", (e) => {
                          if (e.key === "Enter") {
                            e.preventDefault()
                            this.pushEvent("add_player", {}, (reply) => {
                              requestAnimationFrame(() => {
                                const table = this.el.closest("table")
                                const lastRow = table.querySelector("tbody tr:last-child")
                                if (lastRow) {
                                  const firstInput = lastRow.querySelector("input")
                                  if (firstInput) firstInput.focus()
                                }
                              })
                            })
                          }
                        })
                      }
                    }
                  </script>
                <% else %>
                  <%= if @campaign.player_map == %{} do %>
                    <div class="text-center py-4 text-base-content/50">
                      No players mapped yet.
                    </div>
                  <% else %>
                    <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2">
                      <table class="table">
                        <thead>
                          <tr>
                            <th>Discord Name</th>
                            <th>Character Name</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr :for={{discord, character} <- @campaign.player_map}>
                            <td class="font-mono">{discord}</td>
                            <td>{character}</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%!-- Common Replacements --%>
            <div class="card bg-base-100 border border-base-content/5 mt-2">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="card-title text-sm">Common Replacements</h3>
                    <p class="text-sm text-base-content/60">
                      Find/replace pairs applied to every session when review starts.
                    </p>
                  </div>
                  <div :if={!@editing_replacements} class="flex gap-1">
                    <button
                      type="button"
                      phx-click="toggle_import_replacements"
                      class="btn btn-sm btn-ghost"
                      title="Import from JSON"
                    >
                      <.icon name="hero-arrow-up-tray" class="size-4" /> Import
                    </button>
                    <button
                      type="button"
                      phx-click="edit_replacements"
                      class="btn btn-sm btn-ghost"
                    >
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                  </div>
                </div>

                <%= if @editing_replacements do %>
                  <.form
                    for={%{}}
                    id="replacements-form"
                    phx-change="update_replacement_rows"
                    phx-submit="save_replacements"
                  >
                    <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2">
                      <table class="table" id="replacements-table">
                        <thead>
                          <tr>
                            <th>Find</th>
                            <th>Replace</th>
                            <th></th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= if @replacement_rows == [] do %>
                            <tr>
                              <td colspan="3" class="text-center text-base-content/50 py-6">
                                No replacements added yet.
                              </td>
                            </tr>
                          <% end %>
                          <tr :for={row <- @replacement_rows} id={"replacement-row-#{row.id}"}>
                            <td>
                              <input
                                type="text"
                                value={row.find}
                                name={"replacement[#{row.id}][find]"}
                                placeholder="Find text"
                                class="input input-bordered input-sm w-full"
                                id={"replacement-find-#{row.id}"}
                                phx-hook=".ReplacementInput"
                              />
                            </td>
                            <td>
                              <input
                                type="text"
                                value={row.replace}
                                name={"replacement[#{row.id}][replace]"}
                                placeholder="Replace with"
                                class="input input-bordered input-sm w-full"
                                id={"replacement-replace-#{row.id}"}
                                phx-hook=".ReplacementInput"
                              />
                            </td>
                            <td>
                              <button
                                type="button"
                                phx-click="remove_replacement_row"
                                phx-value-id={row.id}
                                class="btn btn-ghost btn-sm btn-square text-error"
                              >
                                <.icon name="hero-x-mark" class="size-4" />
                              </button>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>

                    <div class="flex gap-2 mt-2">
                      <button
                        type="button"
                        phx-click="add_replacement_row"
                        class="btn btn-sm btn-outline"
                      >
                        <.icon name="hero-plus" class="size-4" /> Add Row
                      </button>
                      <.button type="submit" class="btn btn-sm btn-primary">Save</.button>
                      <button
                        type="button"
                        phx-click="cancel_edit_replacements"
                        class="btn btn-sm btn-ghost"
                      >
                        Cancel
                      </button>
                    </div>
                  </.form>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".ReplacementInput">
                    export default {
                      mounted() {
                        this.el.addEventListener("keydown", (e) => {
                          if (e.key === "Enter") {
                            e.preventDefault()
                            this.pushEvent("add_replacement_row", {}, (reply) => {
                              requestAnimationFrame(() => {
                                const table = this.el.closest("table")
                                const lastRow = table.querySelector("tbody tr:last-child")
                                if (lastRow) {
                                  const firstInput = lastRow.querySelector("input")
                                  if (firstInput) firstInput.focus()
                                }
                              })
                            })
                          }
                        })
                      }
                    }
                  </script>
                <% else %>
                  <%= if @campaign.common_replacements == %{} do %>
                    <div class="text-center py-4 text-base-content/50">
                      No common replacements yet.
                    </div>
                  <% else %>
                    <div class="overflow-x-auto rounded-box border border-base-content/5 bg-base-200 mt-2">
                      <table class="table">
                        <thead>
                          <tr>
                            <th>Find</th>
                            <th>Replace</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr :for={{find, replace} <- @campaign.common_replacements}>
                            <td class="font-mono">{find}</td>
                            <td class="font-mono">{replace}</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  <% end %>

                  <%= if @importing_replacements? do %>
                    <.form
                      for={%{}}
                      id="import-replacements-form"
                      phx-submit="import_campaign_replacements"
                      class="mt-3"
                    >
                      <textarea
                        name="json"
                        rows="6"
                        placeholder={"{\n  \"find\": \"replace\",\n  ...\n}"}
                        class="textarea textarea-bordered w-full font-mono text-sm"
                        id="import-replacements-textarea"
                        phx-hook="DropJson"
                      ></textarea>
                      <div class="flex gap-2 mt-2">
                        <button type="submit" class="btn btn-primary btn-sm">Import</button>
                        <button
                          type="button"
                          phx-click="toggle_import_replacements"
                          class="btn btn-ghost btn-sm"
                        >
                          Cancel
                        </button>
                      </div>
                    </.form>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%!-- Danger Zone --%>
            <div class="card bg-base-100 border border-error/20 mt-2">
              <div class="card-body p-4">
                <h3 class="card-title text-sm text-error">Danger Zone</h3>
                <p class="text-sm text-base-content/60">
                  Deleting a campaign will also delete all its sessions.
                </p>
                <div class="mt-2">
                  <button
                    id="delete-campaign-btn"
                    phx-click="delete_campaign"
                    data-confirm="Are you sure you want to delete this campaign and all its sessions?"
                    class="btn btn-error btn-sm"
                  >
                    Delete Campaign
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:session_updated, session}, socket) do
    {:noreply,
     socket
     |> assign(:sessions_empty?, false)
     |> stream_insert(:sessions, session)}
  end

  @impl true
  def handle_event("toggle_settings", _params, socket) do
    {:noreply, assign(socket, settings_open?: !socket.assigns.settings_open?)}
  end

  def handle_event("save_name", %{"campaign" => campaign_params}, socket) do
    old_slug = socket.assigns.campaign.slug

    case Campaigns.update_campaign(socket.assigns.campaign, campaign_params) do
      {:ok, campaign} ->
        campaign = Campaigns.get_campaign!(campaign.id)

        if campaign.slug != old_slug do
          {:noreply,
           socket
           |> put_flash(:info, "Campaign name updated.")
           |> push_navigate(to: ~p"/campaigns/#{campaign.slug}")}
        else
          {:noreply,
           socket
           |> put_flash(:info, "Campaign name updated.")
           |> assign(:campaign, campaign)
           |> assign(:page_title, campaign.name)
           |> assign(:name_form, to_form(Campaigns.change_campaign(campaign)))
           |> assign(:settings_open?, true)}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset))}
    end
  end

  def handle_event("edit_player_map", _params, socket) do
    {:noreply, assign(socket, editing_player_map: true, settings_open?: true)}
  end

  def handle_event("cancel_edit_player_map", _params, socket) do
    # Reset rows from saved campaign data
    player_rows =
      socket.assigns.campaign.player_map
      |> Enum.map(fn {discord, character} ->
        %{id: System.unique_integer([:positive]), discord: discord, character: character}
      end)

    {:noreply,
     socket
     |> assign(:editing_player_map, false)
     |> assign(:settings_open?, true)
     |> assign(:player_rows, player_rows)}
  end

  def handle_event("update_players", %{"player" => player_params}, socket) do
    rows =
      Enum.map(socket.assigns.player_rows, fn row ->
        case Map.get(player_params, to_string(row.id)) do
          %{"discord" => discord, "character" => character} ->
            %{row | discord: discord, character: character}

          _ ->
            row
        end
      end)

    {:noreply, assign(socket, player_rows: rows, settings_open?: true)}
  end

  def handle_event("update_players", _params, socket) do
    {:noreply, assign(socket, settings_open?: true)}
  end

  def handle_event("add_player", _params, socket) do
    new_row = %{id: System.unique_integer([:positive]), discord: "", character: ""}

    {:reply, %{},
     assign(socket, player_rows: socket.assigns.player_rows ++ [new_row], settings_open?: true)}
  end

  def handle_event("remove_player", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.player_rows, &(&1.id == id))
    {:noreply, assign(socket, player_rows: rows, settings_open?: true)}
  end

  def handle_event("save_player_map", %{"player" => player_params}, socket) do
    entries =
      player_params
      |> Map.values()
      |> Enum.reject(fn %{"discord" => d, "character" => c} -> d == "" and c == "" end)

    discord_names = Enum.map(entries, & &1["discord"])
    duplicates = discord_names -- Enum.uniq(discord_names)

    if duplicates != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Duplicate Discord name: #{Enum.uniq(duplicates) |> Enum.join(", ")}")
       |> assign(:settings_open?, true)}
    else
      player_map = Map.new(entries, fn %{"discord" => d, "character" => c} -> {d, c} end)

      case Campaigns.update_campaign(socket.assigns.campaign, %{player_map: player_map}) do
        {:ok, campaign} ->
          campaign = Campaigns.get_campaign!(campaign.id)

          player_rows =
            campaign.player_map
            |> Enum.map(fn {discord, character} ->
              %{id: System.unique_integer([:positive]), discord: discord, character: character}
            end)

          {:noreply,
           socket
           |> put_flash(:info, "Player map saved.")
           |> assign(:campaign, campaign)
           |> assign(:player_rows, player_rows)
           |> assign(:editing_player_map, false)
           |> assign(:settings_open?, true)}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to save player map.")
           |> assign(:name_form, to_form(changeset))
           |> assign(:settings_open?, true)}
      end
    end
  end

  def handle_event("save_player_map", _params, socket) do
    # No players in the form — save empty map
    case Campaigns.update_campaign(socket.assigns.campaign, %{player_map: %{}}) do
      {:ok, campaign} ->
        campaign = Campaigns.get_campaign!(campaign.id)

        {:noreply,
         socket
         |> put_flash(:info, "Player map saved.")
         |> assign(:campaign, campaign)
         |> assign(:player_rows, [])
         |> assign(:editing_player_map, false)
         |> assign(:settings_open?, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save player map.")}
    end
  end

  def handle_event("toggle_import_replacements", _params, socket) do
    {:noreply,
     assign(socket,
       importing_replacements?: !socket.assigns.importing_replacements?,
       settings_open?: true
     )}
  end

  def handle_event("import_campaign_replacements", %{"json" => json}, socket) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          existing = socket.assigns.campaign.common_replacements || %{}
          downcased = Map.new(map, fn {k, v} -> {String.downcase(k), v} end)
          merged = Map.merge(existing, downcased)

          case Campaigns.update_campaign(socket.assigns.campaign, %{common_replacements: merged}) do
            {:ok, campaign} ->
              campaign = Campaigns.get_campaign!(campaign.id)

              replacement_rows =
                campaign.common_replacements
                |> Enum.map(fn {find, replace} ->
                  %{id: System.unique_integer([:positive]), find: find, replace: replace}
                end)

              {:noreply,
               socket
               |> put_flash(:info, "Imported #{map_size(map)} replacement(s).")
               |> assign(:campaign, campaign)
               |> assign(:replacement_rows, replacement_rows)
               |> assign(:importing_replacements?, false)
               |> assign(:settings_open?, true)}

            {:error, _} ->
              {:noreply,
               socket
               |> put_flash(:error, "Failed to import.")
               |> assign(:settings_open?, true)}
          end
        else
          {:noreply,
           socket
           |> put_flash(:error, "All keys and values must be strings.")
           |> assign(:settings_open?, true)}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid JSON object.")
         |> assign(:settings_open?, true)}
    end
  end

  def handle_event("edit_replacements", _params, socket) do
    {:noreply, assign(socket, editing_replacements: true, settings_open?: true)}
  end

  def handle_event("cancel_edit_replacements", _params, socket) do
    replacement_rows =
      socket.assigns.campaign.common_replacements
      |> Enum.map(fn {find, replace} ->
        %{id: System.unique_integer([:positive]), find: find, replace: replace}
      end)

    {:noreply,
     socket
     |> assign(:editing_replacements, false)
     |> assign(:settings_open?, true)
     |> assign(:replacement_rows, replacement_rows)}
  end

  def handle_event("update_replacement_rows", %{"replacement" => params}, socket) do
    rows =
      Enum.map(socket.assigns.replacement_rows, fn row ->
        case Map.get(params, to_string(row.id)) do
          %{"find" => find, "replace" => replace} ->
            %{row | find: find, replace: replace}

          _ ->
            row
        end
      end)

    {:noreply, assign(socket, replacement_rows: rows, settings_open?: true)}
  end

  def handle_event("update_replacement_rows", _params, socket) do
    {:noreply, assign(socket, settings_open?: true)}
  end

  def handle_event("add_replacement_row", _params, socket) do
    new_row = %{id: System.unique_integer([:positive]), find: "", replace: ""}

    {:reply, %{},
     assign(socket,
       replacement_rows: socket.assigns.replacement_rows ++ [new_row],
       settings_open?: true
     )}
  end

  def handle_event("remove_replacement_row", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.replacement_rows, &(&1.id == id))
    {:noreply, assign(socket, replacement_rows: rows, settings_open?: true)}
  end

  def handle_event("save_replacements", %{"replacement" => params}, socket) do
    entries =
      params
      |> Map.values()
      |> Enum.reject(fn %{"find" => f, "replace" => r} -> f == "" and r == "" end)

    find_values = Enum.map(entries, & &1["find"])
    duplicates = find_values -- Enum.uniq(find_values)

    if duplicates != [] do
      {:noreply,
       socket
       |> put_flash(:error, "Duplicate find value: #{Enum.uniq(duplicates) |> Enum.join(", ")}")
       |> assign(:settings_open?, true)}
    else
      replacements_map =
        Map.new(entries, fn %{"find" => f, "replace" => r} -> {String.downcase(f), r} end)

      case Campaigns.update_campaign(socket.assigns.campaign, %{
             common_replacements: replacements_map
           }) do
        {:ok, campaign} ->
          campaign = Campaigns.get_campaign!(campaign.id)

          replacement_rows =
            campaign.common_replacements
            |> Enum.map(fn {find, replace} ->
              %{id: System.unique_integer([:positive]), find: find, replace: replace}
            end)

          {:noreply,
           socket
           |> put_flash(:info, "Common replacements saved.")
           |> assign(:campaign, campaign)
           |> assign(:replacement_rows, replacement_rows)
           |> assign(:editing_replacements, false)
           |> assign(:settings_open?, true)}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to save replacements.")
           |> assign(:settings_open?, true)}
      end
    end
  end

  def handle_event("save_replacements", _params, socket) do
    case Campaigns.update_campaign(socket.assigns.campaign, %{common_replacements: %{}}) do
      {:ok, campaign} ->
        campaign = Campaigns.get_campaign!(campaign.id)

        {:noreply,
         socket
         |> put_flash(:info, "Common replacements saved.")
         |> assign(:campaign, campaign)
         |> assign(:replacement_rows, [])
         |> assign(:editing_replacements, false)
         |> assign(:settings_open?, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save replacements.")}
    end
  end

  def handle_event("delete_campaign", _params, socket) do
    campaign = socket.assigns.campaign

    for session <- campaign.sessions do
      Noter.Jobs.cancel_existing_transcription(session)
      File.rm_rf(Noter.Uploads.session_dir(session.id))
    end

    {:ok, _} = Campaigns.delete_campaign(campaign)

    {:noreply,
     socket
     |> put_flash(:info, "Campaign deleted.")
     |> push_navigate(to: ~p"/")}
  end
end
