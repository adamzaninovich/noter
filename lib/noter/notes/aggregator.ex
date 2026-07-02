defmodule Noter.Notes.Aggregator do
  @moduledoc """
  Merges and deduplicates extracted facts from multiple transcript chunks.
  Pure functions — no external dependencies.
  Ported from the n8n "Aggregate Facts" JavaScript node.
  """

  @text_keys ~w(events info_learned combat decisions character_moments loose_threads inventory_rewards banter)
  @entity_keys ~w(npcs locations)

  @doc """
  Aggregates a list of `{chunk_index, facts_map}` tuples into a single deduplicated facts map.

  - Text categories: dedup by normalized text, preserve first occurrence casing
  - Named entities: merge by normalized name, combine and dedup notes, keep first name casing
  - Cross-category dedup: remove from decisions/combat anything already in events
  """
  def aggregate(chunk_facts) do
    empty = Map.new(@text_keys ++ @entity_keys, fn k -> {k, []} end)

    collected =
      Enum.reduce(chunk_facts, empty, fn {_idx, facts}, acc ->
        Enum.reduce(@text_keys ++ @entity_keys, acc, fn key, inner ->
          items = Map.get(facts, key, [])

          if is_list(items) do
            Map.update!(inner, key, &(&1 ++ items))
          else
            inner
          end
        end)
      end)

    deduped =
      Enum.reduce(@text_keys, collected, fn key, acc ->
        Map.put(acc, key, dedup_text_array(Map.get(acc, key)))
      end)

    merged =
      Enum.reduce(@entity_keys, deduped, fn key, acc ->
        Map.put(acc, key, merge_named_objects(Map.get(acc, key)))
      end)

    events_set = MapSet.new(merged["events"], fn e -> normalize(e["text"]) end)

    merged
    |> Map.put("decisions", cross_dedup(merged["decisions"], events_set))
    |> Map.put("combat", cross_dedup(merged["combat"], events_set))
  end

  defp normalize(str) do
    str
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[.,!?;:]/, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp dedup_text_array(items) do
    {result_rev, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn entry, {acc, seen} ->
        text = entry["text"]

        if is_nil(text) do
          {acc, seen}
        else
          key = normalize(text)

          if MapSet.member?(seen, key) do
            {acc, seen}
          else
            {[%{"text" => String.trim(text)} | acc], MapSet.put(seen, key)}
          end
        end
      end)

    Enum.reverse(result_rev)
  end

  defp merge_named_objects(items) do
    {order_rev, map} =
      Enum.reduce(items, {[], %{}}, fn entry, {order, map} ->
        name = entry["name"]

        if is_nil(name) or name == "" do
          {order, map}
        else
          key = normalize(name)
          note_text = if entry["notes"], do: String.trim(entry["notes"]), else: ""

          if Map.has_key?(map, key) do
            existing = map[key]

            notes =
              if note_text != "" and
                   not Enum.any?(existing.notes, &(normalize(&1) == normalize(note_text))) do
                existing.notes ++ [note_text]
              else
                existing.notes
              end

            {order, Map.put(map, key, %{existing | notes: notes})}
          else
            notes = if note_text != "", do: [note_text], else: []
            {[key | order], Map.put(map, key, %{name: String.trim(name), notes: notes})}
          end
        end
      end)

    order_rev
    |> Enum.reverse()
    |> Enum.map(fn key ->
      entry = map[key]
      %{"name" => entry.name, "notes" => Enum.join(entry.notes, "; ")}
    end)
  end

  defp cross_dedup(items, excluded_set) do
    Enum.filter(items, fn e ->
      text = e["text"]
      not is_nil(text) and not MapSet.member?(excluded_set, normalize(text))
    end)
  end
end
