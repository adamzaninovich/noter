defmodule Noter.Corrections do
  @moduledoc """
  SRT corrections review: extracts unknown terms from a merged SRT,
  flags them for human review, and saves new corrections back to corrections.toml.
  """

  @doc """
  Reads a merged SRT file and extracts all unique words not already covered
  by `vocab` or `corrections`.

  Returns a sorted list of suspicious terms.
  """
  def find_unknown_terms(srt_path, vocab, corrections) do
    known =
      (vocab ++ Map.keys(corrections) ++ Map.values(corrections))
      |> MapSet.new(&String.downcase/1)

    srt_path
    |> File.read!()
    |> extract_srt_words()
    |> Enum.reject(fn word -> MapSet.member?(known, String.downcase(word)) end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort()
  end

  @doc """
  Interactive corrections review loop. Prints each unknown term and prompts
  the user to either skip (Enter), provide a correction, or quit.

  Returns the updated corrections map.
  """
  def interactive_review(unknown_terms, corrections) do
    IO.puts("\nReviewing #{length(unknown_terms)} unknown terms.")
    IO.puts("Press Enter to skip, type a correction to save it, or 'q' to quit.\n")

    Enum.reduce_while(unknown_terms, corrections, fn term, acc ->
      IO.write("  #{term} → ")
      input = IO.gets("") |> String.trim()

      cond do
        input == "q" ->
          {:halt, acc}

        input == "" ->
          {:cont, acc}

        true ->
          IO.puts("    saved: #{term} → #{input}")
          {:cont, Map.put(acc, term, input)}
      end
    end)
  end

  defp extract_srt_words(srt_content) do
    # SRT format: sequence numbers, timestamps, and text lines
    # Skip sequence numbers (pure integers) and timestamp lines
    srt_content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      line = String.trim(line)
      line == "" or Regex.match?(~r/^\d+$/, line) or Regex.match?(~r/\d{2}:\d{2}:\d{2}/, line)
    end)
    |> Enum.flat_map(fn line ->
      ~r/[A-Za-z'\-]+/
      |> Regex.scan(line)
      |> List.flatten()
    end)
  end
end
