defmodule NoterWeb.SessionLive.ShowTest do
  use NoterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{"user1" => "Thorin"}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Session 1"})
    {:ok, _} = Sessions.update_session(session, %{status: "trimming"})
    session = Sessions.get_session!(session.id)

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  test "renders session name and status", %{conn: conn, campaign: campaign, session: session} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

    assert has_element?(view, "h1", session.name)
    assert has_element?(view, ".badge", "trimming")
  end

  test "renders step indicator", %{conn: conn, campaign: campaign, session: session} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

    assert has_element?(view, ".steps")
    assert has_element?(view, ".step", "Upload")
    assert has_element?(view, ".step", "Trim")
  end

  test "breadcrumb links to campaign", %{conn: conn, campaign: campaign, session: session} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

    assert has_element?(view, "a", campaign.name)
  end

  test "displays renamed files when present", %{conn: conn, campaign: campaign, session: session} do
    # Create some renamed files
    renamed_dir = Path.join(Uploads.session_dir(session.id), "renamed")
    File.mkdir_p!(renamed_dir)
    File.write!(Path.join(renamed_dir, "Thorin.flac"), "data")

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")

    assert has_element?(view, "#renamed-files-table")
    assert has_element?(view, "td", "Thorin")
  end
end
