defmodule Noter.Transcription.Transcript do
  @moduledoc """
  Pure functions for parsing transcript JSON into turns and applying word replacements.
  """

  @doc """
  Parses transcript JSON string into turns — consecutive same-speaker segments grouped together.

  Each turn:
    %{id: 0, speaker: "Adam", start: 2.64, end: 15.3,
      segments: [seg1, seg2, ...],
      words: [%{"word" => "Hello", "start" => 0.5, "end" => 0.8}, ...]}
  """
  def parse_turns(nil), do: []

  def parse_turns(json_string) when is_binary(json_string) do
    json_string
    |> Jason.decode!()
    |> Map.get("segments", [])
    |> group_consecutive_speakers()
    |> Enum.with_index(fn turn, idx -> Map.put(turn, :id, idx) end)
  end

  defp group_consecutive_speakers(segments) do
    segments
    |> Enum.chunk_by(& &1["speaker"])
    |> Enum.map(fn segs ->
      first = List.first(segs)
      last = List.last(segs)
      words = Enum.flat_map(segs, &Map.get(&1, "words", []))

      %{
        speaker: first["speaker"],
        start: first["start"],
        end: last["end"],
        segments: segs,
        words: words
      }
    end)
  end

  @doc """
  Applies replacements to turn words. Supports multi-word find patterns by matching
  against concatenated stripped tokens. Annotates each word with `:replaced?`, `:original`.
  """
  def apply_replacements(turns, replacements) when map_size(replacements) == 0 do
    Enum.map(turns, fn turn ->
      words =
        Enum.map(turn.words, fn w ->
          %{word: w["word"], start: w["start"], end: w["end"], replaced?: false, original: nil}
        end)

      Map.put(turn, :display_words, words)
    end)
  end

  def apply_replacements(turns, replacements) do
    patterns = build_patterns(replacements)

    Enum.map(turns, fn turn ->
      display_words = apply_patterns_to_words(turn.words, patterns)
      Map.put(turn, :display_words, display_words)
    end)
  end

  @doc """
  Returns a map of find_word => count for each replacement key.
  """
  def match_counts(_turns, replacements) when map_size(replacements) == 0, do: %{}

  def match_counts(turns, replacements) do
    patterns = build_patterns(replacements)

    Enum.reduce(turns, %{}, fn turn, acc ->
      count_matches_in_words(turn.words, patterns, acc)
    end)
  end

  defp build_patterns(replacements) do
    replacements
    |> Enum.map(fn {find, replace} ->
      # Tokenize the find string the same way we'll compare: split on whitespace
      find_tokens = String.split(find)
      regex = ~r/\A#{Regex.escape(find)}\z/i
      {find, replace, find_tokens, regex}
    end)
    |> Enum.sort_by(fn {_, _, tokens, _} -> -length(tokens) end)
  end

  # Walk the word list, trying multi-word patterns first (longest match wins).
  # Returns annotated display_words list.
  defp apply_patterns_to_words(words, patterns) do
    apply_patterns_to_words(words, patterns, [])
  end

  defp apply_patterns_to_words([], _patterns, acc), do: Enum.reverse(acc)

  defp apply_patterns_to_words(words, patterns, acc) do
    case find_matching_pattern(words, patterns) do
      {pattern, match_len} ->
        {matched, rest} = Enum.split(words, match_len)
        {_find, replace, tokens, _regex} = pattern
        annotated = annotate_matched_words(matched, replace, tokens)
        apply_patterns_to_words(rest, patterns, Enum.reverse(annotated) ++ acc)

      nil ->
        [w | rest] = words

        plain = %{
          word: w["word"],
          start: w["start"],
          end: w["end"],
          replaced?: false,
          original: nil
        }

        apply_patterns_to_words(rest, patterns, [plain | acc])
    end
  end

  defp find_matching_pattern(words, patterns) do
    Enum.find_value(patterns, fn {_find, _replace, find_tokens, _regex} = pattern ->
      token_count = length(find_tokens)

      if token_count <= length(words) do
        candidate_words = Enum.take(words, token_count)
        candidate_stripped = Enum.map(candidate_words, fn w -> strip_word(w["word"]) end)

        if tokens_match?(candidate_stripped, find_tokens) do
          {pattern, token_count}
        end
      end
    end)
  end

  defp tokens_match?(word_tokens, find_tokens) do
    Enum.zip(word_tokens, find_tokens)
    |> Enum.all?(fn {word, find} ->
      String.downcase(word) == String.downcase(strip_word(find))
    end)
  end

  # For a multi-word match, put the replacement text on the first word and
  # mark remaining matched words as consumed (empty display).
  # Only preserves trailing punctuation from the last word that goes beyond
  # what the find pattern's last token already includes.
  defp annotate_matched_words(matched_words, replace, find_tokens) do
    [first | rest] = matched_words
    {prefix, _suffix} = extract_affixes(first["word"])
    last_word = List.last(matched_words)
    {_prefix, word_suffix} = extract_affixes(last_word["word"])
    last_find_token = List.last(find_tokens)
    {_prefix, find_suffix} = extract_affixes(last_find_token)
    suffix = extra_suffix(word_suffix, find_suffix)
    original = Enum.map_join(matched_words, " ", fn w -> strip_word(w["word"]) end)

    first_annotated = %{
      word: prefix <> replace <> suffix,
      start: first["start"],
      end: first["end"],
      replaced?: true,
      original: original
    }

    rest_annotated =
      Enum.map(rest, fn w ->
        %{word: "", start: w["start"], end: w["end"], replaced?: true, original: ""}
      end)

    [first_annotated | rest_annotated]
  end

  # Count matches using the same multi-word sliding window approach
  defp count_matches_in_words([], _patterns, acc), do: acc

  defp count_matches_in_words(words, patterns, acc) do
    case find_matching_pattern(words, patterns) do
      {pattern, match_len} ->
        {_find, _replace, _tokens, _regex} = pattern
        find = elem(pattern, 0)
        rest = Enum.drop(words, match_len)
        count_matches_in_words(rest, patterns, Map.update(acc, find, 1, &(&1 + 1)))

      nil ->
        count_matches_in_words(tl(words), patterns, acc)
    end
  end

  # Returns only the portion of word_suffix that goes beyond find_suffix.
  # e.g. word_suffix=".", find_suffix="." => ""
  #      word_suffix=",", find_suffix="" => ","
  #      word_suffix=".,", find_suffix="." => ","
  defp extra_suffix(word_suffix, find_suffix) do
    if String.starts_with?(word_suffix, find_suffix) do
      String.replace_prefix(word_suffix, find_suffix, "")
    else
      word_suffix
    end
  end

  defp strip_word(word) do
    word
    |> String.trim_leading()
    |> String.replace(~r/[.,;:!?\-"')\]]+\z/, "")
  end

  defp extract_affixes(word) do
    prefix =
      case Regex.run(~r/\A(\s+)/, word) do
        [_, ws] -> ws
        _ -> ""
      end

    suffix =
      case Regex.run(~r/([.,;:!?\-"')\]]+)\z/, word) do
        [_, punct] -> punct
        _ -> ""
      end

    {prefix, suffix}
  end
end
