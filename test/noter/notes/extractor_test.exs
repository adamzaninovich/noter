defmodule Noter.Notes.ExtractorTest do
  use Noter.DataCase, async: false

  @moduletag capture_log: true

  alias Noter.Notes.Extractor
  alias Noter.Settings

  @chunk %{
    index: 0,
    range_start: "00:00:00",
    range_end: "00:10:00",
    text: "[00:00:01] Alice: The party entered the dungeon."
  }

  @context "Campaign context here"

  @valid_facts %{
    "range" => "00:00:00–00:10:00",
    "events" => [%{"text" => "The party entered the dungeon"}],
    "locations" => [%{"name" => "Dungeon", "notes" => "Dark and foreboding"}],
    "npcs" => [],
    "info_learned" => [],
    "combat" => [],
    "decisions" => [],
    "character_moments" => [],
    "loose_threads" => [],
    "inventory_rewards" => []
  }

  defp setup_settings do
    Settings.set("llm_extraction_base_url", "http://localhost:1234/v1")
    Settings.set("llm_extraction_model", "test-model")
    Settings.set("llm_extraction_api_key", nil)
  end

  defp chat_response(content) do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ]
    }
  end

  describe "extract/3" do
    test "returns parsed facts on successful response" do
      setup_settings()

      plug = fn conn ->
        Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
      end

      assert {:ok, facts} = Extractor.extract(@chunk, @context, plug: plug)
      assert facts["events"] == [%{"text" => "The party entered the dungeon"}]
      assert facts["locations"] == [%{"name" => "Dungeon", "notes" => "Dark and foreboding"}]
    end

    test "sends json_schema in Chat Completions format" do
      setup_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["response_format"]["type"] == "json_schema"
        schema = decoded["response_format"]["json_schema"]["schema"]
        assert "events" in schema["required"]
        assert "npcs" in schema["required"]
        Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
      end

      assert {:ok, _} = Extractor.extract(@chunk, @context, plug: plug)
    end

    test "includes chunk range in the messages" do
      setup_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))["content"]
        assert user_msg =~ "00:00:00"
        assert user_msg =~ "00:10:00"
        Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
      end

      assert {:ok, _} = Extractor.extract(@chunk, @context, plug: plug)
    end

    test "returns error on API failure" do
      setup_settings()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "Internal server error"})
      end

      assert {:error, msg} = Extractor.extract(@chunk, @context, plug: plug)
      assert msg =~ "API error 500"
    end

    test "returns error when llm settings not configured" do
      assert {:error, msg} = Extractor.extract(@chunk, @context)
      assert msg =~ "not configured"
    end
  end
end
