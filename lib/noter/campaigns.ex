defmodule Noter.Campaigns do
  import Ecto.Query

  alias Noter.Repo
  alias Noter.Campaigns.Campaign

  def list_campaigns do
    Campaign
    |> order_by(:name)
    |> Repo.all()
  end

  def get_campaign!(id) do
    Campaign
    |> Repo.get!(id)
    |> Repo.preload(sessions: from(s in Noter.Sessions.Session, order_by: [desc: s.inserted_at]))
  end

  def get_campaign_by_slug!(slug) do
    Campaign
    |> Repo.get_by!(slug: slug)
    |> Repo.preload(sessions: from(s in Noter.Sessions.Session, order_by: [desc: s.inserted_at]))
  end

  def create_campaign(attrs) do
    %Campaign{}
    |> Campaign.changeset(attrs)
    |> Repo.insert()
  end

  def update_campaign(%Campaign{} = campaign, attrs) do
    campaign
    |> Campaign.changeset(attrs)
    |> Repo.update()
  end

  def delete_campaign(%Campaign{} = campaign) do
    Repo.delete(campaign)
  end

  def change_campaign(%Campaign{} = campaign, attrs \\ %{}) do
    Campaign.changeset(campaign, attrs)
  end
end
