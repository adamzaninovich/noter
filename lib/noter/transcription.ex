defmodule Noter.Transcription do
  @moduledoc """
  Client for submitting audio transcription jobs to the external service.
  """

  alias Noter.Uploads

  def submit_job(session_id) do
    with {:ok, base} <- base_url() do
      trimmed_dir = Path.join(Uploads.session_dir(session_id), "trimmed")
      vocab_path = Path.join(Uploads.session_dir(session_id), "vocab.txt")

      files =
        trimmed_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".flac"))
        |> Enum.sort()
        |> Enum.map(fn name ->
          path = Path.join(trimmed_dir, name)

          {"files[]",
           {File.stream!(path, 256_000),
            filename: name, content_type: "audio/flac", size: File.stat!(path).size}}
        end)

      files =
        if File.exists?(vocab_path) do
          files ++
            [
              {"files[]",
               {File.stream!(vocab_path), filename: "vocab.txt", content_type: "text/plain"}}
            ]
        else
          files
        end

      url = base <> "/jobs"

      case Req.post(url, form_multipart: files, receive_timeout: 600_000) do
        {:ok, %{status: status, body: %{"job_id" => job_id}}} when status in 200..299 ->
          {:ok, job_id}

        {:ok, %{body: body}} ->
          {:error, "Transcription API error: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Transcription API request failed: #{inspect(reason)}"}
      end
    end
  end

  def cancel_job(job_id) do
    with {:ok, base} <- base_url() do
      url = base <> "/jobs/#{job_id}"

      case Req.delete(url, receive_timeout: 10_000) do
        {:ok, %{status: status}} when status in [200, 404, 409] ->
          :ok

        {:ok, %{body: body}} ->
          {:error, "Cancel error: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Cancel request failed: #{inspect(reason)}"}
      end
    end
  end

  def poll_job(job_id) do
    with {:ok, base} <- base_url() do
      url = base <> "/jobs/#{job_id}"

      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{body: body}} ->
          {:error, "Poll error: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Poll request failed: #{inspect(reason)}"}
      end
    end
  end

  def stream_url(job_id) do
    case base_url() do
      {:ok, base} -> {:ok, base <> "/jobs/#{job_id}/events"}
      error -> error
    end
  end

  defp base_url do
    case Noter.Settings.get("transcription_url") do
      nil -> {:error, :not_configured}
      "" -> {:error, :not_configured}
      url -> {:ok, url}
    end
  end
end
