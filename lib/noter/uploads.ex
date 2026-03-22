defmodule Noter.Uploads do
  alias Noter.Prep

  def session_dir(session_id) do
    Path.join([uploads_dir(), to_string(session_id)])
  end

  def uploads_dir do
    Application.get_env(:noter, :uploads_dir) ||
      Path.join(Application.app_dir(:noter, "priv"), "uploads")
  end

  def process_uploads(
        session,
        campaign,
        zip_path,
        aac_path,
        vocab_path,
        on_progress \\ fn _ -> :ok end
      ) do
    base_dir = session_dir(session.id)
    extracted_dir = Path.join(base_dir, "extracted")
    renamed_dir = Path.join(base_dir, "renamed")

    File.mkdir_p!(base_dir)
    File.mkdir_p!(extracted_dir)

    on_progress.("Copying audio file...")
    aac_dest = Path.join(base_dir, "merged.aac")
    vocab_dest = Path.join(base_dir, "vocab.txt")

    if aac_path, do: move_file!(aac_path, aac_dest)

    if vocab_path do
      on_progress.("Copying vocabulary file...")
      move_file!(vocab_path, vocab_dest)
    end

    on_progress.("Extracting ZIP archive...")

    with :ok <- Prep.extract_zip(zip_path, extracted_dir) do
      on_progress.("Renaming tracks...")
      {:ok, renamed} = Prep.rename_flacs(extracted_dir, renamed_dir, campaign.player_map)

      on_progress.("Cleaning up temporary files...")
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

  def trim_session(session, start_seconds, end_seconds, on_progress \\ fn _, _ -> :ok end) do
    base_dir = session_dir(session.id)
    renamed_dir = Path.join(base_dir, "renamed")
    trimmed_dir = Path.join(base_dir, "trimmed")
    File.mkdir_p!(trimmed_dir)

    flac_files = Prep.find_flac_files(renamed_dir)
    wav_path = Path.join(base_dir, "merged.wav")
    trimmed_wav = Path.join(trimmed_dir, "merged.wav")
    trimmed_m4a = Path.join(trimmed_dir, "merged.m4a")
    total = length(flac_files) + 2

    with :ok <-
           precise_clip_all_with_progress(
             flac_files,
             trimmed_dir,
             session.campaign.player_map,
             start_seconds,
             end_seconds,
             total,
             on_progress
           ),
         _ = on_progress.("merged.wav", {length(flac_files), total}),
         :ok <- precise_clip(wav_path, trimmed_wav, start_seconds, end_seconds),
         _ = on_progress.("merged.m4a", {length(flac_files) + 1, total}),
         :ok <- convert_wav_to_m4a(trimmed_wav, trimmed_m4a) do
      File.rm(trimmed_wav)
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

  defp convert_wav_to_m4a(input, output) do
    args = ["-y", "-i", input, "-c:a", "aac", "-b:a", "192k", output]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "ffmpeg wav→m4a failed (exit #{code}): #{out}"}
    end
  end

  defp precise_clip(input, output, start_seconds, end_seconds) do
    duration = end_seconds - start_seconds

    args = [
      "-y",
      "-ss",
      to_string(start_seconds),
      "-i",
      input,
      "-t",
      to_string(duration),
      output
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "ffmpeg failed (exit #{code}) for #{Path.basename(input)}: #{out}"}
    end
  end

  defp precise_clip_all_with_progress(
         flac_files,
         output_dir,
         player_map,
         start_seconds,
         end_seconds,
         total,
         on_progress
       ) do
    flac_files
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {path, index}, :ok ->
      basename = Path.basename(path, ".flac")
      character_name = Prep.resolve_character(basename, player_map)
      output_path = Path.join(output_dir, "#{character_name}.flac")
      on_progress.("#{character_name}.flac", {index, total})

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

  defp move_file!(source, dest) do
    File.cp!(source, dest)
    File.rm!(source)
  end
end
