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
        range = {chunk.range_start_sec, chunk.range_start, chunk.range_end}

        Enum.reduce(@all_categories, acc, fn key, inner_acc ->
          entries =
            facts
            |> Map.get(key, [])
            |> Enum.map(fn entry -> {range, entry} end)

          Map.update!(inner_acc, key, &(entries ++ &1))
        end)
      end)

    # Sort chronologically
    sorted =
      Map.new(collected, fn {k, v} ->
        {k, Enum.sort_by(v, fn {{start_sec, _, _}, _} -> start_sec end)}
      end)

    # Deduplicate
    sorted
    |> dedupe_text_categories()
    |> dedupe_named_categories()
    |> cross_category_dedupe("decisions", "events")
    |> cross_category_dedupe("combat", "events")
  end

  defp dedupe_text_categories(facts) do
    Enum.reduce(@text_categories, facts, fn key, acc ->
      Map.update!(acc, key, fn items ->
        items
        |> dedupe_by_text()
        |> Enum.map(fn {_range, entry} -> entry end)
      end)
    end)
  end

  defp dedupe_by_text(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn {_range, entry} = tagged, {result, seen} ->
      case Map.get(entry, "text") do
        nil ->
          {result, seen}

        text ->
          key = normalize(text)

          if MapSet.member?(seen, key) do
            {result, seen}
          else
            {[tagged | result], MapSet.put(seen, key)}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp dedupe_named_categories(facts) do
    Enum.reduce(@named_categories, facts, fn key, acc ->
      Map.update!(acc, key, &merge_named/1)
    end)
  end

  defp merge_named(items) do
    items
    |> Enum.reduce(%{}, fn {_range, entry}, acc ->
      case Map.get(entry, "name") do
        nil ->
          acc

        name ->
          key = normalize(name)
          note = entry |> Map.get("notes", "") |> String.trim()
          empty = {String.trim(name), [], MapSet.new()}

          Map.update(acc, key, add_note(empty, note), &add_note(&1, note))
      end
    end)
    |> Map.values()
    |> Enum.map(fn {name, notes, _seen} ->
      %{"name" => name, "notes" => notes |> Enum.reverse() |> Enum.join("; ")}
    end)
  end

  defp add_note(entry, ""), do: entry

  defp add_note({name, notes, seen}, note) do
    key = normalize(note)

    if MapSet.member?(seen, key) do
      {name, notes, seen}
    else
      {name, [note | notes], MapSet.put(seen, key)}
    end
  end

  defp cross_category_dedupe(facts, primary_key, secondary_key) do
    secondary_set =
      facts
      |> Map.get(secondary_key, [])
      |> Enum.flat_map(fn entry ->
        case Map.get(entry, "text") do
          nil -> []
          text -> [normalize(text)]
        end
      end)
      |> MapSet.new()

    Map.update!(facts, primary_key, fn items ->
      Enum.reject(items, fn entry ->
        case Map.get(entry, "text") do
          nil -> false
          text -> MapSet.member?(secondary_set, normalize(text))
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
