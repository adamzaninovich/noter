defmodule Noter.Extractor do
  @moduledoc """
  Extracts structured facts from a single transcript chunk via the LLM.
  Results are cached in SQLite by chunk content hash to avoid re-spending API calls.
  """

  import Ecto.Query
  alias Noter.{ChunkExtraction, LLM, Repo}

  @text_array_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["text"],
      "properties" => %{"text" => %{"type" => "string"}}
    }
  }

  @extraction_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "range",
      "events",
      "locations",
      "npcs",
      "info_learned",
      "combat",
      "decisions",
      "character_moments",
      "loose_threads",
      "inventory_rewards"
    ],
    "properties" => %{
      "range" => %{"type" => "string"},
      "events" => @text_array_schema,
      "locations" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["name", "notes"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "notes" => %{"type" => "string"}
          }
        }
      },
      "npcs" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["name", "notes"],
          "properties" => %{
            "name" => %{"type" => "string"},
            "notes" => %{"type" => "string"}
          }
        }
      },
      "info_learned" => @text_array_schema,
      "combat" => @text_array_schema,
      "decisions" => @text_array_schema,
      "character_moments" => @text_array_schema,
      "loose_threads" => @text_array_schema,
      "inventory_rewards" => @text_array_schema
    }
  }

  @doc """
  Extracts facts from a chunk, using the SQLite cache when available.

  `session_path` is the path to the session directory (basename used as cache key).
  `context` is the campaign context string (may be empty).
  `chunk` is a map from `Noter.Chunker.chunk/4`.
  """
  def extract(session_path, context, chunk, opts \\ []) do
    hash = chunk_hash(chunk.chunk_text)
    session_key = Path.basename(session_path)

    case get_cached(session_key, chunk.chunk_index, hash) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        case call_llm(context, chunk, opts) do
          {:ok, result} ->
            cache_result(session_key, chunk.chunk_index, hash, result)
            {:ok, result}

          {:error, _} = err ->
            err
        end
    end
  end

  defp get_cached(session_key, chunk_index, hash) do
    query =
      from e in ChunkExtraction,
        where:
          e.session_path == ^session_key and
            e.chunk_index == ^chunk_index and
            e.chunk_hash == ^hash,
        select: e.result

    case Repo.one(query) do
      nil -> :miss
      json -> {:ok, Jason.decode!(json)}
    end
  end

  defp cache_result(session_key, chunk_index, hash, result) do
    case %ChunkExtraction{}
         |> ChunkExtraction.changeset(%{
           session_path: session_key,
           chunk_index: chunk_index,
           chunk_hash: hash,
           result: Jason.encode!(result)
         })
         |> Repo.insert(on_conflict: :nothing) do
      {:ok, _} -> :ok
      {:error, changeset} -> IO.puts("Warning: failed to cache chunk #{chunk_index}: #{inspect(changeset.errors)}")
    end
  end

  defp call_llm(context, chunk, opts) do
    system_msg = """
    You extract structured, transcript-grounded facts from a TTRPG session chunk. \
    You do not write prose notes. You do not invent events. Return valid JSON only.
    """

    user_msg = """
    Context (authoritative, may be empty):
    #{context}

    Transcript chunk (authoritative):
    Range: #{chunk.range_start}–#{chunk.range_end}
    #{chunk.chunk_text}

    Task:
    Extract structured facts that are explicitly supported by the transcript chunk.

    Strict rules:
    - Only include facts supported by the chunk text.
    - Do not invent events, outcomes, NPC identities, motives, or locations.
    - Exclude table talk, hypotheticals, jokes, rules discussion, and planning unless it clearly results in an in-fiction action or a party decision that happens in this chunk.
    - If uncertain, omit rather than guess.
    - Do not include quotes or timestamps in the output.
    - Use arrays, even if empty.
    - Keep each entry short and specific.

    If nothing factual occurred in this chunk, return empty arrays for everything.
    Set "range" to "#{chunk.range_start}–#{chunk.range_end}".
    """

    messages = [
      %{"role" => "system", "content" => system_msg},
      %{"role" => "user", "content" => user_msg}
    ]

    response_format = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "chunk_extraction",
        "strict" => true,
        "schema" => @extraction_schema
      }
    }

    with {:ok, content} <-
           LLM.chat(messages, Keyword.put(opts, :response_format, response_format)) do
      case Jason.decode(content) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, _} -> {:error, "LLM returned invalid JSON: #{String.slice(content, 0, 200)}"}
      end
    end
  end

  defp chunk_hash(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end
end
