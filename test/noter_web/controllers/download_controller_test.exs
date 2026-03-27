defmodule NoterWeb.DownloadControllerTest do
  use NoterWeb.ConnCase, async: true

  alias Noter.{Campaigns, Sessions, Uploads}
  alias Noter.Sessions.Session

  @transcript_json Jason.encode!(%{
                     "segments" => [
                       %{
                         "speaker" => "Alice",
                         "start" => 0.0,
                         "end" => 2.5,
                         "text" => "Hello world",
                         "words" => [
                           %{"word" => " Hello", "start" => 0.0, "end" => 1.0},
                           %{"word" => " world", "start" => 1.0, "end" => 2.5}
                         ]
                       }
                     ]
                   })

  defp create_session(opts \\ []) do
    {:ok, campaign} = Campaigns.create_campaign(%{name: "Test Campaign"})
    {:ok, session} = Sessions.create_session(campaign, %{name: "Session One"})

    transcript = Keyword.get(opts, :transcript_json, @transcript_json)
    status = Keyword.get(opts, :status, "reviewed")

    {:ok, session} =
      session
      |> Session.transcription_changeset(%{
        status: "transcribed",
        transcript_json: transcript
      })
      |> Noter.Repo.update()

    {:ok, session} =
      session
      |> Session.corrections_changeset(%{status: status})
      |> Noter.Repo.update()

    session = Noter.Repo.preload(session, :campaign)
    {campaign, session}
  end

  defp setup_upload_files(session) do
    session_dir = Uploads.session_dir(session.id)
    trimmed_dir = Path.join(session_dir, "trimmed")
    File.mkdir_p!(trimmed_dir)

    File.write!(Path.join(trimmed_dir, "merged.m4a"), "fake-m4a-data")
    File.write!(Path.join(trimmed_dir, "track01.flac"), "fake-flac-1")
    File.write!(Path.join(trimmed_dir, "track02.flac"), "fake-flac-2")
    File.write!(Path.join(session_dir, "vocab.txt"), "dragon\nkobold\n")

    on_exit(fn -> File.rm_rf!(session_dir) end)
  end

  defp unzip(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, data} -> {to_string(name), data} end)
  end

  describe "download/2" do
    test "redirects when session is not finalized", %{conn: conn} do
      {_campaign, session} = create_session(status: "uploaded")

      conn = get(conn, "/sessions/#{session.id}/download")

      assert redirected_to(conn) =~
               "/campaigns/#{session.campaign.slug}/sessions/#{session.slug}"
    end

    test "streams a zip with all files for a finalized session", %{conn: conn} do
      {_campaign, session} = create_session()
      setup_upload_files(session)

      conn = get(conn, "/sessions/#{session.id}/download")

      assert conn.status == 200

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "Test%20Campaign%20Session%20One"

      files = unzip(conn.resp_body)
      root = "Test Campaign Session One"

      assert Map.has_key?(files, "#{root}/#{root} - Merged.m4a")
      assert Map.has_key?(files, "#{root}/tracks/track01.flac")
      assert Map.has_key?(files, "#{root}/tracks/track02.flac")
      assert Map.has_key?(files, "#{root}/transcripts/merged.json")
      assert Map.has_key?(files, "#{root}/transcripts/merged.srt")
      assert Map.has_key?(files, "#{root}/vocab.txt")

      assert files["#{root}/#{root} - Merged.m4a"] == "fake-m4a-data"
      assert files["#{root}/tracks/track01.flac"] == "fake-flac-1"
      assert files["#{root}/vocab.txt"] == "dragon\nkobold\n"
    end

    test "transcript json contains corrected segments", %{conn: conn} do
      {_campaign, session} = create_session()
      setup_upload_files(session)

      conn = get(conn, "/sessions/#{session.id}/download")

      files = unzip(conn.resp_body)
      root = "Test Campaign Session One"
      json = Jason.decode!(files["#{root}/transcripts/merged.json"])

      assert [segment] = json["segments"]
      assert segment["speaker"] == "Alice"
      assert segment["text"] == "Hello world"
    end

    test "transcript srt contains formatted subtitles", %{conn: conn} do
      {_campaign, session} = create_session()
      setup_upload_files(session)

      conn = get(conn, "/sessions/#{session.id}/download")

      files = unzip(conn.resp_body)
      root = "Test Campaign Session One"
      srt = files["#{root}/transcripts/merged.srt"]

      assert srt =~ "[Alice]"
      assert srt =~ "Hello world"
      assert srt =~ "00:00:00,000"
    end

    test "omits missing files gracefully", %{conn: conn} do
      {_campaign, session} = create_session()
      session_dir = Uploads.session_dir(session.id)
      on_exit(fn -> File.rm_rf!(session_dir) end)

      conn = get(conn, "/sessions/#{session.id}/download")

      assert conn.status == 200
      files = unzip(conn.resp_body)
      root = "Test Campaign Session One"

      assert Map.has_key?(files, "#{root}/transcripts/merged.json")
      assert Map.has_key?(files, "#{root}/transcripts/merged.srt")
      refute Map.has_key?(files, "#{root}/#{root} - Merged.m4a")
      refute Map.has_key?(files, "#{root}/vocab.txt")
    end
  end
end
