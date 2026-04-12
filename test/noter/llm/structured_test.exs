defmodule Noter.LLM.StructuredTest do
  use Noter.DataCase, async: false

  @moduletag capture_log: true

  alias Noter.LLM.Structured
  alias Noter.Settings

  @messages [%{"role" => "user", "content" => "Give me data"}]
  @schema %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "string"}},
    "required" => ["value"]
  }

  defp chat_response(content) do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ]
    }
  end

  defp plug_for(fun), do: fun

  defp setup_settings do
    Settings.set("llm_extraction_base_url", "http://localhost:1234/v1")
    Settings.set("llm_extraction_model", "test-model")
  end

  describe "call/4" do
    test "returns parsed JSON on first successful attempt" do
      setup_settings()

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, chat_response(Jason.encode!(%{"value" => "hello"})))
        end)

      assert {:ok, %{"value" => "hello"}} =
               Structured.call(:extraction, @messages, @schema, plug: plug)
    end

    test "retries on malformed JSON and succeeds" do
      setup_settings()
      call_count = :counters.new(1, [:atomics])

      plug =
        plug_for(fn conn ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          content =
            if count <= 1,
              do: "not json {{{",
              else: Jason.encode!(%{"value" => "retried"})

          Req.Test.json(conn, chat_response(content))
        end)

      assert {:ok, %{"value" => "retried"}} =
               Structured.call(:extraction, @messages, @schema, plug: plug)
    end

    test "fails after max retries with malformed JSON" do
      setup_settings()

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, chat_response("not valid json ever"))
        end)

      assert {:error, msg} = Structured.call(:extraction, @messages, @schema, plug: plug)
      assert msg =~ "Failed to parse JSON"
    end

    test "returns error immediately on API failure" do
      setup_settings()

      plug =
        plug_for(fn conn ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{"error" => "server error"})
        end)

      assert {:error, msg} = Structured.call(:extraction, @messages, @schema, plug: plug)
      assert msg =~ "API error 500"
    end

    test "appends schema instruction to existing system message" do
      setup_settings()

      messages = [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "data please"}
      ]

      plug =
        plug_for(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          system_msg = Enum.find(decoded["messages"], &(&1["role"] == "system"))
          assert system_msg["content"] =~ "You are helpful."
          assert system_msg["content"] =~ "valid JSON"
          Req.Test.json(conn, chat_response(Jason.encode!(%{"value" => "ok"})))
        end)

      assert {:ok, _} = Structured.call(:extraction, messages, @schema, plug: plug)
    end
  end
end
