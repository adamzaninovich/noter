defmodule Noter.Sessions do
  import Ecto.Query

  alias Noter.Repo
  alias Noter.Sessions.Session

  def list_sessions(campaign_id) do
    Session
    |> where(campaign_id: ^campaign_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_session!(id) do
    Repo.get!(Session, id)
  end

  def create_session(%Noter.Campaigns.Campaign{} = campaign, attrs) do
    %Session{campaign_id: campaign.id}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  def change_session(%Session{} = session, attrs \\ %{}) do
    Session.changeset(session, attrs)
  end
end
