defmodule Noter.Notes.PipelineTest do
  use Noter.DataCase, async: false

  @moduletag capture_log: true

  alias Noter.{Campaigns, Jobs, Sessions}
  alias Noter.Notes.Pipeline
  alias Noter.Settings

  @transcript_json Jason.encode!(%{
                     "segments" => [
                       %{
                         "start" => 0,
                         "end" => 5,
                         "speaker" => "Alice",
                         "text" => " Hello world",
                         "words" => [
                           %{"word" => " Hello", "start" => 0, "end" => 2},
                           %{"word" => " world", "start" => 2, "end" => 5}
                         ]
                       }
                     ]
                   })

  @valid_facts %{
    "range" => "00:00:00–00:00:05",
    "events" => [%{"text" => "The party arrived"}],
    "locations" => [],
    "npcs" => [],
    "info_learned" => [],
    "combat" => [],
    "decisions" => [],
    "character_moments" => [],
    "loose_threads" => [],
    "inventory_rewards" => [],
    "banter" => [%{"text" => "Anyone watch the game?"}]
  }

  @notes_markdown "# Session Notes\n\n## Summary\nThe party arrived."

  defp setup_session(attrs \\ %{}) do
    {:ok, campaign} = Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{}})
    {:ok, session} = Sessions.create_session(campaign, %{name: "Test Session"})
    session = Repo.preload(session, :campaign)

    {:ok, session} =
      Sessions.update_transcription(session, %{
        status: "reviewing",
        transcript_json: Map.get(attrs, :transcript_json, @transcript_json),
        transcription_job_id: "job_123"
      })

    {:ok, session} = Sessions.finalize(session)

    if context = Map.get(attrs, :context) do
      {:ok, session} = Sessions.update_session_notes(session, %{context: context})
      session
    else
      session
    end
  end

  defp setup_llm_settings do
    Settings.set("llm_extraction_base_url", "http://localhost:1234/v1")
    Settings.set("llm_extraction_model", "test-model")
    Settings.set("llm_extraction_api_key", nil)
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

  # Extraction has response_format (json_schema), writing does not
  defp dual_plug(extraction_response, writing_response) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      if Map.has_key?(decoded, "response_format") do
        Req.Test.json(conn, chat_response(Jason.encode!(extraction_response)))
      else
        Req.Test.json(conn, chat_response(writing_response))
      end
    end
  end

  describe "run/2" do
    test "full success: session status transitions to done with notes" do
      session = setup_session()
      setup_llm_settings()

      plug = dual_plug(@valid_facts, @notes_markdown)

      assert :ok = Pipeline.run(session.id, plug: plug)

      updated = Sessions.get_session!(session.id)
      assert updated.status == "done"
      assert updated.session_notes == @notes_markdown
    end

    test "session must be in noting status" do
      session = setup_session()
      setup_llm_settings()

      # Verify the session is in noting status after finalize
      assert session.status == "noting"
    end

    test "extraction failure stays on noting" do
      session = setup_session()
      setup_llm_settings()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "LLM unavailable"})
      end

      assert {:error, _} = Pipeline.run(session.id, plug: plug)

      updated = Sessions.get_session!(session.id)
      assert updated.notes_error =~ "Extraction failed"
      assert updated.status == "noting"
    end

    test "writing failure stays on noting" do
      session = setup_session()
      setup_llm_settings()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        if Map.has_key?(decoded, "response_format") do
          Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
        else
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{"error" => "Writer unavailable"})
        end
      end

      assert {:error, _} = Pipeline.run(session.id, plug: plug)

      updated = Sessions.get_session!(session.id)
      assert updated.notes_error =~ "API error 500"
      assert updated.status == "noting"
    end

    test "returns error for non-noting session" do
      {:ok, campaign} = Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{}})
      {:ok, session} = Sessions.create_session(campaign, %{name: "Test Session"})

      assert {:error, reason} = Pipeline.run(session.id)
      assert reason =~ "not in noting status"
    end

    test "broadcasts progress events during extraction" do
      session = setup_session()
      setup_llm_settings()
      Jobs.subscribe(session.id)

      plug = dual_plug(@valid_facts, @notes_markdown)

      {:ok, _pid} = Jobs.start_notes_generation(session, plug: plug)

      assert_receive {:notes_progress,
                      %{
                        stage: :extracting,
                        chunks: [%{index: 0, status: :done}],
                        completed: 1,
                        total: 1
                      }},
                     5000

      assert_receive {:notes_progress, %{stage: :complete}}, 5000

      # Wait for Runner to fully shut down so sandbox isn't torn down mid-query
      case Registry.lookup(Noter.JobRegistry, {session.id, :notes}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5000

        [] ->
          :ok
      end
    end

    test "broadcasts error event on failure" do
      session = setup_session()
      setup_llm_settings()
      Jobs.subscribe(session.id)

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "fail"})
      end

      Pipeline.run(session.id, plug: plug)

      assert_received {:notes_progress, %{stage: :error, error: _}}
    end

    test "banter is stripped from facts before reaching the writer" do
      session = setup_session()
      setup_llm_settings()
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        if Map.has_key?(decoded, "response_format") do
          Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
        else
          user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
          send(test_pid, {:writing_facts, user_msg["content"]})
          Req.Test.json(conn, chat_response(@notes_markdown))
        end
      end

      assert :ok = Pipeline.run(session.id, plug: plug)

      assert_received {:writing_facts, content}
      refute content =~ "banter"
      refute content =~ "Anyone watch the game"
    end

    test "uses session context in extraction request" do
      session = setup_session(%{context: "My campaign context text"})
      setup_llm_settings()
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        if Map.has_key?(decoded, "response_format") do
          user_msg = Enum.find(decoded["messages"], &(&1["role"] == "user"))
          send(test_pid, {:context_in_request, user_msg["content"]})
          Req.Test.json(conn, chat_response(Jason.encode!(@valid_facts)))
        else
          Req.Test.json(conn, chat_response(@notes_markdown))
        end
      end

      Pipeline.run(session.id, plug: plug)

      assert_received {:context_in_request, content}
      assert content =~ "My campaign context text"
    end
  end

  describe "Jobs.start_notes_generation/2" do
    test "returns {:ok, :started} and registers in JobRegistry" do
      session = setup_session()
      setup_llm_settings()

      plug = dual_plug(@valid_facts, @notes_markdown)

      assert {:ok, :started} = Jobs.start_notes_generation(session, plug: plug)
      assert Jobs.running?(session.id, :notes)

      # Wait for Runner to fully shut down so sandbox isn't torn down mid-query
      case Registry.lookup(Noter.JobRegistry, {session.id, :notes}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5000

        [] ->
          :ok
      end
    end

    test "returns {:error, :already_running} when notes job is in progress" do
      session = setup_session()
      setup_llm_settings()

      # Register a fake entry so running?/2 returns true
      Registry.register(Noter.JobRegistry, {session.id, :notes}, [])

      assert {:error, :already_running} = Jobs.start_notes_generation(session)
    end
  end
end
