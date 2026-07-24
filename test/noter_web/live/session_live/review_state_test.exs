defmodule NoterWeb.SessionLive.ReviewStateTest do
  use ExUnit.Case, async: true

  alias Noter.Sessions.Session
  alias NoterWeb.SessionLive.ReviewState

  test "build_speaker_colors sources characters from session.player_map" do
    session = %Session{player_map: %{"alice" => "Thorin", "bob" => "Gandalf"}}
    colors = ReviewState.build_speaker_colors(["Thorin", "Gandalf"], session)

    assert Map.has_key?(colors, "Thorin")
    assert Map.has_key?(colors, "Gandalf")
    assert colors["Thorin"] != nil
  end
end
