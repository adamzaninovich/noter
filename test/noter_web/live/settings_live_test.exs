defmodule NoterWeb.SettingsLiveTest do
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Noter.Settings

  setup do
    Settings.set("transcription_url", "http://localhost:8000")
    :ok
  end

  test "renders settings page with form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-form")
    assert has_element?(view, "h2", "Transcription Service")
    assert has_element?(view, "h2", "LLM — Extraction Model")
    assert has_element?(view, "h2", "LLM — Writing Model")
  end

  test "saves settings on form submit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", settings: %{transcription_url: "http://new-host:9000"})
    |> render_submit()

    assert Settings.get("transcription_url") == "http://new-host:9000"
    assert has_element?(view, "[role=alert]", "Settings saved.")
  end

  test "pre-fills transcription_url", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "http://localhost:8000"
  end
end
