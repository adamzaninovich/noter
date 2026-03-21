defmodule NoterWeb.AudioController do
  use NoterWeb, :controller

  alias Noter.Uploads

  def merged(conn, %{"session_id" => session_id}) do
    path = Path.join(Uploads.session_dir(session_id), "merged.wav")

    if File.exists?(path) do
      send_file_with_range(conn, path, "audio/wav")
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def trimmed_merged(conn, %{"session_id" => session_id}) do
    path = Path.join([Uploads.session_dir(session_id), "trimmed", "merged.m4a"])

    if File.exists?(path) do
      send_file_with_range(conn, path, "audio/mp4")
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
