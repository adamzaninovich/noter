defmodule Noter.Transcription.SSEClientGateTest do
  @moduledoc """
  Tests for the gate check that prevents advancing to "reviewing" until
  both transcription and M4A encoding are complete.
  """
  use Noter.DataCase, async: true

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

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
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Gate Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Gate Session"})
    {:ok, session} = Sessions.update_session(session, %{status: "transcribing"})

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, session: session}
  end

  describe "check_advance_to_reviewing/1" do
    test "advances when transcript_json is set and M4A exists", %{session: session} do
      # Set transcript_json (simulates transcription done)
      {:ok, session} =
        Sessions.update_transcription(session, %{transcript_json: @transcript_json})

      # Create the M4A file (simulates M4A encode done)
      trimmed_dir = Path.join(Uploads.session_dir(session.id), "trimmed")
      File.mkdir_p!(trimmed_dir)
      File.write!(Path.join(trimmed_dir, "merged.m4a"), "fake m4a data")

      assert {:ok, :advanced} = Noter.Jobs.check_advance_to_reviewing(session.id)

      updated = Sessions.get_session!(session.id)
      assert updated.status == "reviewing"
    end

    test "does not advance when transcript_json is set but M4A is missing", %{session: session} do
      {:ok, _session} =
        Sessions.update_transcription(session, %{transcript_json: @transcript_json})

      assert {:ok, :waiting} = Noter.Jobs.check_advance_to_reviewing(session.id)

      updated = Sessions.get_session!(session.id)
      assert updated.status == "transcribing"
    end

    test "does not advance when M4A exists but transcript_json is nil", %{session: session} do
      trimmed_dir = Path.join(Uploads.session_dir(session.id), "trimmed")
      File.mkdir_p!(trimmed_dir)
      File.write!(Path.join(trimmed_dir, "merged.m4a"), "fake m4a data")

      assert {:ok, :waiting} = Noter.Jobs.check_advance_to_reviewing(session.id)

      updated = Sessions.get_session!(session.id)
      assert updated.status == "transcribing"
    end
  end
end
