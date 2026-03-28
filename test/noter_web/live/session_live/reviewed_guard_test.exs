defmodule NoterWeb.SessionLive.ReviewedGuardTest do
  use NoterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Reviewed Session"})

    transcript_json =
      Jason.encode!(%{
        "segments" => [
          %{
            "speaker" => "DM",
            "start" => 0.0,
            "end" => 5.0,
            "words" => [
              %{"word" => " Hello", "start" => 0.0, "end" => 1.0},
              %{"word" => " world", "start" => 1.0, "end" => 5.0}
            ]
          }
        ]
      })

    {:ok, session} =
      Sessions.update_transcription(session, %{
        status: "transcribed",
        transcript_json: transcript_json
      })

    {:ok, session} = Sessions.finalize(session)

    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  defp open_session(conn, campaign, session) do
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{campaign.slug}/sessions/#{session.slug}")
    view
  end

  test "add_replacement is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "add_replacement", %{
      "replacement" => %{"find" => "hello", "replace" => "goodbye"}
    })

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
    assert get_in(reloaded.corrections, ["replacements", "hello"]) == nil
  end

  test "remove_replacement is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "remove_replacement", %{"find" => "nonexistent"})

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
  end

  test "import_replacements is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "import_replacements", %{
      "json" => Jason.encode!(%{"foo" => "bar"})
    })

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
    assert get_in(reloaded.corrections, ["replacements", "foo"]) == nil
  end

  test "start_edit is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "start_edit", %{"turn-id" => "0"})

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
  end

  test "save_edit is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "save_edit", %{"edit" => %{"text" => "modified text"}})

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
    assert get_in(reloaded.corrections, ["edits", "0"]) == nil
  end

  test "delete_turn is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "delete_turn", %{"turn-id" => "0"})

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
    assert get_in(reloaded.corrections, ["edits", "0"]) == nil
  end

  test "remove_edit is rejected when session is reviewed",
       %{conn: conn, campaign: campaign, session: session} do
    view = open_session(conn, campaign, session)

    render_hook(view, "remove_edit", %{"turn-id" => "0"})

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "reviewed"
  end
end
