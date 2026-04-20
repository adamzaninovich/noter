defmodule NoterWeb.SettingsLiveTest do
  use NoterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Noter.Settings

  setup do
    Settings.set("transcription_url", "http://localhost:8000")
    Settings.set("llm_extraction_base_url", "http://saved-host:1234/v1")
    Settings.set("llm_extraction_api_key", "saved-api-key")
    Settings.set("llm_writing_base_url", "http://saved-host:1234/v1")
    Settings.set("llm_writing_api_key", "saved-writing-key")
    Application.put_env(:noter, :fetch_models_plug, [])
    on_exit(fn -> Application.delete_env(:noter, :fetch_models_plug) end)
    :ok
  end

  test "fetch_models reads base URL from form, not saved DB value", %{conn: conn} do
    test_pid = self()

    captured = fn conn ->
      url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
      auth = Enum.find(conn.req_headers, fn {k, _} -> k == "authorization" end)
      send(test_pid, {:model_request, %{url: url, auth: auth}})
      Req.Test.json(conn, %{"data" => [%{"id" => "model-from-form"}]})
    end

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form",
      settings: %{"llm_extraction_base_url" => "http://form-host:9999/v1"}
    )
    |> render_change()

    Application.put_env(:noter, :fetch_models_plug, plug: captured)

    view
    |> element("button[phx-click='fetch_models'][phx-value-role='extraction']")
    |> render_click()

    assert_receive {:model_request, %{url: url}}
    assert url =~ "form-host:9999"
  end

  test "fetch_models falls back to saved API key when form field is blank", %{conn: conn} do
    test_pid = self()

    captured = fn conn ->
      auth = Enum.find(conn.req_headers, fn {k, _} -> k == "authorization" end)
      send(test_pid, {:model_request, %{auth: auth}})
      Req.Test.json(conn, %{"data" => [%{"id" => "model-from-form"}]})
    end

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", settings: %{"llm_extraction_api_key" => ""})
    |> render_change()

    Application.put_env(:noter, :fetch_models_plug, plug: captured)

    view
    |> element("button[phx-click='fetch_models'][phx-value-role='extraction']")
    |> render_click()

    assert_receive {:model_request, %{auth: {"authorization", "Bearer saved-api-key"}}}
  end

  test "fetch_models uses form API key when provided", %{conn: conn} do
    test_pid = self()

    captured = fn conn ->
      auth = Enum.find(conn.req_headers, fn {k, _} -> k == "authorization" end)
      send(test_pid, {:model_request, %{auth: auth}})
      Req.Test.json(conn, %{"data" => [%{"id" => "model-from-form"}]})
    end

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-form", settings: %{"llm_extraction_api_key" => "form-api-key"})
    |> render_change()

    Application.put_env(:noter, :fetch_models_plug, plug: captured)

    view
    |> element("button[phx-click='fetch_models'][phx-value-role='extraction']")
    |> render_click()

    assert_receive {:model_request, %{auth: {"authorization", "Bearer form-api-key"}}}
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
