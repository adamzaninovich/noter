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

      words =
        segs
        |> Enum.flat_map(&Map.get(&1, "words", []))
        |> merge_hyphenated_words()

      %{
        speaker: first["speaker"],
        start: first["start"],
        end: last["end"],
        segments: segs,
        words: words
      }
    end)
  end

  # Merges word tokens that start with a hyphen into the previous word.
  # E.g. [" barrel", " -chested"] becomes [" barrel-chested"]
  defp merge_hyphenated_words(words) do
    words
    |> Enum.reduce([], fn word, acc ->
      trimmed = String.trim_leading(word["word"])

      case {acc, String.starts_with?(trimmed, "-")} do
        {[prev | rest], true} ->
          merged = %{
            "word" => prev["word"] <> trimmed,
            "start" => prev["start"],
            "end" => word["end"]
          }

          [merged | rest]

        _ ->
          [word | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Applies replacements to turn words. Supports multi-word find patterns by matching
  against concatenated stripped tokens. Annotates each word with `:replaced?`, `:original`.
  """
  def apply_replacements(turns, replacements) when map_size(replacements) == 0 do
    display_turns =
      Enum.map(turns, fn turn ->
        words =
          Enum.map(turn.words, fn w ->
            %{word: w["word"], start: w["start"], end: w["end"], replaced?: false, original: nil}
          end)

        Map.put(turn, :display_words, words)
      end)

    {display_turns, %{}}
  end

  def apply_replacements(turns, replacements) do
    patterns = build_patterns(replacements)
    {single_map, multi_patterns} = split_patterns(patterns)

    {display_turns_rev, counts} =
      Enum.reduce(turns, {[], %{}}, fn turn, {turns_acc, counts_acc} ->
        {display_words, turn_counts} =
          apply_and_count_words(turn.words, single_map, multi_patterns)

        merged_counts = Map.merge(counts_acc, turn_counts, fn _k, a, b -> a + b end)
        {[Map.put(turn, :display_words, display_words) | turns_acc], merged_counts}
      end)

    {Enum.reverse(display_turns_rev), counts}
  end

  defp build_patterns(replacements) do
    replacements
    |> Enum.map(fn {find, replace} ->
      find_tokens = String.split(find)
      stripped_downcased = Enum.map(find_tokens, &(&1 |> strip_word() |> String.downcase()))
      {find, replace, find_tokens, stripped_downcased}
    end)
    |> Enum.sort_by(fn {_, _, tokens, _} -> -length(tokens) end)
  end

  # Split patterns into a fast single-word lookup map and multi-word patterns list.
  defp split_patterns(patterns) do
    {multi, single} = Enum.split_with(patterns, fn {_, _, tokens, _} -> length(tokens) > 1 end)

    single_map =
      Map.new(single, fn {find, replace, find_tokens, _} ->
        key = find_tokens |> hd() |> strip_word() |> String.downcase()
        {key, {find, replace, find_tokens}}
      end)

    {single_map, multi}
  end

  # Single pass: applies replacements and counts matches simultaneously.
  # Uses indexed arrays for O(1) access and a hash map for single-word pattern lookup.
  defp apply_and_count_words(words, single_map, multi_patterns) do
    word_array = :array.from_list(words)
    len = :array.size(word_array)

    keys =
      :array.from_list(
        Enum.map(words, fn w -> w["word"] |> strip_word() |> String.downcase() end)
      )

    {display_words, counts} =
      apply_and_count(word_array, keys, len, 0, single_map, multi_patterns, [], %{})

    {display_words, counts}
  end

  defp apply_and_count(_wa, _keys, len, pos, _sm, _multi, acc, counts) when pos >= len do
    {Enum.reverse(acc), counts}
  end

  defp apply_and_count(wa, keys, len, pos, sm, multi, acc, counts) do
    key = :array.get(pos, keys)

    case find_multi_match(keys, len, pos, multi) do
      {pattern, match_len, _possessive?} ->
        {find, replace, find_tokens, _} = pattern
        matched = for i <- pos..(pos + match_len - 1), do: :array.get(i, wa)
        annotated = annotate_matched_words(matched, replace, find_tokens)
        new_counts = Map.update(counts, find, 1, &(&1 + 1))

        apply_and_count(
          wa,
          keys,
          len,
          pos + match_len,
          sm,
          multi,
          Enum.reverse(annotated) ++ acc,
          new_counts
        )

      nil ->
        case match_single(sm, key) do
          {:ok, {find, replace, find_tokens}, _possessive?} ->
            w = :array.get(pos, wa)
            annotated = annotate_matched_words([w], replace, find_tokens)
            new_counts = Map.update(counts, find, 1, &(&1 + 1))

            apply_and_count(
              wa,
              keys,
              len,
              pos + 1,
              sm,
              multi,
              Enum.reverse(annotated) ++ acc,
              new_counts
            )

          :error ->
            w = :array.get(pos, wa)

            plain = %{
              word: w["word"],
              start: w["start"],
              end: w["end"],
              replaced?: false,
              original: nil
            }

            apply_and_count(wa, keys, len, pos + 1, sm, multi, [plain | acc], counts)
        end
    end
  end

  # Looks up a single-word key in the map, falling back to possessive-stripped base.
  defp match_single(sm, key) do
    case Map.fetch(sm, key) do
      {:ok, match} ->
        {:ok, match, false}

      :error ->
        case strip_possessive(key) do
          {base, _} ->
            case Map.fetch(sm, base) do
              {:ok, match} -> {:ok, match, true}
              :error -> :error
            end

          :none ->
            :error
        end
    end
  end

  defp find_multi_match(_keys, _len, _pos, []), do: nil

  defp find_multi_match(keys, len, pos, multi_patterns) do
    Enum.find_value(multi_patterns, fn {_find, _replace, _tokens, stripped_downcased} = pattern ->
      token_count = length(stripped_downcased)

      if pos + token_count <= len do
        # Try exact match first
        exact? =
          stripped_downcased
          |> Enum.with_index()
          |> Enum.all?(fn {find_key, i} -> :array.get(pos + i, keys) == find_key end)

        if exact? do
          {pattern, token_count, false}
        else
          # Try possessive match: all tokens match except last has 's appended
          last_idx = token_count - 1

          possessive? =
            stripped_downcased
            |> Enum.with_index()
            |> Enum.all?(fn {find_key, i} ->
              actual = :array.get(pos + i, keys)

              if i == last_idx do
                case strip_possessive(actual) do
                  {base, _} -> base == find_key
                  :none -> false
                end
              else
                actual == find_key
              end
            end)

          if possessive?, do: {pattern, token_count, true}
        end
      end
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

  @doc """
  Applies per-turn edits to display-turns. If a turn's stringified id is in the edits map,
  its display_words are replaced with a single synthetic word containing the edited text.
  """
  def apply_edits(turns, edits) when map_size(edits) == 0 do
    Enum.map(turns, &Map.merge(&1, %{edited?: false, deleted?: false}))
  end

  def apply_edits(turns, edits) do
    Enum.map(turns, fn turn ->
      key = to_string(turn.id)

      case Map.fetch(edits, key) do
        {:ok, ""} ->
          Map.merge(turn, %{edited?: false, deleted?: true})

        {:ok, edited_text} ->
          original_text = Enum.map_join(turn.words, fn w -> w["word"] end)

          turn
          |> Map.merge(%{edited?: true, deleted?: false, original_text: original_text})
          |> Map.put(:display_words, [
            %{
              word: edited_text,
              replaced?: false,
              original: nil,
              start: turn.start,
              end: turn.end
            }
          ])

        :error ->
          Map.merge(turn, %{edited?: false, deleted?: false})
      end
    end)
  end

  @doc """
  Applies the full corrections (replacements + edits) to raw turns and returns
  a flat list of corrected turn maps for finalization.
  """
  def apply_corrections(raw_turns, corrections) do
    replacements = Map.get(corrections, "replacements", %{})
    edits = Map.get(corrections, "edits", %{})

    {single_map, multi_patterns} =
      if map_size(replacements) > 0 do
        replacements |> build_patterns() |> split_patterns()
      else
        {%{}, []}
      end

    raw_turns
    |> Enum.reject(fn turn -> Map.get(edits, to_string(turn.id)) == "" end)
    |> Enum.map(fn turn ->
      key = to_string(turn.id)

      text =
        case Map.fetch(edits, key) do
          {:ok, edited_text} ->
            edited_text

          :error ->
            if single_map == %{} and multi_patterns == [] do
              Enum.map_join(turn.words, fn w -> w["word"] end)
            else
              {display_words, _counts} =
                apply_and_count_words(turn.words, single_map, multi_patterns)

              Enum.map_join(display_words, fn w -> w.word end)
            end
        end

      %{speaker: turn.speaker, start: turn.start, end: turn.end, text: String.trim(text)}
    end)
  end

  @doc """
  Converts corrected turns into SRT format string.
  """
  def segments_to_srt(turns) do
    turns
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {turn, idx} ->
      "#{idx}\n#{srt_timestamp(turn.start)} --> #{srt_timestamp(turn.end)}\n[#{turn.speaker}] #{turn.text}"
    end)
    |> Kernel.<>("\n")
  end

  defp srt_timestamp(seconds) when is_number(seconds) do
    total_ms = round(seconds * 1000)
    ms = rem(total_ms, 1000)
    total_s = div(total_ms, 1000)
    s = rem(total_s, 60)
    total_m = div(total_s, 60)
    m = rem(total_m, 60)
    h = div(total_m, 60)

    [h, m, s]
    |> Enum.map(&String.pad_leading(Integer.to_string(&1), 2, "0"))
    |> Enum.join(":")
    |> Kernel.<>(",#{String.pad_leading(Integer.to_string(ms), 3, "0")}")
  end

  defp strip_word(word) do
    word
    |> String.trim_leading()
    |> String.replace(~r/[.,;:!?\-"')\]]+\z/, "")
  end

  # Returns {base, possessive_suffix} if the key ends with 's or 's, otherwise :none.
  defp strip_possessive(key) do
    cond do
      String.ends_with?(key, "'s") ->
        {String.slice(key, 0, String.length(key) - 2), "'s"}

      String.ends_with?(key, "\u2019s") ->
        {String.slice(key, 0, String.length(key) - 2), "\u2019s"}

      true ->
        :none
    end
  end

  defp extract_affixes(word) do
    prefix =
      case Regex.run(~r/\A(\s+)/, word) do
        [_, ws] -> ws
        _ -> ""
      end

    suffix =
      case Regex.run(~r/(['\x{2019}]s[.,;:!?\-"')\]]*|[.,;:!?\-"')\]]+)\z/u, word) do
        [_, punct] -> punct
        _ -> ""
      end

    {prefix, suffix}
  end
end
