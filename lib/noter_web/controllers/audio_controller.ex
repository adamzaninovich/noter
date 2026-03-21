defmodule NoterWeb.AudioController do
  use NoterWeb, :controller

  alias Noter.Uploads

  def merged(conn, %{"session_id" => session_id}) do
    path = Path.join(Uploads.session_dir(session_id), "merged.wav")

    if File.exists?(path) do
      conn
      |> put_resp_content_type("audio/wav")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def peaks(conn, %{"session_id" => session_id}) do
    path = Path.join(Uploads.session_dir(session_id), "peaks.json")

    if File.exists?(path) do
      conn
      |> put_resp_content_type("application/json")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end
end
