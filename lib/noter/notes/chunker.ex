defmodule Noter.Notes.Chunker do
  @moduledoc """
  Splits corrected transcript turns into fixed-size time windows for LLM processing.
  """

  @doc """
  Splits corrected turns into time-windowed text chunks.

  Input is the output of `Transcript.apply_corrections/3` — a list of maps with
  `%{speaker, start, end, text}` fields.

  Returns a list of chunk maps, one per non-empty window, 0-based index:
    %{index: integer, range_start: "HH:MM:SS", range_end: "HH:MM:SS", text: String.t()}
  """
  def chunk_turns(corrected_turns, window_seconds \\ 600)
  def chunk_turns([], _window_seconds), do: []

  def chunk_turns(corrected_turns, window_seconds) do
    first_start = List.first(corrected_turns).start
    last_end = List.last(corrected_turns).end

    first_start
    |> Stream.iterate(&(&1 + window_seconds))
    |> Enum.reduce_while([], fn window_start, acc ->
      if window_start >= last_end do
        {:halt, Enum.reverse(acc)}
      else
        {:cont, [window_start | acc]}
      end
    end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {window_start, idx} ->
      window_end = window_start + window_seconds

      turns =
        Enum.filter(corrected_turns, fn t ->
          t.start >= window_start and t.start < window_end
        end)

      if turns == [] do
        []
      else
        lines =
          turns
          |> Enum.map(fn t -> "[#{sec_to_hms(t.start)}] #{t.speaker}: #{t.text}" end)
          |> Enum.uniq()

        [
          %{
            index: idx,
            range_start: sec_to_hms(window_start),
            range_end: sec_to_hms(min(window_end, last_end)),
            text: Enum.join(lines, "\n")
          }
        ]
      end
    end)
  end

  defp sec_to_hms(seconds) do
    total = max(0, trunc(seconds))
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)
    "#{pad2(h)}:#{pad2(m)}:#{pad2(s)}"
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
