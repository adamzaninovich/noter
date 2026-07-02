defmodule NoterWeb.SessionLive.NewTest do
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{"user1" => "Thorin"}})

    {:ok, campaign: campaign}
  end

  test "renders session creation form", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "#session-form")
    assert has_element?(view, "h1", "New Session")
  end

  test "breadcrumb links to campaign", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "a", campaign.name)
  end

  test "validates session name", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    view
    |> form("#session-form", session: %{name: ""})
    |> render_change()

    assert has_element?(view, "#session-form")
  end

  test "prefills vocab from the most recent session", %{conn: conn, campaign: campaign} do
    {:ok, prev} = Sessions.create_session(campaign, %{name: "Earlier Session"})
    File.mkdir_p!(Uploads.session_dir(prev.id))
    File.write!(Path.join(Uploads.session_dir(prev.id), "vocab.txt"), "Tharivol\nNeverwinter")
    on_exit(fn -> File.rm_rf(Uploads.session_dir(prev.id)) end)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "#session-vocab", "Tharivol")
  end

  test "vocab textarea is empty for the first session", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    assert has_element?(view, "#session-vocab")
    refute has_element?(view, "#session-vocab", "Tharivol")
  end

  test "flashes an error when a non-text file is dropped", %{conn: conn, campaign: campaign} do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    html =
      view
      |> element("#session-vocab")
      |> render_hook("vocab_file_rejected", %{"name" => "photo.jpg"})

    assert html =~ "photo.jpg is not a text file"
  end

  test "reset restores the originally loaded vocab", %{conn: conn, campaign: campaign} do
    {:ok, prev} = Sessions.create_session(campaign, %{name: "Earlier Session"})
    File.mkdir_p!(Uploads.session_dir(prev.id))
    File.write!(Path.join(Uploads.session_dir(prev.id), "vocab.txt"), "Tharivol\nNeverwinter")
    on_exit(fn -> File.rm_rf(Uploads.session_dir(prev.id)) end)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/new")

    view |> element("button", "Reset") |> render_click()

    assert_push_event(view, "vocab_reset", %{vocab: "Tharivol\nNeverwinter"})
  end
end
