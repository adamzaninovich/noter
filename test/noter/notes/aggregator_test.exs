defmodule Noter.Notes.AggregatorTest do
  use ExUnit.Case, async: true

  alias Noter.Notes.Aggregator

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        "events" => [],
        "locations" => [],
        "npcs" => [],
        "info_learned" => [],
        "combat" => [],
        "decisions" => [],
        "character_moments" => [],
        "loose_threads" => [],
        "inventory_rewards" => []
      },
      overrides
    )
  end

  describe "aggregate/1" do
    test "returns empty arrays for all categories when input is empty" do
      result = Aggregator.aggregate([])

      for key <-
            ~w(events locations npcs info_learned combat decisions character_moments loose_threads inventory_rewards) do
        assert result[key] == [], "expected #{key} to be empty"
      end
    end

    test "preserves text entries from a single chunk" do
      input = [{0, facts(%{"events" => [%{"text" => "The party arrived"}]})}]
      result = Aggregator.aggregate(input)
      assert result["events"] == [%{"text" => "The party arrived"}]
    end

    test "deduplicates identical text entries across chunks" do
      entry = %{"text" => "The party arrived"}

      input = [
        {0, facts(%{"events" => [entry]})},
        {1, facts(%{"events" => [entry]})}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["events"]) == 1
    end

    test "deduplicates by normalized text (case and punctuation insensitive)" do
      input = [
        {0, facts(%{"events" => [%{"text" => "The party arrived!"}]})},
        {1, facts(%{"events" => [%{"text" => "the party arrived"}]})}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["events"]) == 1
    end

    test "preserves first occurrence casing in text dedup" do
      input = [
        {0, facts(%{"events" => [%{"text" => "The Party Arrived"}]})},
        {1, facts(%{"events" => [%{"text" => "the party arrived"}]})}
      ]

      result = Aggregator.aggregate(input)
      assert result["events"] == [%{"text" => "The Party Arrived"}]
    end

    test "merges named entities by normalized name" do
      input = [
        {0, facts(%{"npcs" => [%{"name" => "Bob", "notes" => "A fighter"}]})},
        {1, facts(%{"npcs" => [%{"name" => "bob", "notes" => "Wears armor"}]})}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["npcs"]) == 1
      [npc] = result["npcs"]
      assert npc["name"] == "Bob"
      assert npc["notes"] =~ "A fighter"
      assert npc["notes"] =~ "Wears armor"
    end

    test "keeps first name casing for named entities" do
      input = [
        {0, facts(%{"locations" => [%{"name" => "The Tavern", "notes" => "Big place"}]})},
        {1, facts(%{"locations" => [%{"name" => "the tavern", "notes" => "Noisy"}]})}
      ]

      result = Aggregator.aggregate(input)
      [loc] = result["locations"]
      assert loc["name"] == "The Tavern"
    end

    test "deduplicates notes within named entities" do
      input = [
        {0, facts(%{"npcs" => [%{"name" => "Alice", "notes" => "Friendly"}]})},
        {1, facts(%{"npcs" => [%{"name" => "Alice", "notes" => "friendly"}]})}
      ]

      result = Aggregator.aggregate(input)
      [npc] = result["npcs"]
      refute npc["notes"] =~ ";"
    end

    test "cross-category dedup: removes decisions that match events" do
      shared = "The party decided to explore the dungeon"

      input = [
        {0,
         facts(%{
           "events" => [%{"text" => shared}],
           "decisions" => [%{"text" => shared}]
         })}
      ]

      result = Aggregator.aggregate(input)
      assert result["decisions"] == []
      assert length(result["events"]) == 1
    end

    test "cross-category dedup: removes combat that matches events" do
      shared = "The party fought a dragon"

      input = [
        {0,
         facts(%{
           "events" => [%{"text" => shared}],
           "combat" => [%{"text" => shared}]
         })}
      ]

      result = Aggregator.aggregate(input)
      assert result["combat"] == []
    end

    test "preserves decisions not in events" do
      input = [
        {0,
         facts(%{
           "events" => [%{"text" => "Something happened"}],
           "decisions" => [%{"text" => "Decided to camp for the night"}]
         })}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["decisions"]) == 1
    end

    test "deduplicates all text categories" do
      for key <-
            ~w(info_learned combat decisions character_moments loose_threads inventory_rewards) do
        entry = %{"text" => "Test entry"}

        input = [
          {0, facts(%{key => [entry]})},
          {1, facts(%{key => [entry]})}
        ]

        result = Aggregator.aggregate(input)
        assert length(result[key]) == 1, "expected #{key} to be deduped"
      end
    end

    test "preserves order of first occurrence across chunks" do
      input = [
        {0, facts(%{"events" => [%{"text" => "First event"}]})},
        {1, facts(%{"events" => [%{"text" => "Second event"}]})}
      ]

      result = Aggregator.aggregate(input)
      assert Enum.at(result["events"], 0)["text"] == "First event"
      assert Enum.at(result["events"], 1)["text"] == "Second event"
    end

    test "handles empty arrays in facts gracefully" do
      input = [{0, facts()}]
      result = Aggregator.aggregate(input)

      for key <-
            ~w(events locations npcs info_learned combat decisions character_moments loose_threads inventory_rewards) do
        assert result[key] == []
      end
    end

    test "aggregates and deduplicates banter entries across chunks" do
      entry = %{"text" => "Did you see the game last night?"}

      input = [
        {0, facts(%{"banter" => [entry, %{"text" => "Classic!"}]})},
        {1, facts(%{"banter" => [entry]})}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["banter"]) == 2
      assert Enum.any?(result["banter"], &(&1["text"] == "Did you see the game last night?"))
      assert Enum.any?(result["banter"], &(&1["text"] == "Classic!"))
    end

    test "banter dedup is case and punctuation insensitive" do
      input = [
        {0, facts(%{"banter" => [%{"text" => "Ha, classic!"}]})},
        {1, facts(%{"banter" => [%{"text" => "ha classic"}]})}
      ]

      result = Aggregator.aggregate(input)
      assert length(result["banter"]) == 1
    end
  end
end
