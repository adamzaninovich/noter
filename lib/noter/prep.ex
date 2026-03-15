defmodule Noter.Prep do
  @moduledoc """
  Handles audio preparation: extracting the zip, clipping tracks to session
  timestamps, and renaming files using the player map.

  Requires ffmpeg to be available on PATH.
  """

  alias Noter.Campaign

  @doc """
  Runs the full prep pipeline for a session directory.

    1. Finds the zip archive in `session_dir`
    2. Extracts it into `session_dir`
    3. Clips each FLAC track to `start_ts`–`end_ts`
    4. Renames files using `players.toml` and moves them to `tracks/`

  `start_ts` and `end_ts` are strings in "HH:MM:SS" format.
  """
  def run(session_dir, campaign_dir, start_ts, end_ts) do
    session_dir = Path.expand(session_dir)
    tracks_dir = Path.join(session_dir, "tracks")
    File.mkdir_p!(tracks_dir)

    with {:ok, players} <- Campaign.load_players(campaign_dir),
         {:ok, zip_path} <- find_zip(session_dir),
         :ok <- extract_zip(zip_path, session_dir),
         flac_files = find_flac_files(session_dir),
         :ok <- clip_and_rename(flac_files, tracks_dir, players, start_ts, end_ts) do
      copy_vocab(campaign_dir, tracks_dir)
      :ok
    end
  end

  defp find_zip(session_dir) do
    case Path.wildcard(Path.join(session_dir, "*.zip")) do
      [zip | _] -> {:ok, zip}
      [] -> {:error, "No zip file found in #{session_dir}"}
    end
  end

  defp extract_zip(zip_path, dest_dir) do
    IO.puts("Extracting #{Path.basename(zip_path)}...")

    case System.cmd("unzip", ["-o", zip_path, "-d", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "unzip failed (exit #{code}): #{output}"}
    end
  end

  defp find_flac_files(session_dir) do
    # Find FLAC files directly in session_dir (not in subdirs)
    Path.wildcard(Path.join(session_dir, "*.flac"))
  end

  defp clip_and_rename(flac_files, tracks_dir, players, start_ts, end_ts) do
    Enum.reduce_while(flac_files, :ok, fn path, :ok ->
      basename = Path.basename(path, ".flac")
      character_name = resolve_character(basename, players)
      output_path = Path.join(tracks_dir, "#{character_name}.flac")

      IO.puts("  #{Path.basename(path)} → #{character_name}.flac")

      case ffmpeg_clip(path, output_path, start_ts, end_ts) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # Handles filenames like "2-indifferentpineapple.flac" → look up "indifferentpineapple"
  defp resolve_character(basename, players) do
    username =
      case Regex.run(~r/^\d+-(.+)$/, basename) do
        [_, name] -> name
        nil -> basename
      end

    Map.get(players, username, username)
  end

  defp ffmpeg_clip(input, output, start_ts, end_ts) do
    args = ["-y", "-i", input, "-ss", start_ts, "-to", end_ts, "-c", "copy", output]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "ffmpeg failed (exit #{code}) for #{Path.basename(input)}: #{out}"}
    end
  end

  defp copy_vocab(campaign_dir, tracks_dir) do
    src = Path.join(campaign_dir, "vocab.txt")
    dst = Path.join(tracks_dir, "vocab.txt")

    if File.exists?(src) do
      File.copy!(src, dst)
    end
  end
end
