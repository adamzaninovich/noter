defmodule Noter.SessionsTest do
  use Noter.DataCase, async: true

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Sessions.Session

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Test Session"})

    {:ok, campaign: campaign, session: session}
  end

  describe "Session.replacements/1" do
    test "returns empty map when corrections is nil" do
      session = %Session{corrections: nil}
      assert Session.replacements(session) == %{}
    end

    test "returns replacements map when present" do
      session = %Session{corrections: %{"replacements" => %{"foo" => "bar"}}}
      assert Session.replacements(session) == %{"foo" => "bar"}
    end

    test "returns empty map when corrections has no replacements key" do
      session = %Session{corrections: %{}}
      assert Session.replacements(session) == %{}
    end
  end

  describe "Session.edits/1" do
    test "returns empty map when corrections is nil" do
      session = %Session{corrections: nil}
      assert Session.edits(session) == %{}
    end

    test "returns edits map when present" do
      session = %Session{corrections: %{"edits" => %{"0" => "edited text"}}}
      assert Session.edits(session) == %{"0" => "edited text"}
    end

    test "returns empty map when corrections has no edits key" do
      session = %Session{corrections: %{}}
      assert Session.edits(session) == %{}
    end
  end

  describe "Session.put_corrections/3" do
    test "builds map from nil corrections" do
      session = %Session{corrections: nil}

      assert Session.put_corrections(session, "replacements", %{"a" => "b"}) ==
               %{"replacements" => %{"a" => "b"}}
    end

    test "merges into existing corrections" do
      session = %Session{corrections: %{"edits" => %{"0" => "x"}}}
      result = Session.put_corrections(session, "replacements", %{"a" => "b"})
      assert result == %{"edits" => %{"0" => "x"}, "replacements" => %{"a" => "b"}}
    end
  end

  describe "nil corrections safety" do
    setup %{session: session} do
      # Force corrections to nil in the DB to simulate a NULL column
      session =
        session
        |> Ecto.Changeset.change(%{corrections: nil})
        |> Repo.update!()

      assert session.corrections == nil
      {:ok, session: session}
    end

    test "add_replacement works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_replacement(session, "hello", "world")
      assert updated.corrections["replacements"]["hello"] == "world"
    end

    test "remove_replacement works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.remove_replacement(session, "nonexistent")
      assert updated.corrections["replacements"] == %{}
    end

    test "add_edit works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_edit(session, 0, "edited text")
      assert updated.corrections["edits"]["0"] == "edited text"
    end

    test "remove_edit works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.remove_edit(session, 0)
      assert updated.corrections["edits"] == %{}
    end

    test "add_replacements works when corrections is nil", %{session: session} do
      {:ok, updated} = Sessions.add_replacements(session, %{"Foo" => "bar", "BAZ" => "qux"})
      assert updated.corrections["replacements"] == %{"foo" => "bar", "baz" => "qux"}
    end
  end
end
