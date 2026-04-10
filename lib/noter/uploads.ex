defmodule Noter.Uploads do
  @moduledoc """
  File system operations for session audio uploads, including directory management,
  track processing, waveform generation, and audio trimming.
  """

  require Logger

  alias Noter.Prep

  def session_dir(session_id) do
    base = uploads_dir()
    full = Path.join(base, to_string(session_id)) |> Path.expand()

    if String.starts_with?(full, Path.expand(base) <> "/") do
      full
    else
      raise ArgumentError, "session_id results in path outside uploads directory"
    end
  end

  def uploads_dir do
    Application.get_env(:noter, :uploads_dir) ||
      Path.join(Application.app_dir(:noter, "priv"), "uploads")
  end

  def process_uploads(
        session,
        campaign,
        zip_path,
        vocab_path,
        on_progress \\ fn _ -> :ok end
      ) do
    base_dir = session_dir(session.id)
    extracted_dir = Path.join(base_dir, "extracted")
    renamed_dir = Path.join(base_dir, "renamed")
    wav_dest = Path.join(base_dir, "merged.wav")
    vocab_dest = Path.join(base_dir, "vocab.txt")

    File.mkdir_p!(base_dir)
    File.mkdir_p!(extracted_dir)

    if vocab_path do
      on_progress.("Copying vocabulary file...")
      move_file!(vocab_path, vocab_dest)
    end

    on_progress.("Extracting ZIP archive...")

    with :ok <- Prep.extract_zip(zip_path, extracted_dir) do
      on_progress.("Renaming tracks...")
      {:ok, renamed} = Prep.rename_flacs(extracted_dir, renamed_dir, campaign.player_map)

      on_progress.("Mixing and normalizing audio...")

      with :ok <- mix_tracks_to_wav(renamed_dir, wav_dest) do
        on_progress.("Cleaning up temporary files...")
        log_file_op(File.rm(zip_path), "rm #{zip_path}")
        log_file_op(File.rm_rf(extracted_dir), "rm_rf #{extracted_dir}")
        {:ok, renamed}
      end
    end
  end

  def mix_tracks_to_wav(renamed_dir, output_wav_path) do
    flac_files = Prep.find_flac_files(renamed_dir) |> Enum.sort()

    if flac_files == [] do
      {:error, "no FLAC files found in #{renamed_dir}"}
    else
      count = length(flac_files)

      input_args = Enum.flat_map(flac_files, fn path -> ["-i", path] end)

      anull_filters =
        flac_files
        |> Enum.with_index()
        |> Enum.map_join(";", fn {_path, i} -> "[#{i}:a]anull[aud#{i}]" end)

      mix_inputs = Enum.map_join(0..(count - 1), "", fn i -> "[aud#{i}]" end)
      filter_complex = "#{anull_filters};#{mix_inputs}amix=#{count},dynaudnorm[aud]"

      args =
        ["-y"] ++
          input_args ++
          ["-filter_complex", filter_complex, "-map", "[aud]", "-ac", "1", output_wav_path]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {out, code} ->
          {:error, "ffmpeg mix failed (exit #{code}): #{String.slice(out, -200..-1)}"}
      end
    end
  end

  def generate_peaks(session_id) do
    base_dir = session_dir(session_id)
    wav_path = Path.join(base_dir, "merged.wav")
    peaks_path = Path.join(base_dir, "peaks.json")

    case System.cmd(
           "audiowaveform",
           ["-i", wav_path, "-o", peaks_path, "--pixels-per-second", "10", "-b", "8"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok, peaks_path}

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
    duration = end_seconds - start_seconds

    flac_jobs =
      Enum.map(flac_files, fn path ->
        basename = Path.basename(path, ".flac")
        character_name = Prep.resolve_character(basename, session.campaign.player_map)
        output_path = Path.join(trimmed_dir, "#{character_name}.flac")
        {"#{character_name}.flac", path, output_path}
      end)

    wav_job = [{"merged.wav", wav_path, trimmed_wav}]

    result = parallel_clip(flac_jobs ++ wav_job, start_seconds, duration, on_progress)

    case result do
      :ok ->
        :ok

      error ->
        File.rm_rf(trimmed_dir)
        error
    end
  end

  def encode_merged_m4a(session_id, duration, on_progress \\ fn _pct -> :ok end) do
    base_dir = session_dir(session_id)
    trimmed_dir = Path.join(base_dir, "trimmed")
    trimmed_wav = Path.join(trimmed_dir, "merged.wav")
    trimmed_m4a = Path.join(trimmed_dir, "merged.m4a")

    case ffmpeg_with_progress(
           trimmed_wav,
           trimmed_m4a,
           [],
           ["-c:a", "aac", "-b:a", "192k"],
           duration,
           on_progress
         ) do
      :ok ->
        log_file_op(File.rm(trimmed_wav), "rm #{trimmed_wav}")
        :ok

      error ->
        error
    end
  end

  defp parallel_clip(jobs, start_seconds, duration, on_progress) do
    results =
      jobs
      |> Task.async_stream(
        fn {label, input, output} ->
          ffmpeg_with_progress(
            input,
            output,
            ["-ss", to_string(start_seconds)],
            ["-t", to_string(duration)],
            duration,
            fn pct -> on_progress.(label, pct) end
          )
        end,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.to_list()

    case Enum.find(results, fn {:ok, result} -> result != :ok end) do
      nil -> :ok
      {:ok, err} -> err
    end
  end

  defp ffmpeg_with_progress(
         input,
         output,
         pre_input_args,
         post_input_args,
         duration_seconds,
         on_percent
       ) do
    total_us = trunc(duration_seconds * 1_000_000)
    ffmpeg = System.find_executable("ffmpeg") || "ffmpeg"

    args =
      ["-y", "-nostats", "-loglevel", "error"] ++
        pre_input_args ++
        ["-i", input] ++
        post_input_args ++
        ["-progress", "pipe:1", output]

    port =
      Port.open({:spawn_executable, ffmpeg}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    on_percent.(0)
    collect_ffmpeg_progress(port, "", total_us, -1, on_percent)
  end

  defp collect_ffmpeg_progress(port, buffer, total_us, last_pct, on_percent) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data
        {lines, leftover} = split_lines(buffer)

        last_pct =
          Enum.reduce(lines, last_pct, fn line, acc ->
            case parse_progress_percent(line, total_us) do
              nil ->
                acc

              pct when pct != acc ->
                on_percent.(pct)
                pct

              _ ->
                acc
            end
          end)

        collect_ffmpeg_progress(port, leftover, total_us, last_pct, on_percent)

      {^port, {:exit_status, 0}} ->
        on_percent.(100)
        :ok

      {^port, {:exit_status, code}} ->
        {:error, "ffmpeg failed (exit #{code}) for #{inspect(port)}"}
    end
  end

  defp parse_progress_percent("out_time_us=" <> val, total_us) when total_us > 0 do
    case Integer.parse(String.trim(val)) do
      {us, _} -> min(100, trunc(us / total_us * 100))
      :error -> nil
    end
  end

  defp parse_progress_percent(_, _), do: nil

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [leftover]} = Enum.split(parts, -1)
    {complete, leftover}
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

  defp log_file_op(:ok, _label), do: :ok
  defp log_file_op({:ok, _} = result, _label), do: result

  defp log_file_op({:error, reason} = error, label) do
    Logger.warning("File operation failed (#{label}): #{inspect(reason)}")
    error
  end
end
