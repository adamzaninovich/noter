defmodule Noter.StateMachineTest do
  use Noter.DataCase, async: false

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Settings

  @transcript_json Jason.encode!(%{
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

  setup do
    {:ok, campaign} = Campaigns.create_campaign(%{name: "SM Campaign", player_map: %{}})
    {:ok, session} = Sessions.create_session(campaign, %{name: "SM Session"})
    session = Repo.preload(session, :campaign)
    {:ok, campaign: campaign, session: session}
  end

  describe "valid forward transitions" do
    test "uploading → trimming", %{session: session} do
      assert session.status == "uploading"
      {:ok, s} = Sessions.update_session(session, %{status: "trimming"})
      assert s.status == "trimming"
    end

    test "trimming → transcribing", %{session: session} do
      {:ok, s} = Sessions.update_session(session, %{status: "trimming"})

      {:ok, s} =
        Sessions.update_transcription(s, %{status: "transcribing", transcription_job_id: "j1"})

      assert s.status == "transcribing"
    end

    test "transcribing → reviewing", %{session: session} do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      assert s.status == "reviewing"
    end

    test "reviewing → noting (via finalize)", %{session: session} do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, s} = Sessions.finalize(s)
      assert s.status == "noting"
      assert s.transcript_srt != nil
    end

    test "noting → done (via pipeline success)", %{session: session} do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, s} = Sessions.finalize(s)

      {:ok, s} =
        Sessions.update_session_notes(s, %{status: "done", session_notes: "# Notes"})

      assert s.status == "done"
    end
  end

  describe "backward transition: done → reviewing" do
    test "edit_session clears notes_error and transcript_srt, preserves notes", %{
      session: session
    } do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, s} = Sessions.finalize(s)

      {:ok, s} =
        Sessions.update_session_notes(s, %{
          status: "done",
          session_notes: "# Notes",
          notes_error: nil
        })

      s = Ecto.Changeset.change(s, %{transcript_srt: "srt data"}) |> Repo.update!()

      {:ok, reverted} = Sessions.edit_session(s)
      assert reverted.status == "reviewing"
      assert reverted.notes_error == nil
      assert reverted.session_notes == "# Notes"
      assert reverted.transcript_srt == nil
    end
  end

  describe "backward transition: noting → reviewing" do
    test "edit_session from noting clears notes_error and transcript_srt", %{session: session} do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, s} = Sessions.finalize(s)
      assert s.status == "noting"

      # Simulate a notes failure
      {:ok, s} = Sessions.update_session_notes(s, %{notes_error: "LLM unavailable"})

      {:ok, reverted} = Sessions.edit_session(s)
      assert reverted.status == "reviewing"
      assert reverted.notes_error == nil
      assert reverted.transcript_srt == nil
    end
  end

  describe "invalid transitions" do
    test "finalize rejects non-reviewing session", %{session: session} do
      assert {:error, :invalid_status} = Sessions.finalize(session)
    end

    test "edit_session rejects non-noting/done session", %{session: session} do
      assert {:error, :invalid_status} = Sessions.edit_session(session)
    end

    test "update_corrections rejects non-reviewing session", %{session: session} do
      assert {:error, :invalid_status} =
               Sessions.update_corrections(session, %{"replacements" => %{}})
    end
  end

  describe "error revert transitions" do
    test "notes failure stays on noting", %{session: session} do
      {:ok, s} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, s} = Sessions.finalize(s)
      assert s.status == "noting"

      # Simulate pipeline failure — stays on noting so user can retry
      {:ok, failed} =
        Sessions.update_session_notes(s, %{
          notes_error: "LLM unavailable"
        })

      assert failed.status == "noting"
      assert failed.notes_error == "LLM unavailable"
    end
  end

  describe "Settings.get/2 falsy values" do
    test "returns false when stored value is false" do
      Settings.set("test_bool", false)
      assert Settings.get("test_bool", true) == false
    end

    test "returns 0 when stored value is 0" do
      Settings.set("test_zero", 0)
      assert Settings.get("test_zero", 42) == 0
    end

    test "falls back to default only for nil" do
      Settings.set("test_nil", nil)
      assert Settings.get("test_nil", "fallback") == "fallback"
    end

    test "returns default when key does not exist" do
      assert Settings.get("nonexistent_key", "default") == "default"
    end
  end
end
