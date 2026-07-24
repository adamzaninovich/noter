defmodule NoterWeb.CampaignLive.ShowTest do
  use NoterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Noter.Campaigns
  alias Noter.Sessions

  describe "campaign player map editability" do
    test "shows Edit button when campaign has no sessions", %{conn: conn} do
      {:ok, campaign} =
        Campaigns.create_campaign(%{"name" => "NoSessions #{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}")
      assert has_element?(view, "button[phx-click='edit_player_map']")
    end

    test "hides Edit button once a session exists", %{conn: conn} do
      {:ok, campaign} =
        Campaigns.create_campaign(%{
          "name" => "WithSession #{System.unique_integer([:positive])}",
          "player_map" => %{"alice" => "Thorin"}
        })

      {:ok, _session} = Sessions.create_session(campaign, %{"name" => "S1"})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}")
      refute has_element?(view, "button[phx-click='edit_player_map']")
    end
  end
end
