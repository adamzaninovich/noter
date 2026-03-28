defmodule Noter.Notes.ChunkerTest do
  use ExUnit.Case, async: true

  alias Noter.Notes.Chunker

  defp turn(speaker, start_sec, end_sec, text) do
    %{speaker: speaker, start: start_sec, end: end_sec, text: text}
  end

  describe "chunk_turns/1" do
    test "returns empty list for empty input" do
      assert Chunker.chunk_turns([]) == []
    end

    test "single turn in one window" do
      turns = [turn("Alice", 0, 5, "Hello world")]
      [chunk] = Chunker.chunk_turns(turns)

      assert chunk.index == 0
      assert chunk.range_start == "00:00:00"
      assert chunk.text =~ "Alice: Hello world"
    end

    test "all turns fit in one window" do
      turns = [
        turn("Alice", 0, 10, "First"),
        turn("Bob", 30, 40, "Second"),
        turn("Alice", 59, 60, "Third")
      ]

      chunks = Chunker.chunk_turns(turns, 600)
      assert length(chunks) == 1
      [chunk] = chunks
      assert chunk.index == 0
      assert chunk.text =~ "[00:00:00] Alice: First"
      assert chunk.text =~ "[00:00:30] Bob: Second"
      assert chunk.text =~ "[00:00:59] Alice: Third"
    end

    test "splits turns into multiple windows" do
      turns = [
        turn("Alice", 0, 10, "Chunk one"),
        turn("Bob", 700, 710, "Chunk two")
      ]

      chunks = Chunker.chunk_turns(turns, 600)
      assert length(chunks) == 2
      assert Enum.at(chunks, 0).index == 0
      assert Enum.at(chunks, 1).index == 1
      assert Enum.at(chunks, 0).text =~ "Chunk one"
      assert Enum.at(chunks, 1).text =~ "Chunk two"
    end

    test "skips empty windows" do
      turns = [
        turn("Alice", 0, 10, "First"),
        turn("Bob", 1300, 1310, "Third")
      ]

      # Window 600-1200 has no turns, should be skipped
      chunks = Chunker.chunk_turns(turns, 600)
      assert length(chunks) == 2
      assert Enum.at(chunks, 0).index == 0
      assert Enum.at(chunks, 1).index == 1
    end

    test "deduplicates identical lines (same timestamp, speaker, and text)" do
      # Identical formatted lines are deduped — can happen with duplicate segments
      turns = [
        turn("Alice", 0, 5, "Hello"),
        turn("Alice", 0, 3, "Hello")
      ]

      [chunk] = Chunker.chunk_turns(turns)
      lines = String.split(chunk.text, "\n")
      assert length(lines) == 1
    end

    test "does not dedup lines with same text but different timestamps" do
      turns = [
        turn("Alice", 0, 5, "Hello"),
        turn("Alice", 10, 15, "Hello")
      ]

      [chunk] = Chunker.chunk_turns(turns)
      lines = String.split(chunk.text, "\n")
      assert length(lines) == 2
    end

    test "formats timestamp correctly" do
      turns = [turn("GM", 3661, 3665, "Test")]
      [chunk] = Chunker.chunk_turns(turns)
      assert chunk.text =~ "[01:01:01] GM: Test"
    end

    test "range_start and range_end are HH:MM:SS strings" do
      turns = [turn("Alice", 0, 5, "Hello")]
      [chunk] = Chunker.chunk_turns(turns)
      assert chunk.range_start =~ ~r/^\d{2}:\d{2}:\d{2}$/
      assert chunk.range_end =~ ~r/^\d{2}:\d{2}:\d{2}$/
    end

    test "range_end caps at last turn end" do
      turns = [turn("Alice", 0, 300, "Hello")]
      [chunk] = Chunker.chunk_turns(turns, 600)
      # last_end is 300, range_end should be 00:05:00 not 00:10:00
      assert chunk.range_end == "00:05:00"
    end

    test "custom window size" do
      turns = [
        turn("Alice", 0, 5, "A"),
        turn("Bob", 120, 125, "B"),
        turn("Alice", 250, 255, "C")
      ]

      chunks = Chunker.chunk_turns(turns, 60)
      assert length(chunks) == 3
    end

    test "indices are sequential and 0-based after skipped windows" do
      turns = [
        turn("Alice", 0, 5, "A"),
        turn("Bob", 1300, 1305, "B")
      ]

      chunks = Chunker.chunk_turns(turns, 600)
      indices = Enum.map(chunks, & &1.index)
      assert indices == [0, 1]
    end
  end
end
