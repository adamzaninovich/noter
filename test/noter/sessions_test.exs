defmodule Noter.SessionsTest do
  use Noter.DataCase, async: true

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Sessions.Session

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Test Session"})

    {:ok, campaign: campaign, session: session}
  end

  describe "Session.replacements/1" do
    test "returns empty map when corrections is nil" do
      session = %Session{corrections: nil}
      assert Session.replacements(session) == %{}
    end

    test "returns replacements map when present" do
      session = %Session{corrections: %{"replacements" => %{"foo" => "bar"}}}
      assert Session.replacements(session) == %{"foo" => "bar"}
    end

    test "returns empty map when corrections has no replacements key" do
      session = %Session{corrections: %{}}
      assert Session.replacements(session) == %{}
    end
  end

  describe "Session.edits/1" do
    test "returns empty map when corrections is nil" do
      session = %Session{corrections: nil}
      assert Session.edits(session) == %{}
    end

    test "returns edits map when present" do
      session = %Session{corrections: %{"edits" => %{"0" => "edited text"}}}
      assert Session.edits(session) == %{"0" => "edited text"}
    end

    test "returns empty map when corrections has no edits key" do
      session = %Session{corrections: %{}}
      assert Session.edits(session) == %{}
    end
  end

  describe "Session.put_corrections/3" do
    test "builds map from nil corrections" do
      session = %Session{corrections: nil}

      assert Session.put_corrections(session, "replacements", %{"a" => "b"}) ==
               %{"replacements" => %{"a" => "b"}}
    end

    test "merges into existing corrections" do
      session = %Session{corrections: %{"edits" => %{"0" => "x"}}}
      result = Session.put_corrections(session, "replacements", %{"a" => "b"})
      assert result == %{"edits" => %{"0" => "x"}, "replacements" => %{"a" => "b"}}
    end
  end

  describe "update_transcription/2" do
    test "applies transcription and campaign replacements atomically", %{
      campaign: campaign,
      session: session
    } do
      {:ok, campaign} =
        Campaigns.update_campaign(campaign, %{common_replacements: %{"npc" => "NPC Name"}})

      session = %{session | campaign: campaign}

      {:ok, updated} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: "{}",
          transcription_job_id: "job_123"
        })

      assert updated.status == "reviewing"
      assert updated.transcript_json == "{}"
      assert updated.corrections["replacements"]["npc"] == "NPC Name"
    end

    test "works without campaign replacements", %{session: session} do
      session = Repo.preload(session, :campaign)

      {:ok, updated} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: "{}",
          transcription_job_id: "job_123"
        })

      assert updated.status == "reviewing"
      assert updated.corrections == nil || updated.corrections["replacements"] == nil
    end

    test "skips campaign replacements for non-reviewing status", %{
      campaign: campaign,
      session: session
    } do
      {:ok, campaign} =
        Campaigns.update_campaign(campaign, %{common_replacements: %{"npc" => "NPC Name"}})

      session = %{session | campaign: campaign}

      {:ok, updated} =
        Sessions.update_transcription(session, %{status: "transcribing"})

      assert updated.status == "transcribing"
      refute updated.corrections["replacements"]
    end

    test "broadcasts session update after successful transaction", %{
      campaign: campaign,
      session: session
    } do
      Sessions.subscribe(campaign.id)
      session = Repo.preload(session, :campaign)

      {:ok, _updated} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: "{}"
        })

      assert_receive {:session_updated, %Session{status: "reviewing"}}
    end

    test "does not broadcast on failure", %{session: session} do
      session = Repo.preload(session, :campaign)
      Sessions.subscribe(session.campaign_id)

      # invalid status should cause a changeset error
      {:error, _reason} =
        Sessions.update_transcription(session, %{status: "bogus_status"})

      refute_receive {:session_updated, _}
    end
  end

  describe "create_session/2 broadcasts" do
    test "broadcasts session_created on success", %{campaign: campaign} do
      Sessions.subscribe(campaign.id)

      {:ok, session} = Sessions.create_session(campaign, %{name: "New Session"})

      assert_receive {:session_created, %Session{id: id}}
      assert id == session.id
    end

    test "does not broadcast on failure", %{campaign: campaign} do
      Sessions.subscribe(campaign.id)

      {:error, _changeset} = Sessions.create_session(campaign, %{name: nil})

      refute_receive {:session_created, _}
    end
  end

  describe "delete_session/1 broadcasts" do
    test "broadcasts session_deleted on success", %{campaign: campaign, session: session} do
      Sessions.subscribe(campaign.id)

      {:ok, deleted} = Sessions.delete_session(session)

      assert_receive {:session_deleted, %Session{id: id}}
      assert id == deleted.id
    end
  end

  describe "nil corrections safety" do
    setup %{session: session} do
      # Force corrections to nil and status to reviewing
      session =
        session
        |> Ecto.Changeset.change(%{corrections: nil, status: "reviewing"})
        |> Repo.update!()

      assert session.corrections == nil
      {:ok, session: session}
    end

    test "add_replacement works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_replacement(session, "hello", "world")
      assert updated.corrections["replacements"]["hello"] == "world"
    end

    test "remove_replacement works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.remove_replacement(session, "nonexistent")
      assert updated.corrections["replacements"] == %{}
    end

    test "add_edit works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_edit(session, 0, "edited text")
      assert updated.corrections["edits"]["0"] == "edited text"
    end

    test "remove_edit works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.remove_edit(session, 0)
      assert updated.corrections["edits"] == %{}
    end

    test "add_replacements works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_replacements(session, %{"Foo" => "bar", "BAZ" => "qux"})
      assert updated.corrections["replacements"] == %{"foo" => "bar", "baz" => "qux"}
    end
  end

  describe "update_corrections/2 status guard" do
    test "only allows corrections when status is reviewing", %{session: session} do
      assert {:error, :invalid_status} =
               Sessions.update_corrections(session, %{"replacements" => %{}})

      {:ok, session} = Sessions.update_session(session, %{status: "reviewing"})

      assert {:ok, _} =
               Sessions.update_corrections(session, %{"replacements" => %{"a" => "b"}})
    end
  end

  describe "finalize/1" do
    setup %{session: session} do
      transcript_json =
        Jason.encode!(%{
          "segments" => [
            %{
              "speaker" => "Alice",
              "start" => 0.0,
              "end" => 2.5,
              "words" => [
                %{"word" => " Hello", "start" => 0.0, "end" => 1.0},
                %{"word" => " world", "start" => 1.0, "end" => 2.5}
              ]
            }
          ]
        })

      session = Repo.preload(session, :campaign)

      {:ok, session} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: transcript_json
        })

      {:ok, session: session}
    end

    test "transitions from reviewing to noting", %{session: session} do
      {:ok, updated} = Sessions.finalize(session)
      assert updated.status == "noting"
      assert updated.transcript_srt != nil
    end

    test "rejects finalize from non-reviewing status", %{session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "uploading"})
      assert {:error, :invalid_status} = Sessions.finalize(session)
    end
  end

  describe "edit_session/1" do
    setup %{session: session} do
      session = Repo.preload(session, :campaign)

      {:ok, session} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: "{}"
        })

      {:ok, session} =
        Sessions.update_session_notes(session, %{
          status: "done",
          session_notes: "some notes",
          notes_error: nil
        })

      session =
        session
        |> Ecto.Changeset.change(%{transcript_srt: "some srt"})
        |> Repo.update!()

      {:ok, session: session}
    end

    test "transitions from done to reviewing and clears only notes_error", %{session: session} do
      {:ok, updated} = Sessions.edit_session(session)
      assert updated.status == "reviewing"
      assert updated.notes_error == nil
      assert updated.session_notes == "some notes"
      assert updated.transcript_srt == "some srt"
    end

    test "rejects edit_session from non-done status" do
      {:ok, campaign} = Campaigns.create_campaign(%{name: "C2", player_map: %{}})
      {:ok, session} = Sessions.create_session(campaign, %{name: "S2"})
      assert {:error, :invalid_status} = Sessions.edit_session(session)
    end
  end
end
