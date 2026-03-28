defmodule Noter.Notes.PromptsTest do
  use ExUnit.Case, async: true

  alias Noter.Notes.Prompts

  describe "extraction_messages/3" do
    test "returns a list of two messages" do
      msgs = Prompts.extraction_messages("some text", "00:00:00–00:10:00", "context")
      assert length(msgs) == 2
    end

    test "messages use string keys" do
      [system, user] = Prompts.extraction_messages("text", "range", "ctx")
      assert Map.has_key?(system, "role")
      assert Map.has_key?(system, "content")
      assert Map.has_key?(user, "role")
      assert Map.has_key?(user, "content")
    end

    test "first message is system role" do
      [system | _] = Prompts.extraction_messages("text", "range", "ctx")
      assert system["role"] == "system"
    end

    test "second message is user role" do
      [_, user] = Prompts.extraction_messages("text", "range", "ctx")
      assert user["role"] == "user"
    end

    test "context is included in user message" do
      [_, user] = Prompts.extraction_messages("text", "range", "My campaign context")
      assert user["content"] =~ "My campaign context"
    end

    test "chunk text is included in user message" do
      [_, user] = Prompts.extraction_messages("[00:00:01] Alice: Hello", "range", "ctx")
      assert user["content"] =~ "[00:00:01] Alice: Hello"
    end

    test "range is included in user message" do
      [_, user] = Prompts.extraction_messages("text", "00:05:00–00:10:00", "ctx")
      assert user["content"] =~ "00:05:00–00:10:00"
    end

    test "handles nil context" do
      assert [_, user] = Prompts.extraction_messages("text", "range", nil)
      assert is_binary(user["content"])
    end
  end

  describe "writing_messages/2" do
    test "returns a list of two messages" do
      facts = %{"events" => [], "npcs" => []}
      msgs = Prompts.writing_messages(facts, "context")
      assert length(msgs) == 2
    end

    test "messages use string keys" do
      [system, user] = Prompts.writing_messages(%{}, "ctx")
      assert Map.has_key?(system, "role")
      assert Map.has_key?(user, "role")
    end

    test "first message is system role" do
      [system | _] = Prompts.writing_messages(%{}, "ctx")
      assert system["role"] == "system"
    end

    test "second message is user role" do
      [_, user] = Prompts.writing_messages(%{}, "ctx")
      assert user["role"] == "user"
    end

    test "context is included in user message" do
      [_, user] = Prompts.writing_messages(%{}, "Campaign world details")
      assert user["content"] =~ "Campaign world details"
    end

    test "facts are JSON-encoded in user message" do
      facts = %{"events" => [%{"text" => "Something happened"}]}
      [_, user] = Prompts.writing_messages(facts, "ctx")
      assert user["content"] =~ "Something happened"
      assert user["content"] =~ "events"
    end

    test "handles nil context" do
      assert [_, user] = Prompts.writing_messages(%{}, nil)
      assert is_binary(user["content"])
    end
  end
end
