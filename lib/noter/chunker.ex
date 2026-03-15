defmodule Noter.Chunker do
  @moduledoc """
  Splits a transcript into fixed-size time windows and applies corrections.
  Ported from the n8n Chunk Transcript node.
  """

  @default_chunk_minutes 10
  @default_overlap_seconds 0

  @doc """
  Chunks a transcript into time windows.

  Options:
    - `:chunk_minutes` - window size in minutes (default: 10)
    - `:overlap_seconds` - seconds of overlap between chunks (default: 0)

  Returns a list of chunk maps:
    %{
      chunk_index: integer,
      range_start_sec: float,
      range_end_sec: float,
      range_start: "HH:MM:SS",
      range_end: "HH:MM:SS",
      chunk_text: String.t()
    }
  """
  def chunk(transcript, corrections, speaker_map, opts \\ []) do
    chunk_minutes = Keyword.get(opts, :chunk_minutes, @default_chunk_minutes)
    overlap_seconds = Keyword.get(opts, :overlap_seconds, @default_overlap_seconds)
    chunk_size_sec = max(60, trunc(chunk_minutes * 60))

    segments =
      transcript.segments
      |> Enum.filter(fn s -> is_number(s.start) && is_number(s.end) end)
      |> Enum.sort_by(& &1.start)

    duration = transcript.duration
    compiled_corrections = precompile_corrections(corrections)

    build_chunks(segments, duration, chunk_size_sec, overlap_seconds, compiled_corrections, speaker_map)
  end

  defp build_chunks(segments, duration, chunk_size_sec, overlap_seconds, corrections, speaker_map) do
    0
    |> Stream.iterate(&(&1 + chunk_size_sec))
    |> Stream.take_while(&(&1 < duration))
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {window_start, chunk_index} ->
      window_end = min(duration, window_start + chunk_size_sec)

      window_segs =
        Enum.filter(segments, fn s ->
          s.start >= window_start && s.start < window_end
        end)

      if window_segs == [] do
        []
      else
        final_segs =
          if overlap_seconds > 0 do
            overlap_start = max(0.0, window_start - overlap_seconds)
            overlap_end = min(duration, window_end + overlap_seconds)

            Enum.filter(segments, fn s ->
              s.start >= overlap_start && s.start < overlap_end
            end)
          else
            window_segs
          end

        lines =
          final_segs
          |> Enum.map(&build_line(&1, corrections, speaker_map))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        chunk_text = Enum.join(lines, "\n")

        [
          %{
            chunk_index: chunk_index,
            range_start_sec: window_start,
            range_end_sec: window_end,
            range_start: sec_to_hms(window_start),
            range_end: sec_to_hms(window_end),
            chunk_text: chunk_text
          }
        ]
      end
    end)
  end

  defp build_line(seg, corrections, speaker_map) do
    ts = sec_to_hms(seg.start)
    raw_speaker = seg.speaker || "UNKNOWN"
    speaker = Map.get(speaker_map, raw_speaker, raw_speaker)
    text = seg.text |> normalize_whitespace() |> apply_corrections(corrections)

    if text == "", do: nil, else: "[#{ts}] #{speaker}: #{text}"
  end

  @doc """
  Precompiles correction patterns for efficient reuse across segments.
  """
  def precompile_corrections(corrections) when is_map(corrections) do
    corrections
    |> Enum.reject(fn {from, _} -> from == "" end)
    |> Enum.map(fn {from, to} ->
      escaped = Regex.escape(from)

      pattern =
        if Regex.match?(~r/^[A-Za-z0-9_'\-]+$/, from) do
          Regex.compile!("\\b#{escaped}\\b")
        else
          Regex.compile!(escaped)
        end

      {pattern, to}
    end)
  end

  @doc """
  Applies precompiled spelling/name corrections to text.
  """
  def apply_corrections(text, compiled_corrections) when is_list(compiled_corrections) do
    Enum.reduce(compiled_corrections, text, fn {pattern, to}, acc ->
      Regex.replace(pattern, acc, to)
    end)
  end

  defp normalize_whitespace(str) do
    str
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sec_to_hms(sec) do
    s = max(0, trunc(sec))
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    ss = rem(s, 60)
    [h, m, ss] |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end
end
