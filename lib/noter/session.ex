defmodule Noter.Session do
  @moduledoc """
  Finds and validates session files, and locates the previous session for
  context inheritance.

  Session directory layout (after all pipeline steps):
    session-N/
      tracks/
        Character.flac
        ...
        vocab.txt
      transcripts/
        Character.json
        merged.json
        merged.srt
      campaign-context.md
      session-N-notes.md
  """

  @doc """
  Returns the path to the merged transcript JSON for the given session directory.
  """
  def merged_json_path(session_dir) do
    Path.join([session_dir, "transcripts", "merged.json"])
  end

  @doc """
  Returns the path to the merged SRT file for the given session directory.
  """
  def merged_srt_path(session_dir) do
    Path.join([session_dir, "transcripts", "merged.srt"])
  end

  @doc """
  Returns the expected notes output path for the session.
  The filename is derived from the session directory name.
  """
  def notes_path(session_dir) do
    session_name = Path.basename(session_dir)
    Path.join(session_dir, "#{session_name}-notes.md")
  end

  @doc """
  Returns the path to the campaign context file for this session.
  """
  def context_path(session_dir) do
    Path.join(session_dir, "campaign-context.md")
  end

  @doc """
  Validates that a session directory has the required transcripts to run
  the LLM pipeline. Returns `:ok` or `{:error, reason}`.
  """
  def validate_for_run(session_dir) do
    merged = merged_json_path(session_dir)

    cond do
      not File.dir?(session_dir) ->
        {:error, "Session directory does not exist: #{session_dir}"}

      not File.exists?(merged) ->
        {:error, "Missing merged transcript: #{merged}\nRun transcribe-audio first."}

      true ->
        :ok
    end
  end

  @doc """
  Finds the previous session directory by looking at sibling directories
  (sorted lexicographically) and returning the one immediately before
  `session_dir`. Returns `{:ok, prev_dir}` or `{:error, :no_previous_session}`.
  """
  def find_previous_session(session_dir) do
    session_dir = Path.expand(session_dir)
    parent = Path.dirname(session_dir)
    current_name = Path.basename(session_dir)

    siblings =
      parent
      |> File.ls!()
      |> Enum.filter(fn name ->
        File.dir?(Path.join(parent, name)) and name < current_name
      end)
      |> Enum.sort()

    case List.last(siblings) do
      nil -> {:error, :no_previous_session}
      name -> {:ok, Path.join(parent, name)}
    end
  end

  @doc """
  Reads the merged transcript JSON from the session's transcripts/ directory.
  Returns `{:ok, %{segments: [...], duration: float}}` or `{:error, reason}`.
  """
  def read_transcript(session_dir) do
    path = merged_json_path(session_dir)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      segments =
        data
        |> Map.get("segments", [])
        |> Enum.map(fn s ->
          %{
            start: s["start"] || 0.0,
            end: s["end"] || 0.0,
            speaker: s["speaker"] || "UNKNOWN",
            text: s["text"] || ""
          }
        end)

      duration =
        case Map.get(data, "duration") do
          nil -> segments |> Enum.map(& &1.end) |> Enum.max(fn -> 0.0 end)
          d -> d * 1.0
        end

      {:ok, %{segments: segments, duration: duration}}
    end
  end
end
