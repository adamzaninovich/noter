defmodule Noter.Prep do
  @moduledoc """
  Handles audio preparation: extracting a zip, clipping tracks to session
  timestamps, and renaming files using a player map.

  Requires ffmpeg to be available on PATH.
  """

  @doc """
  Extracts a zip archive into `dest_dir`.
  """
  def extract_zip(zip_path, dest_dir) do
    case System.cmd("unzip", ["-o", zip_path, "-d", dest_dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "unzip failed (exit #{code}): #{output}"}
    end
  end

  @doc """
  Returns a list of FLAC file paths directly inside `dir` (not in subdirs).
  """
  def find_flac_files(dir) do
    Path.wildcard(Path.join(dir, "*.flac"))
  end

  @doc """
  Renames a FLAC file using the player map.

  Handles filenames like "2-indifferentpineapple.flac" by stripping the
  numeric prefix before looking up the discord username in the player map.
  Returns the character name, or the original username if not found.
  """
  def resolve_character(basename, player_map) do
    username =
      case Regex.run(~r/^\d+-(.+)$/, basename) do
        [_, name] -> name
        nil -> basename
      end

    Map.get(player_map, username, username)
  end

  @doc """
  Clips an audio file to the given start/end timestamps using ffmpeg.

  `start_ts` and `end_ts` are strings in "HH:MM:SS" or seconds format.
  """
  def ffmpeg_clip(input, output, start_ts, end_ts) do
    args = ["-y", "-i", input, "-ss", start_ts, "-to", end_ts, "-c", "copy", output]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "ffmpeg failed (exit #{code}) for #{Path.basename(input)}: #{out}"}
    end
  end

  @doc """
  Clips and renames all FLAC files using the player map and timestamps.

  Reads FLACs from `source_dir`, writes clipped and renamed files to `output_dir`.
  """
  def clip_and_rename(source_dir, output_dir, player_map, start_ts, end_ts) do
    File.mkdir_p!(output_dir)

    source_dir
    |> find_flac_files()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      basename = Path.basename(path, ".flac")
      character_name = resolve_character(basename, player_map)
      output_path = Path.join(output_dir, "#{character_name}.flac")

      case ffmpeg_clip(path, output_path, start_ts, end_ts) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end
end
