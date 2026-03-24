defmodule NoterWeb.AudioController do
  use NoterWeb, :controller

  alias Noter.Uploads

  plug :validate_session_id when action in [:merged, :trimmed_merged, :peaks]

  def merged(conn, _params) do
    path = Path.join(Uploads.session_dir(conn.assigns.session_id), "merged.wav")

    if File.exists?(path) do
      send_file_with_range(conn, path, "audio/wav")
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def trimmed_merged(conn, _params) do
    path = Path.join([Uploads.session_dir(conn.assigns.session_id), "trimmed", "merged.m4a"])

    if File.exists?(path) do
      send_file_with_range(conn, path, "audio/mp4")
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def peaks(conn, _params) do
    path = Path.join(Uploads.session_dir(conn.assigns.session_id), "peaks.json")

    if File.exists?(path) do
      conn
      |> put_resp_content_type("application/json")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end

  defp validate_session_id(conn, _opts) do
    case Integer.parse(conn.params["session_id"]) do
      {id, ""} when id > 0 ->
        assign(conn, :session_id, id)

      _ ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp send_file_with_range(conn, path, content_type) do
    %{size: total} = File.stat!(path)

    case get_req_header(conn, "range") do
      ["bytes=" <> range_spec] ->
        {offset, length} = parse_range(range_spec, total)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{total}")
        |> send_file(206, path, offset, length)

      _ ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> send_file(200, path)
    end
  end

  defp parse_range(range_spec, total) do
    case String.split(range_spec, "-", parts: 2) do
      ["", suffix] ->
        suffix_len = String.to_integer(suffix)
        offset = total - suffix_len
        {offset, suffix_len}

      [start_str, ""] ->
        offset = String.to_integer(start_str)
        {offset, total - offset}

      [start_str, end_str] ->
        offset = String.to_integer(start_str)
        range_end = String.to_integer(end_str)
        {offset, range_end - offset + 1}
    end
  end
end
