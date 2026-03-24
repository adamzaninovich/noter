defmodule Noter.Sessions do
  import Ecto.Query

  alias Noter.Repo
  alias Noter.Sessions.Session

  def subscribe(campaign_id) do
    Phoenix.PubSub.subscribe(Noter.PubSub, "campaign:#{campaign_id}:sessions")
  end

  defp broadcast_session_update({:ok, session} = result) do
    Phoenix.PubSub.broadcast(
      Noter.PubSub,
      "campaign:#{session.campaign_id}:sessions",
      {:session_updated, session}
    )

    result
  end

  defp broadcast_session_update(error), do: error

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
    |> broadcast_session_update()
  end

  def update_transcription(%Session{} = session, attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, session} <-
               session
               |> Session.transcription_changeset(attrs)
               |> Repo.update(),
             {:ok, session} <- apply_campaign_replacements(session, attrs) do
          session
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, session} -> {:ok, session} |> broadcast_session_update()
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_campaign_replacements(session, %{status: "transcribed"}) do
    session = Repo.preload(session, :campaign)
    campaign_replacements = session.campaign.common_replacements || %{}

    if campaign_replacements == %{} do
      {:ok, session}
    else
      existing = Session.replacements(session)
      merged = Map.merge(campaign_replacements, existing)
      corrections = Session.put_corrections(session, "replacements", merged)

      session
      |> Session.corrections_changeset(%{corrections: corrections})
      |> Repo.update()
    end
  end

  defp apply_campaign_replacements(session, _attrs), do: {:ok, session}

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

  def update_corrections(%Session{} = session, corrections_map) do
    status =
      if session.status in ~w(transcribed done), do: "reviewing", else: session.status

    session
    |> Session.corrections_changeset(%{
      corrections: corrections_map,
      status: status,
      transcript_srt: nil
    })
    |> Repo.update()
    |> broadcast_session_update()
  end

  def add_replacement(%Session{} = session, find, replace) do
    replacements =
      session
      |> Session.replacements()
      |> Map.put(String.downcase(find), replace)

    update_corrections(session, Session.put_corrections(session, "replacements", replacements))
  end

  def add_edit(%Session{} = session, turn_id, text) do
    edits =
      session
      |> Session.edits()
      |> Map.put(to_string(turn_id), text)

    update_corrections(session, Session.put_corrections(session, "edits", edits))
  end

  def remove_edit(%Session{} = session, turn_id) do
    edits =
      session
      |> Session.edits()
      |> Map.delete(to_string(turn_id))

    update_corrections(session, Session.put_corrections(session, "edits", edits))
  end

  def finalize(%Session{} = session) do
    alias Noter.Transcription.Transcript

    raw_turns = Transcript.parse_turns(session.transcript_json)
    corrected_turns = Transcript.apply_corrections(raw_turns, Session.corrections(session))
    srt = Transcript.segments_to_srt(corrected_turns)

    session
    |> Session.corrections_changeset(%{status: "done", transcript_srt: srt})
    |> Repo.update()
    |> broadcast_session_update()
  end

  def unfinalize(%Session{} = session) do
    session
    |> Session.corrections_changeset(%{status: "reviewing", transcript_srt: nil})
    |> Repo.update()
    |> broadcast_session_update()
  end

  def add_replacements(%Session{} = session, new_replacements) when is_map(new_replacements) do
    existing = Session.replacements(session)
    downcased = Map.new(new_replacements, fn {k, v} -> {String.downcase(k), v} end)
    merged = Map.merge(existing, downcased)
    update_corrections(session, Session.put_corrections(session, "replacements", merged))
  end

  def remove_replacement(%Session{} = session, find) do
    replacements =
      session
      |> Session.replacements()
      |> Map.delete(find)

    update_corrections(session, Session.put_corrections(session, "replacements", replacements))
  end
end
