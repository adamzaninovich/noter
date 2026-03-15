defmodule Mix.Tasks.Noter.Prep do
  use Mix.Task

  @shortdoc "Extract zip, clip tracks to timestamps, rename to character names"

  @moduledoc """
  Prepares a session directory for transcription.

      mix noter.prep SESSION_DIR --start HH:MM:SS --end HH:MM:SS

  Steps:
    1. Discovers campaign dir by walking up from SESSION_DIR
    2. Extracts the zip archive into SESSION_DIR
    3. Clips each FLAC track to the given timestamps via ffmpeg
    4. Renames files using players.toml (discord username → character name)
    5. Moves clipped files to SESSION_DIR/tracks/
    6. Copies vocab.txt from campaign dir into tracks/ if present

  ## Options

    --start   Session start timestamp (required), e.g. 00:13:57
    --end     Session end timestamp (required), e.g. 03:27:37

  ## Example

      mix noter.prep ~/sessions/stonewalkers/session-3 --start 00:13:57 --end 03:27:37

  After running, hand the tracks/ directory to the transcribe-audio pipeline.
  """

  @switches [start: :string, end: :string]

  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    session_dir =
      case positional do
        [dir | _] ->
          dir

        [] ->
          Mix.raise(
            "SESSION_DIR is required. Usage: mix noter.prep SESSION_DIR --start HH:MM:SS --end HH:MM:SS"
          )
      end

    start_ts =
      Keyword.get(opts, :start) ||
        Mix.raise(
          "--start is required. Usage: mix noter.prep SESSION_DIR --start HH:MM:SS --end HH:MM:SS"
        )

    end_ts =
      Keyword.get(opts, :end) ||
        Mix.raise(
          "--end is required. Usage: mix noter.prep SESSION_DIR --start HH:MM:SS --end HH:MM:SS"
        )

    validate_timestamp!(start_ts, "--start")
    validate_timestamp!(end_ts, "--end")

    session_dir = Path.expand(session_dir)

    campaign_dir =
      case Noter.Campaign.find_campaign_dir(Path.dirname(session_dir)) do
        {:ok, dir} ->
          IO.puts("Campaign dir: #{dir}")
          dir

        {:error, :not_found} ->
          Mix.raise("""
          Could not find campaign directory (no players.toml found walking up from #{session_dir}).
          Expected layout: campaign_dir/players.toml with session dirs as children of campaign_dir.
          """)
      end

    IO.puts("Preparing session: #{session_dir}")
    IO.puts("Clip range: #{start_ts} – #{end_ts}")

    case Noter.Prep.run(session_dir, campaign_dir, start_ts, end_ts) do
      :ok ->
        IO.puts("\nDone. Run the transcribe-audio pipeline on tracks/, then:\n")
        IO.puts("  mix noter.run #{session_dir}\n")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp validate_timestamp!(ts, flag) do
    unless Regex.match?(~r/^\d{2}:\d{2}:\d{2}$/, ts) do
      Mix.raise("#{flag} must be in HH:MM:SS format, got: #{ts}")
    end
  end
end
