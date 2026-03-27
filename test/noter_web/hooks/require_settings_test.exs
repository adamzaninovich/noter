defmodule NoterWeb.Hooks.RequireSettingsTest do
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Noter.Settings

  test "redirects to /settings when transcription_url not configured", %{conn: conn} do
    # Delete the seeded transcription_url from migration
    Noter.Repo.delete_all(Noter.Settings.Setting)

    assert {:error, {:redirect, %{to: "/settings"}}} = live(conn, ~p"/")
  end

  test "allows access when transcription_url is configured", %{conn: conn} do
    Settings.set("transcription_url", "http://localhost:8000")

    {:ok, _view, _html} = live(conn, ~p"/")
  end
end
