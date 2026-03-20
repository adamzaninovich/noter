defmodule NoterWeb.CampaignLive.Show do
  use NoterWeb, :live_view

  alias Noter.Campaigns

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    campaign = Campaigns.get_campaign!(id)
    name_changeset = Campaigns.change_campaign(campaign)

    player_rows =
      campaign.player_map
      |> Enum.map(fn {discord, character} ->
        %{id: System.unique_integer([:positive]), discord: discord, character: character}
      end)

    {:ok,
     socket
     |> assign(:page_title, campaign.name)
     |> assign(:campaign, campaign)
     |> assign(:name_form, to_form(name_changeset))
     |> assign(:player_rows, player_rows)
     |> assign(:sessions_empty?, campaign.sessions == [])
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

        <%!-- Edit Name Section --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">Campaign Name</h2>
            <.form for={@name_form} id="name-form" phx-submit="save_name" class="flex gap-3 items-end">
              <div class="flex-1">
                <.input field={@name_form[:name]} type="text" />
              </div>
              <.button type="submit" class="btn btn-primary">Save</.button>
            </.form>
          </div>
        </div>

        <%!-- Player Map Section --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">Player Map</h2>
            <p class="text-sm text-base-content/60">
              Map Discord usernames to character names for transcript processing.
            </p>

            <div class="overflow-x-auto mt-2">
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
                        form="player-map-form"
                      />
                    </td>
                    <td>
                      <input
                        type="text"
                        value={row.character}
                        name={"player[#{row.id}][character]"}
                        placeholder="Character name"
                        class="input input-bordered input-sm w-full"
                        form="player-map-form"
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
              <form id="player-map-form" phx-submit="save_player_map">
                <.button type="submit" class="btn btn-sm btn-primary">Save Player Map</.button>
              </form>
            </div>
          </div>
        </div>

        <%!-- Sessions Section --%>
        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-lg">Sessions</h2>
            </div>

            <div id="sessions" phx-update="stream" class="space-y-2 mt-2">
              <div class={["text-center py-6 text-base-content/50", !@sessions_empty? && "hidden"]}>
                No sessions yet.
              </div>
              <div
                :for={{id, session} <- @streams.sessions}
                id={id}
                class="flex items-center justify-between p-3 bg-base-100 rounded-lg border border-base-300"
              >
                <div class="flex items-center gap-3">
                  <span class="font-medium">{session.name}</span>
                  <span class={["badge badge-sm", status_badge_class(session.status)]}>
                    {session.status}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Danger Zone --%>
        <div class="card bg-base-200 shadow-sm border border-error/20">
          <div class="card-body">
            <h2 class="card-title text-lg text-error">Danger Zone</h2>
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
    </Layouts.app>
    """
  end

  defp status_badge_class(status) do
    case status do
      "done" -> "badge-success"
      "reviewing" -> "badge-warning"
      "transcribing" -> "badge-info"
      "transcribed" -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  @impl true
  def handle_event("save_name", %{"campaign" => campaign_params}, socket) do
    case Campaigns.update_campaign(socket.assigns.campaign, campaign_params) do
      {:ok, campaign} ->
        campaign = Campaigns.get_campaign!(campaign.id)

        {:noreply,
         socket
         |> put_flash(:info, "Campaign name updated.")
         |> assign(:campaign, campaign)
         |> assign(:page_title, campaign.name)
         |> assign(:name_form, to_form(Campaigns.change_campaign(campaign)))}

      {:error, changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset))}
    end
  end

  def handle_event("add_player", _params, socket) do
    new_row = %{id: System.unique_integer([:positive]), discord: "", character: ""}
    {:noreply, assign(socket, player_rows: socket.assigns.player_rows ++ [new_row])}
  end

  def handle_event("remove_player", %{"id" => id}, socket) do
    id = String.to_integer(id)
    rows = Enum.reject(socket.assigns.player_rows, &(&1.id == id))
    {:noreply, assign(socket, player_rows: rows)}
  end

  def handle_event("save_player_map", %{"player" => player_params}, socket) do
    player_map =
      player_params
      |> Map.values()
      |> Enum.reject(fn %{"discord" => d, "character" => c} -> d == "" and c == "" end)
      |> Map.new(fn %{"discord" => discord, "character" => character} -> {discord, character} end)

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
         |> assign(:player_rows, player_rows)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save player map.")
         |> assign(:name_form, to_form(changeset))}
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
         |> assign(:player_rows, [])}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save player map.")}
    end
  end

  def handle_event("delete_campaign", _params, socket) do
    {:ok, _} = Campaigns.delete_campaign(socket.assigns.campaign)

    {:noreply,
     socket
     |> put_flash(:info, "Campaign deleted.")
     |> push_navigate(to: ~p"/")}
  end
end
