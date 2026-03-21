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

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def update_transcription(%Session{} = session, attrs) do
    session
    |> Session.transcription_changeset(attrs)
    |> Repo.update()
  end

  def get_session_with_campaign!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload(:campaign)
  end

  def get_session_by_slug!(campaign_id, slug) do
    Session
    |> Repo.get_by!(campaign_id: campaign_id, slug: slug)
    |> Repo.preload(:campaign)
  end

  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  def change_session(%Session{} = session, attrs \\ %{}) do
    Session.changeset(session, attrs)
  end
end
