defmodule Noter.Aggregator do
  @moduledoc """
  Merges and deduplicates extracted facts across all chunks.
  Ported from the n8n Aggregate Facts node.
  """

  @text_categories ~w(events info_learned combat decisions character_moments loose_threads inventory_rewards)
  @named_categories ~w(npcs locations)
  @all_categories @text_categories ++ @named_categories

  @doc """
  Aggregates a list of per-chunk extraction results into a single facts map.

  Each item in `extractions` is `{chunk_meta, facts_map}` where `chunk_meta`
  has `:range_start_sec`, `:range_start`, `:range_end`.
  """
  def aggregate(extractions) do
    empty = Map.new(@all_categories, &{&1, []})

    collected =
      Enum.reduce(extractions, empty, fn {chunk, facts}, acc ->
        Enum.reduce(@all_categories, acc, fn key, inner_acc ->
          entries =
            facts
            |> Map.get(key, [])
            |> Enum.map(fn entry ->
              Map.merge(entry, %{
                "_range_start_sec" => chunk.range_start_sec,
                "_range_start" => chunk.range_start,
                "_range_end" => chunk.range_end
              })
            end)

          Map.update!(inner_acc, key, &(&1 ++ entries))
        end)
      end)

    # Sort chronologically
    sorted = Map.new(collected, fn {k, v} -> {k, sort_by_range(v)} end)

    # Deduplicate
    result =
      sorted
      |> dedupe_text_categories()
      |> dedupe_named_categories()
      |> cross_category_dedupe("decisions", "events")
      |> cross_category_dedupe("combat", "events")

    # Strip internal range tracking keys from output
    Map.new(result, fn {k, v} ->
      {k, Enum.map(v, &Map.drop(&1, ["_range_start_sec", "_range_start", "_range_end"]))}
    end)
  end

  defp sort_by_range(items) do
    Enum.sort_by(items, &Map.get(&1, "_range_start_sec", 0))
  end

  defp dedupe_text_categories(facts) do
    Enum.reduce(@text_categories, facts, fn key, acc ->
      Map.update!(acc, key, &dedupe_by_text/1)
    end)
  end

  defp dedupe_by_text(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn entry, {result, seen} ->
      case Map.get(entry, "text") do
        nil ->
          {result, seen}

        text ->
          key = normalize(text)

          if MapSet.member?(seen, key) do
            {result, seen}
          else
            {result ++ [entry], MapSet.put(seen, key)}
          end
      end
    end)
    |> elem(0)
  end

  defp dedupe_named_categories(facts) do
    Enum.reduce(@named_categories, facts, fn key, acc ->
      Map.update!(acc, key, &merge_named/1)
    end)
  end

  defp merge_named(items) do
    items
    |> Enum.reduce(%{}, fn entry, acc ->
      case Map.get(entry, "name") do
        nil ->
          acc

        name ->
          key = normalize(name)
          note = entry |> Map.get("notes", "") |> String.trim()

          Map.update(acc, key, %{"name" => String.trim(name), "notes" => [note]}, fn existing ->
            existing_notes = Map.get(existing, "notes", [])

            updated_notes =
              if note != "" and normalize(note) not in Enum.map(existing_notes, &normalize/1) do
                existing_notes ++ [note]
              else
                existing_notes
              end

            Map.put(existing, "notes", updated_notes)
          end)
      end
    end)
    |> Map.values()
    |> Enum.map(fn entry ->
      Map.update!(entry, "notes", &Enum.join(&1, "; "))
    end)
  end

  defp cross_category_dedupe(facts, primary_key, secondary_key) do
    secondary_set =
      facts
      |> Map.get(secondary_key, [])
      |> Enum.flat_map(fn e ->
        case Map.get(e, "text") do
          nil -> []
          t -> [normalize(t)]
        end
      end)
      |> MapSet.new()

    Map.update!(facts, primary_key, fn items ->
      Enum.reject(items, fn e ->
        case Map.get(e, "text") do
          nil -> false
          t -> MapSet.member?(secondary_set, normalize(t))
        end
      end)
    end)
  end

  defp normalize(str) do
    str
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[.,!?;:]/, "")
    |> String.replace(~r/\s+/, " ")
  end
end
