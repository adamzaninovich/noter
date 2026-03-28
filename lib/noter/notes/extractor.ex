defmodule Noter.Notes.Extractor do
  @moduledoc """
  Extracts structured facts from a single transcript chunk via an LLM call.
  """

  alias Noter.LLM.Client
  alias Noter.Notes.Prompts

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
      "events" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
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
      "info_learned" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
      "combat" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
      "decisions" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
      "character_moments" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
      "loose_threads" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      },
      "inventory_rewards" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        }
      }
    }
  }

  @doc """
  Extracts structured facts from a single chunk via a JSON-schema-constrained LLM call.
  Returns `{:ok, facts_map}` or `{:error, reason}`.
  `opts` are passed through to `Client.chat_json/4` for test plug injection.
  """
  def extract(chunk, context, opts \\ []) do
    chunk_range = "#{chunk.range_start}–#{chunk.range_end}"
    messages = Prompts.extraction_messages(chunk.text, chunk_range, context)
    Client.chat_json(:extraction, messages, @extraction_schema, opts)
  end
end
