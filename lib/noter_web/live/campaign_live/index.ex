defmodule NoterWeb.CampaignLive.Index do
  use NoterWeb, :live_view

  on_mount NoterWeb.Hooks.RequireSettings

  alias Noter.Campaigns

  @impl true
  def mount(_params, _session, socket) do
    campaigns = Campaigns.list_campaigns()
    changeset = Campaigns.change_campaign(%Noter.Campaigns.Campaign{})

    {:ok,
     socket
     |> assign(:page_title, "Campaigns")
     |> assign(:form, to_form(changeset))
     |> assign(:campaigns_empty?, campaigns == [])
     |> stream(:campaigns, campaigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">Campaigns</h1>
        </div>

        <div :if={@campaigns_empty?} class="text-center py-12 text-base-content/50">
          No campaigns yet. Create one below to get started.
        </div>
        <ul id="campaigns" phx-update="stream" class="list bg-base-200 rounded-box shadow-md">
          <li :for={{id, campaign} <- @streams.campaigns} id={id} class="list-row">
            <.link
              navigate={~p"/campaigns/#{campaign.slug}"}
              class="list-col-grow flex items-center justify-between hover:text-primary transition-colors"
            >
              <div>
                <div class="text-lg font-semibold">{campaign.name}</div>
                <div class="text-xs uppercase font-semibold opacity-60">
                  {session_count_label(campaign.session_count)}
                </div>
              </div>
              <.icon
                name="hero-chevron-right"
                class="size-5 text-base-content/30"
              />
            </.link>
          </li>
        </ul>

        <div class="card bg-base-200 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-lg">New Campaign</h2>
            <.form
              for={@form}
              id="campaign-form"
              phx-change="validate"
              phx-submit="save"
            >
              <div class="flex gap-3 items-center">
                <div class="flex-1 [&_.fieldset]:mb-0">
                  <.input field={@form[:name]} type="text" placeholder="Campaign name" />
                </div>
                <.button type="submit" class="btn btn-primary">
                  Create
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp session_count_label(0), do: "No Sessions"
  defp session_count_label(1), do: "1 Session"
  defp session_count_label(count), do: "#{count} Sessions"

  @impl true
  def handle_event("validate", %{"campaign" => campaign_params}, socket) do
    changeset =
      %Noter.Campaigns.Campaign{}
      |> Campaigns.change_campaign(campaign_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"campaign" => campaign_params}, socket) do
    case Campaigns.create_campaign(campaign_params) do
      {:ok, campaign} ->
        changeset = Campaigns.change_campaign(%Noter.Campaigns.Campaign{})

        {:noreply,
         socket
         |> put_flash(:info, "Campaign created successfully.")
         |> assign(:form, to_form(changeset))
         |> assign(:campaigns_empty?, false)
         |> stream_insert(:campaigns, campaign)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
