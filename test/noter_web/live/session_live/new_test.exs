defmodule NoterWeb.SessionLive.NewTest do
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Noter.Campaigns

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
end
