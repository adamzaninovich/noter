defmodule NoterWeb.SessionLive.AutoChainTest do
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
      Campaigns.create_campaign(%{name: "Chain Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Chain Session"})
    session = Noter.Repo.preload(session, :campaign)

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  describe "finalize auto-chains to notes generation" do
    setup %{session: session} do
      {:ok, session} =
        Sessions.update_transcription(session, %{
          status: "reviewing",
          transcript_json: @transcript_json
        })

      {:ok, session: session}
    end

    test "finalize transitions to noting and triggers notes generation",
         %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      html = render_click(view, "finalize")

      # Flash confirms the auto-chain fired
      assert html =~ "Generating notes..."
    end
  end

  describe "trim complete auto-chains to transcription" do
    setup %{session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "trimming"})
      {:ok, session: session}
    end

    test "trim_complete message transitions LiveView to transcribing state",
         %{conn: conn, campaign: campaign, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

      # Simulate the trim_complete broadcast that Jobs sends
      {:ok, updated} = Sessions.update_session(session, %{status: "transcribing"})

      send(view.pid, {:trim_complete, :ok, updated})

      html = render(view)
      assert html =~ "Starting transcription"
    end
  end
end
