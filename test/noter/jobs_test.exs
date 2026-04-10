defmodule Noter.JobsTest do
  use Noter.DataCase, async: false

  alias Noter.Campaigns
  alias Noter.Jobs
  alias Noter.Sessions
  alias Noter.Uploads

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Jobs Test Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Jobs Test Session"})
    session = Noter.Repo.preload(session, :campaign)

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  describe "start_m4a_encode/2" do
    setup %{session: session} do
      session_dir = Uploads.session_dir(session.id)
      trimmed_dir = Path.join(session_dir, "trimmed")
      File.mkdir_p!(trimmed_dir)
      File.write!(Path.join(trimmed_dir, "merged.wav"), "fake wav data")

      {:ok, session: %{session | duration_seconds: 60}}
    end

    test "returns error when already running", %{session: session} do
      first = Jobs.start_m4a_encode(session, session.duration_seconds)
      assert first == {:ok, :started}

      wait_for(fn -> Jobs.running?(session.id, :m4a_encode) end)

      second = Jobs.start_m4a_encode(session, session.duration_seconds)
      assert second == {:error, :already_running}
    end
  end

  describe "get_m4a_progress/1" do
    test "returns nil when no progress registered" do
      assert Jobs.get_m4a_progress(999_999_999) == nil
    end
  end
end
