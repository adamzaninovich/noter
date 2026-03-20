defmodule NoterWeb.CampaignLive.Index do
  use NoterWeb, :live_view

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

        <div :if={@campaigns_empty?} class="text-center py-12 text-base-content/50">
          No campaigns yet. Create one above to get started.
        </div>
        <div id="campaigns" phx-update="stream" class="flex flex-col gap-4">
          <.link
            :for={{id, campaign} <- @streams.campaigns}
            id={id}
            navigate={~p"/campaigns/#{campaign.id}"}
            class="flex items-center justify-between p-4 rounded-lg bg-base-100 border border-base-300 hover:border-primary/40 hover:bg-base-100/80 transition-all cursor-pointer group"
          >
            <span class="text-lg font-semibold group-hover:text-primary transition-colors">
              {campaign.name}
            </span>
            <.icon name="hero-chevron-right" class="size-5 text-base-content/30 group-hover:text-primary transition-colors" />
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

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

  def handle_event("delete", %{"id" => id}, socket) do
    campaign = Campaigns.get_campaign!(id)
    {:ok, _} = Campaigns.delete_campaign(campaign)

    remaining = Campaigns.list_campaigns()

    {:noreply,
     socket
     |> put_flash(:info, "Campaign deleted.")
     |> assign(:campaigns_empty?, remaining == [])
     |> stream_delete(:campaigns, campaign)}
  end
end
