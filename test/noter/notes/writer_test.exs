defmodule Noter.Notes.WriterTest do
  use Noter.DataCase, async: false

  alias Noter.Notes.Writer
  alias Noter.Settings

  @aggregated_facts %{
    "events" => [%{"text" => "The party explored the dungeon"}],
    "locations" => [%{"name" => "Dungeon", "notes" => "Dark"}],
    "npcs" => [],
    "info_learned" => [],
    "combat" => [],
    "decisions" => [],
    "character_moments" => [],
    "loose_threads" => [],
    "inventory_rewards" => []
  }

  @context "Campaign context"

  defp setup_settings do
    Settings.set("llm_writing_base_url", "http://localhost:1234/v1")
    Settings.set("llm_writing_model", "test-model")
    Settings.set("llm_writing_api_key", nil)
  end

  defp chat_response(content) do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ]
    }
  end

  describe "write/3" do
    test "returns markdown string on successful response" do
      setup_settings()
      expected = "# Session Notes\n\n## Summary\nThe party explored."

      plug = fn conn ->
        Req.Test.json(conn, chat_response(expected))
      end

      assert {:ok, markdown} = Writer.write(@aggregated_facts, @context, plug: plug)
      assert markdown == expected
    end

    test "includes facts in the request" do
      setup_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        user_content = Enum.find(decoded["messages"], &(&1["role"] == "user"))["content"]
        assert user_content =~ "The party explored the dungeon"
        Req.Test.json(conn, chat_response("# Notes"))
      end

      assert {:ok, _} = Writer.write(@aggregated_facts, @context, plug: plug)
    end

    test "includes context in the request" do
      setup_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        user_content = Enum.find(decoded["messages"], &(&1["role"] == "user"))["content"]
        assert user_content =~ "Campaign context"
        Req.Test.json(conn, chat_response("# Notes"))
      end

      assert {:ok, _} = Writer.write(@aggregated_facts, @context, plug: plug)
    end

    test "does not include response_format (plain chat)" do
      setup_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "response_format")
        Req.Test.json(conn, chat_response("# Notes"))
      end

      assert {:ok, _} = Writer.write(@aggregated_facts, @context, plug: plug)
    end

    test "returns error on API failure" do
      setup_settings()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server error"})
      end

      assert {:error, msg} = Writer.write(@aggregated_facts, @context, plug: plug)
      assert msg =~ "API error 500"
    end

    test "returns error when writing settings not configured" do
      assert {:error, msg} = Writer.write(@aggregated_facts, @context)
      assert msg =~ "not configured"
    end
  end
end
