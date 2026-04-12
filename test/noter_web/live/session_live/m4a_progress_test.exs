defmodule NoterWeb.SessionLive.M4aProgressTest do
  @moduledoc """
  Tests for the parallel M4A encoding progress display during transcription.
  """
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
      Campaigns.create_campaign(%{name: "M4A Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "M4A Session"})
    session = Noter.Repo.preload(session, :campaign)

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  describe "M4A encoding card during transcription" do
    test "shows M4A encoding progress card when m4a_complete? is false",
         %{conn: conn, campaign: campaign, session: session} do
      # Use update_transcription to set transcription_job_id (changeset doesn't include it).
      # This makes reconnect_transcription take the poll_job path instead of
      # calling start_transcription_submit (which would crash).
      {:ok, session} =
        Sessions.update_transcription(session, %{
          status: "transcribing",
          transcription_job_id: "fake-job-id"
        })

      Noter.Settings.set("transcription_url", nil)

      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      # Simulate M4A progress broadcast
      send(view.pid, {:m4a_progress, 42})

      html = render(view)
      assert html =~ "Converting to M4A"
      assert html =~ "42%"
    end

    test "hides M4A card when m4a_complete? is true",
         %{conn: conn, campaign: campaign, session: session} do
      # Create M4A file so mount detects it
      trimmed_dir = Path.join(Uploads.session_dir(session.id), "trimmed")
      File.mkdir_p!(trimmed_dir)
      File.write!(Path.join(trimmed_dir, "merged.m4a"), "fake data")

      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      html = render(view)
      refute html =~ "Converting to M4A"
    end

    test "m4a_complete broadcast updates state",
         %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      send(view.pid, {:m4a_complete, :ok})

      html = render(view)
      refute html =~ "Converting to M4A"
    end
  end

  describe "both-done gate in LiveView" do
    setup %{session: session} do
      {:ok, session} =
        Sessions.update_transcription(session, %{
          status: "transcribing",
          transcription_job_id: "fake-job-id"
        })

      Noter.Settings.set("transcription_url", nil)

      {:ok, session: session}
    end

    test "transcription done + M4A done transitions to review",
         %{conn: conn, campaign: campaign, session: session} do
      # Create M4A file and set transcript
      trimmed_dir = Path.join(Uploads.session_dir(session.id), "trimmed")
      File.mkdir_p!(trimmed_dir)
      File.write!(Path.join(trimmed_dir, "merged.m4a"), "fake data")

      {:ok, _} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      # Send transcription done — since M4A already exists, should transition
      send(view.pid, {:transcription, :done, %{}})

      html = render(view)
      assert html =~ "Transcription complete"
    end

    test "transcription done without M4A does not transition to review",
         %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      # Send transcription done but M4A is not complete
      send(view.pid, {:transcription, :done, %{}})

      html = render(view)
      # Should still show transcribing state, waiting for M4A
      assert html =~ "Waiting for audio conversion"
    end
  end

  describe "trim files exclude M4A" do
    setup %{session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "trimming"})
      {:ok, session: session}
    end

    test "trimming progress card does not show M4A row",
         %{conn: conn, campaign: campaign, session: session} do
      base_dir = Uploads.session_dir(session.id)

      renamed_dir = Path.join(base_dir, "renamed")
      File.mkdir_p!(renamed_dir)
      File.write!(Path.join(renamed_dir, "Thorin.flac"), "data")

      # Put session in trimming with an active trim job
      {:ok, _session} = Sessions.update_session(session, %{status: "trimming"})

      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      # Manually set trim state to simulate an active trim
      send(view.pid, {:trim_complete, :ok, Sessions.get_session!(session.id)})
      html = render(view)

      # The trimming progress card should not have an M4A row
      refute html =~ "Converting to M4A"
    end
  end
end
