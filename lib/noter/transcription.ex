defmodule Noter.Transcription do
  @moduledoc """
  Client for submitting audio transcription jobs to the external service.
  """

  alias Noter.Uploads

  def submit_job(session_id, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _bytes_sent, _total_bytes -> :ok end)

    with {:ok, base} <- base_url(),
         {:ok, trimmed_dir} <- get_session_dir(session_id, "trimmed"),
         {:ok, vocab_path} <- get_vocab_path(session_id) do
      case File.ls(trimmed_dir) do
        {:ok, filenames} ->
          flac_files =
            filenames
            |> Enum.filter(&String.ends_with?(&1, ".flac"))
            |> Enum.sort()
            |> Enum.map(fn name ->
              path = Path.join(trimmed_dir, name)
              {:ok, %{size: size}} = File.stat(path)
              {name, path, size, "audio/flac"}
            end)

          vocab_files =
            if File.exists?(vocab_path) do
              {:ok, %{size: size}} = File.stat(vocab_path)
              [{Path.basename(vocab_path), vocab_path, size, "text/plain"}]
            else
              []
            end

          all_files = flac_files ++ vocab_files
          total_bytes = Enum.reduce(all_files, 0, fn {_, _, size, _}, acc -> acc + size end)
          counter = :counters.new(1, [:atomics])

          fields =
            Enum.map(all_files, fn {name, path, size, content_type} ->
              {:ok, stream} = {:ok, File.stream!(path, 256_000)}

              stream =
                stream
                |> Stream.each(fn chunk ->
                  chunk_size = IO.iodata_length(chunk)
                  :counters.add(counter, 1, chunk_size)
                  on_progress.(:counters.get(counter, 1), total_bytes)
                end)

              {"files[]", {stream, filename: name, content_type: content_type, size: size}}
            end)

          url = base <> "/jobs"

          case Req.post(url, form_multipart: fields, receive_timeout: 600_000) do
            {:ok, %{status: status, body: %{"job_id" => job_id}}} when status in 200..299 ->
              {:ok, job_id}

            {:ok, %{body: body}} ->
              {:error, "Transcription API error: #{inspect(body)}"}

            {:error, reason} ->
              {:error, "Transcription API request failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to read trimmed directory: #{inspect(reason)}"}
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

  defp get_session_dir(session_id, subdir) do
    path = Path.join(Uploads.session_dir(session_id), subdir)
    {:ok, path}
  end

  defp get_vocab_path(session_id) do
    path = Path.join(Uploads.session_dir(session_id), "vocab.txt")
    {:ok, path}
  end
end
