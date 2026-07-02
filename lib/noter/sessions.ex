defmodule Noter.Sessions do
  @moduledoc """
  Data access layer for session management, including CRUD operations,
  transcription updates, and correction/replacement handling.
  """

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

  defp broadcast_session_created({:ok, session} = result) do
    Phoenix.PubSub.broadcast(
      Noter.PubSub,
      "campaign:#{session.campaign_id}:sessions",
      {:session_created, session}
    )

    result
  end

  defp broadcast_session_created(error), do: error

  defp broadcast_session_deleted({:ok, session} = result) do
    Phoenix.PubSub.broadcast(
      Noter.PubSub,
      "campaign:#{session.campaign_id}:sessions",
      {:session_deleted, session}
    )

    result
  end

  defp broadcast_session_deleted(error), do: error

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
    |> broadcast_session_created()
  end

  def update_session(%Session{} = session, attrs) do
    session = Repo.preload(session, :campaign)

    result =
      Repo.transaction(fn ->
        with {:ok, session} <-
               session
               |> Session.changeset(attrs)
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

  def atomic_advance_to_reviewing(session_id) do
    case Repo.transaction(fn ->
           case Repo.update_all(
                  from(s in Session, where: s.id == ^session_id and s.status == "transcribing"),
                  set: [status: "reviewing"]
                ) do
             {1, _} ->
               session = Session |> Repo.get!(session_id) |> Repo.preload(:campaign)
               {:ok, _session} = apply_campaign_replacements(session, %{status: "reviewing"})
               {:ok, :advanced}

             {0, _} ->
               {:ok, :already_reviewing}
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def update_transcription(%Session{} = session, attrs) do
    session = Repo.preload(session, :campaign)

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

  defp apply_campaign_replacements(session, %{status: "reviewing"}) do
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
    session
    |> Repo.delete()
    |> broadcast_session_deleted()
  end

  def change_session(%Session{} = session, attrs \\ %{}) do
    Session.changeset(session, attrs)
  end

  def update_corrections(%Session{status: "reviewing"} = session, corrections_map) do
    session
    |> Session.corrections_changeset(%{corrections: corrections_map})
    |> Repo.update()
    |> broadcast_session_update()
  end

  def update_corrections(%Session{}, _corrections_map), do: {:error, :invalid_status}

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

  @doc """
  Finalize a session: generate SRT, set status to `noting`.
  This is the `reviewing → noting` transition. The caller should auto-start
  notes generation after this succeeds.
  """
  def finalize(%Session{status: "reviewing"} = session) do
    alias Noter.Transcription.Transcript

    raw_turns = Transcript.parse_turns(session.transcript_json)

    corrected_turns =
      Transcript.apply_corrections(
        raw_turns,
        Session.replacements(session),
        Session.edits(session)
      )

    srt = Transcript.segments_to_srt(corrected_turns)

    session
    |> Session.corrections_changeset(%{status: "noting", transcript_srt: srt})
    |> Repo.update()
    |> broadcast_session_update()
  end

  def finalize(%Session{}), do: {:error, :invalid_status}

  @doc """
  Edit session: `done|noting → reviewing` backward transition.
  Clears notes_error and transcript_srt so the transcript will be re-finalized.
  """
  def revert_to_review(%Session{status: status} = session) when status in ~w(noting done) do
    session
    |> Session.notes_changeset(%{
      status: "reviewing",
      notes_error: nil,
      transcript_srt: nil,
      chunk_facts: %{}
    })
    |> Repo.update()
    |> broadcast_session_update()
  end

  def revert_to_review(%Session{}), do: {:error, :invalid_status}

  def restore_notes(%Session{status: "noting", session_notes: notes} = session)
      when is_binary(notes) and notes != "" do
    session
    |> Session.notes_changeset(%{status: "done", notes_error: nil})
    |> Repo.update()
    |> broadcast_session_update()
  end

  def restore_notes(%Session{}), do: {:error, :no_existing_notes}

  def add_replacements(%Session{} = session, new_replacements) when is_map(new_replacements) do
    existing = Session.replacements(session)
    downcased = Map.new(new_replacements, fn {k, v} -> {String.downcase(k), v} end)
    merged = Map.merge(existing, downcased)
    update_corrections(session, Session.put_corrections(session, "replacements", merged))
  end

  def update_session_notes(%Session{} = session, attrs) do
    session
    |> Session.notes_changeset(attrs)
    |> Repo.update()
    |> broadcast_session_update()
  end

  def remove_replacement(%Session{} = session, find) do
    replacements =
      session
      |> Session.replacements()
      |> Map.delete(find)

    update_corrections(session, Session.put_corrections(session, "replacements", replacements))
  end

  def save_chunk_fact(session_id, chunk_index, facts) do
    patch = Jason.encode!(%{to_string(chunk_index) => facts})

    Session
    |> where([s], s.id == ^session_id)
    |> update([s],
      set: [chunk_facts: fragment("json_patch(coalesce(chunk_facts, '{}'), ?)", ^patch)]
    )
    |> Repo.update_all([])

    :ok
  end

  def clear_chunk_facts(%Session{} = session) do
    session
    |> Session.notes_changeset(%{chunk_facts: %{}})
    |> Repo.update()
  end
end
