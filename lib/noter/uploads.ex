defmodule Noter.Uploads do
  alias Noter.Prep

  def session_dir(session_id) do
    Path.join([Application.app_dir(:noter, "priv"), "uploads", to_string(session_id)])
  end

  def process_uploads(session, campaign, zip_path, aac_path, vocab_path) do
    base_dir = session_dir(session.id)
    extracted_dir = Path.join(base_dir, "extracted")
    renamed_dir = Path.join(base_dir, "renamed")

    File.mkdir_p!(base_dir)
    File.mkdir_p!(extracted_dir)

    # Move consumed files into session dir
    aac_dest = Path.join(base_dir, "merged.aac")
    vocab_dest = Path.join(base_dir, "vocab.txt")

    if aac_path, do: File.rename!(aac_path, aac_dest)
    if vocab_path, do: File.rename!(vocab_path, vocab_dest)

    # Extract zip, rename FLACs, clean up intermediates
    with :ok <- Prep.extract_zip(zip_path, extracted_dir),
         {:ok, renamed} <- Prep.rename_flacs(extracted_dir, renamed_dir, campaign.player_map) do
      File.rm(zip_path)
      File.rm_rf(extracted_dir)
      {:ok, renamed}
    end
  end

  def generate_peaks(session_id) do
    base_dir = session_dir(session_id)
    aac_path = Path.join(base_dir, "merged.aac")
    wav_path = Path.join(base_dir, "merged.wav")
    peaks_path = Path.join(base_dir, "peaks.json")

    with {_, 0} <-
           System.cmd("ffmpeg", ["-y", "-i", aac_path, "-ac", "1", wav_path],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd(
             "audiowaveform",
             ["-i", wav_path, "-o", peaks_path, "--pixels-per-second", "10", "-b", "8"],
             stderr_to_stdout: true
           ) do
      {:ok, peaks_path}
    else
      {out, code} ->
        {:error, "peaks generation failed (exit #{code}): #{String.slice(out, -200..-1)}"}
    end
  end

  def get_duration(session_id) do
    wav_path = Path.join(session_dir(session_id), "merged.wav")

    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-show_entries",
           "format=duration",
           "-of",
           "csv=p=0",
           wav_path
         ]) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {duration, _} ->
            {:ok, duration}

          :error ->
            {:error, "could not parse duration from ffprobe output: #{String.trim(output)}"}
        end

      {out, code} ->
        {:error, "ffprobe failed (exit #{code}): #{out}"}
    end
  end

  def trim_session(session, start_seconds, end_seconds) do
    base_dir = session_dir(session.id)
    renamed_dir = Path.join(base_dir, "renamed")
    trimmed_dir = Path.join(base_dir, "trimmed")
    File.mkdir_p!(trimmed_dir)

    with :ok <-
           precise_clip_all(
             renamed_dir,
             trimmed_dir,
             session.campaign.player_map,
             start_seconds,
             end_seconds
           ),
         :ok <-
           precise_clip(
             Path.join(base_dir, "merged.wav"),
             Path.join(trimmed_dir, "merged.wav"),
             start_seconds,
             end_seconds
           ) do
      :ok
    else
      error ->
        File.rm_rf(trimmed_dir)
        error
    end
  end

  def cleanup_wav(session_id) do
    session_dir(session_id)
    |> Path.join("merged.wav")
    |> File.rm()
  end

  defp precise_clip(input, output, start_seconds, end_seconds) do
    duration = end_seconds - start_seconds

    args = [
      "-y",
      "-i",
      input,
      "-ss",
      to_string(start_seconds),
      "-t",
      to_string(duration),
      "-af",
      "atrim=0:#{duration},asetpts=PTS-STARTPTS",
      output
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "ffmpeg failed (exit #{code}) for #{Path.basename(input)}: #{out}"}
    end
  end

  defp precise_clip_all(source_dir, output_dir, player_map, start_seconds, end_seconds) do
    source_dir
    |> Prep.find_flac_files()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      basename = Path.basename(path, ".flac")
      character_name = Prep.resolve_character(basename, player_map)
      output_path = Path.join(output_dir, "#{character_name}.flac")

      case precise_clip(path, output_path, start_seconds, end_seconds) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  def list_renamed_files(session_id) do
    dir = Path.join(session_dir(session_id), "renamed")

    if File.dir?(dir) do
      dir
      |> Prep.find_flac_files()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()
    else
      []
    end
  end
end
