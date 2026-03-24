defmodule Noter.Transcription.TranscriptTest do
  use ExUnit.Case, async: true

  alias Noter.Transcription.Transcript

  defp make_words(texts) do
    texts
    |> Enum.with_index()
    |> Enum.map(fn {text, i} ->
      %{"word" => text, "start" => i * 0.5, "end" => (i + 1) * 0.5}
    end)
  end

  defp make_turns(word_texts) do
    [
      %{
        id: 0,
        speaker: "DM",
        start: 0.0,
        end: length(word_texts) * 0.5,
        words: make_words(word_texts)
      }
    ]
  end

  defp display_texts(turns) do
    turns
    |> hd()
    |> Map.get(:display_words)
    |> Enum.map(& &1.word)
    |> Enum.reject(&(&1 == ""))
  end

  describe "apply_replacements/2 possessives" do
    test "replaces possessive form with straight apostrophe" do
      turns = make_turns([" Tazo's", " sword"])
      {result, counts} = Transcript.apply_replacements(turns, %{"tazo" => "Taszo"})

      assert display_texts(result) == [" Taszo's", " sword"]
      assert counts == %{"tazo" => 1}
    end

    test "replaces possessive form with curly apostrophe" do
      turns = make_turns([" Tazo\u2019s", " sword"])
      {result, counts} = Transcript.apply_replacements(turns, %{"tazo" => "Taszo"})

      assert display_texts(result) == [" Taszo\u2019s", " sword"]
      assert counts == %{"tazo" => 1}
    end

    test "replaces both plain and possessive in same transcript" do
      turns = make_turns([" Tazo", " and", " Tazo's", " cat"])
      {result, counts} = Transcript.apply_replacements(turns, %{"tazo" => "Taszo"})

      assert display_texts(result) == [" Taszo", " and", " Taszo's", " cat"]
      assert counts == %{"tazo" => 2}
    end

    test "preserves trailing punctuation after possessive" do
      turns = make_turns([" Tazo's,", " yeah"])
      {result, _} = Transcript.apply_replacements(turns, %{"tazo" => "Taszo"})

      assert display_texts(result) == [" Taszo's,", " yeah"]
    end

    test "does not false-positive on words ending in s" do
      turns = make_turns([" dogs", " cats"])
      {result, counts} = Transcript.apply_replacements(turns, %{"dog" => "hound"})

      assert display_texts(result) == [" dogs", " cats"]
      assert counts == %{}
    end

    test "multi-word possessive replacement" do
      turns = make_turns([" big", " Tazo's", " stuff"])
      {result, counts} = Transcript.apply_replacements(turns, %{"big tazo" => "Big Taszo"})

      assert display_texts(result) == [" Big Taszo's", " stuff"]
      assert counts == %{"big tazo" => 1}
    end

    test "multi-word exact match still works" do
      turns = make_turns([" big", " Tazo", " stuff"])
      {result, counts} = Transcript.apply_replacements(turns, %{"big tazo" => "Big Taszo"})

      assert display_texts(result) == [" Big Taszo", " stuff"]
      assert counts == %{"big tazo" => 1}
    end
  end

  describe "apply_replacements/2 case insensitivity" do
    test "matches regardless of case" do
      turns = make_turns([" TAZO", " tazo", " Tazo"])
      {result, counts} = Transcript.apply_replacements(turns, %{"tazo" => "Taszo"})

      assert display_texts(result) == [" Taszo", " Taszo", " Taszo"]
      assert counts == %{"tazo" => 3}
    end
  end

  describe "compile_patterns/1 + apply_replacements/3" do
    test "pre-compiled patterns produce identical results to apply_replacements/2" do
      replacements = %{"hello" => "goodbye", "big tazo" => "Big Taszo"}
      compiled = Transcript.compile_patterns(replacements)

      turns1 = make_turns([" hello", " world"])
      turns2 = make_turns([" big", " tazo", " hello"])

      assert Transcript.apply_replacements(turns1, replacements) ==
               Transcript.apply_replacements(turns1, replacements, compiled)

      assert Transcript.apply_replacements(turns2, replacements) ==
               Transcript.apply_replacements(turns2, replacements, compiled)
    end

    test "empty replacements compile to empty patterns" do
      assert {%{}, []} = Transcript.compile_patterns(%{})
    end
  end

  describe "apply_replacements/2 basic" do
    test "no replacements returns words unchanged" do
      turns = make_turns([" hello", " world"])
      {result, counts} = Transcript.apply_replacements(turns, %{})

      assert display_texts(result) == [" hello", " world"]
      assert counts == %{}
    end

    test "single word replacement" do
      turns = make_turns([" hello", " world"])
      {result, counts} = Transcript.apply_replacements(turns, %{"hello" => "goodbye"})

      assert display_texts(result) == [" goodbye", " world"]
      assert counts == %{"hello" => 1}
    end
  end
end
