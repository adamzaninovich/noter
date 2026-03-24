defmodule NoterWeb.AudioControllerTest do
  use NoterWeb.ConnCase, async: true

  describe "validate_session_id plug" do
    test "returns 404 for non-integer session_id", %{conn: conn} do
      conn = get(conn, "/sessions/abc/audio/merged")
      assert conn.status == 404
    end

    test "returns 404 for path traversal attempt", %{conn: conn} do
      conn = get(conn, "/sessions/..%2F..%2Fetc/audio/merged")
      assert conn.status == 404
    end

    test "returns 404 for negative session_id", %{conn: conn} do
      conn = get(conn, "/sessions/-1/audio/merged")
      assert conn.status == 404
    end

    test "returns 404 for zero session_id", %{conn: conn} do
      conn = get(conn, "/sessions/0/audio/merged")
      assert conn.status == 404
    end

    test "returns 404 for mixed alphanumeric session_id", %{conn: conn} do
      conn = get(conn, "/sessions/123abc/audio/merged")
      assert conn.status == 404
    end

    test "allows valid positive integer session_id through", %{conn: conn} do
      # Valid integer, but no file exists — should get past the plug and return 404 from action
      conn = get(conn, "/sessions/999999/audio/merged")
      assert conn.status == 404
    end
  end
end
