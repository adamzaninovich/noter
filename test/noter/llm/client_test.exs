defmodule Noter.LLM.ClientTest do
  use Noter.DataCase, async: false

  @moduletag capture_log: true

  alias Noter.LLM.Client
  alias Noter.Settings

  @messages [%{"role" => "user", "content" => "Hello"}]

  defp chat_response(content) do
    %{
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => content}}
      ]
    }
  end

  defp setup_settings(role) do
    prefix = "llm_#{role}"
    Settings.set("#{prefix}_base_url", "http://localhost:1234/v1")
    Settings.set("#{prefix}_model", "test-model")
    Settings.set("#{prefix}_api_key", "test-key")
  end

  defp plug_for(fun), do: fun

  describe "chat/3" do
    test "returns content on successful response" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, chat_response("Hello back!"))
        end)

      assert {:ok, "Hello back!"} = Client.chat(:extraction, @messages, plug: plug)
    end

    test "returns error on API error status" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          conn
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => "rate limited"})
        end)

      assert {:error, msg} = Client.chat(:extraction, @messages, plug: plug)
      assert msg =~ "API error 429"
    end

    test "returns error on network failure" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.transport_error(conn, :econnrefused)
        end)

      assert {:error, msg} = Client.chat(:extraction, @messages, plug: plug)
      assert msg =~ "Request failed"
    end

    test "returns error when base_url is not configured" do
      assert {:error, msg} = Client.chat(:extraction, @messages)
      assert msg =~ "not configured"
    end

    test "includes temperature only when set" do
      setup_settings(:extraction)
      Settings.set("llm_extraction_temperature", 0.7)

      plug =
        plug_for(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["temperature"] == 0.7
          Req.Test.json(conn, chat_response("ok"))
        end)

      assert {:ok, _} = Client.chat(:extraction, @messages, plug: plug)
    end

    test "omits temperature when nil" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          refute Map.has_key?(decoded, "temperature")
          Req.Test.json(conn, chat_response("ok"))
        end)

      assert {:ok, _} = Client.chat(:extraction, @messages, plug: plug)
    end

    test "sends authorization header when api_key is set" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          auth = Plug.Conn.get_req_header(conn, "authorization")
          assert auth == ["Bearer test-key"]
          Req.Test.json(conn, chat_response("ok"))
        end)

      assert {:ok, _} = Client.chat(:extraction, @messages, plug: plug)
    end
  end

  describe "chat_json/4" do
    @schema %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    }

    test "returns parsed JSON on valid response" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, chat_response(Jason.encode!(%{"name" => "test"})))
        end)

      assert {:ok, %{"name" => "test"}} =
               Client.chat_json(:extraction, @messages, @schema, plug: plug)
    end

    test "falls back to structured on invalid JSON response" do
      setup_settings(:extraction)

      call_count = :counters.new(1, [])

      plug =
        plug_for(fn conn ->
          :counters.add(call_count, 1, 1)
          count = :counters.get(call_count, 1)

          if count == 1 do
            Req.Test.json(conn, chat_response("not valid json {{{"))
          else
            # Structured fallback uses chat completions
            Req.Test.json(conn, chat_response(Jason.encode!(%{"name" => "fallback"})))
          end
        end)

      assert {:ok, %{"name" => "fallback"}} =
               Client.chat_json(:extraction, @messages, @schema, plug: plug)
    end

    test "uses Chat Completions format with json_schema" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["response_format"]["type"] == "json_schema"
          assert decoded["response_format"]["json_schema"]["strict"] == true
          assert decoded["response_format"]["json_schema"]["schema"] == @schema
          refute Map.has_key?(decoded, "chat_template_kwargs")
          assert is_list(decoded["messages"])
          Req.Test.json(conn, chat_response(Jason.encode!(%{"name" => "ok"})))
        end)

      assert {:ok, _} = Client.chat_json(:extraction, @messages, @schema, plug: plug)
    end

    test "strips markdown fences from response" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, chat_response(~s|```json\n{"name": "fenced"}\n```|))
        end)

      assert {:ok, %{"name" => "fenced"}} =
               Client.chat_json(:extraction, @messages, @schema, plug: plug)
    end

    test "falls back to reasoning_content when content is empty" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, %{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => "",
                  "reasoning_content" => Jason.encode!(%{"name" => "from_reasoning"})
                }
              }
            ]
          })
        end)

      assert {:ok, %{"name" => "from_reasoning"}} =
               Client.chat_json(:extraction, @messages, @schema, plug: plug)
    end
  end

  describe "list_models/2" do
    test "returns sorted model IDs" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          Req.Test.json(conn, %{
            "data" => [
              %{"id" => "model-b"},
              %{"id" => "model-a"},
              %{"id" => "model-c"}
            ]
          })
        end)

      assert {:ok, ["model-a", "model-b", "model-c"]} =
               Client.list_models(:extraction, plug: plug)
    end

    test "returns error on failure" do
      setup_settings(:extraction)

      plug =
        plug_for(fn conn ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{"error" => "internal"})
        end)

      assert {:error, msg} = Client.list_models(:extraction, plug: plug)
      assert msg =~ "API error 500"
    end

    test "returns error when base_url not configured" do
      assert {:error, msg} = Client.list_models(:extraction)
      assert msg =~ "not configured"
    end
  end
end
