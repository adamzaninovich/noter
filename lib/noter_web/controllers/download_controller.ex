defmodule NoterWeb.DownloadController do
  use NoterWeb, :controller

  alias Noter.Sessions
  alias Noter.Sessions.Session
  alias Noter.Uploads
  alias Noter.Transcription.Transcript

  def download(conn, %{"session_id" => session_id}) do
    session = Sessions.get_session_with_campaign!(session_id)

    if session.status != "done" do
      conn
      |> put_flash(:error, "Session must be finalized before downloading.")
      |> redirect(to: ~p"/campaigns/#{session.campaign.slug}/sessions/#{session.slug}")
    else
      zip_binary = build_zip(session)
      filename = "#{session.campaign.name} #{session.name}.zip"

      send_download(conn, {:binary, zip_binary},
        filename: filename,
        content_type: "application/zip"
      )
    end
  end

  defp build_zip(session) do
    session_dir = Uploads.session_dir(session.id)
    root = "#{session.campaign.name} #{session.name}"

    files =
      []
      |> add_merged_audio(session_dir, root)
      |> add_tracks(session_dir, root)
      |> add_transcripts(session, root)
      |> add_vocab(session_dir, root)

    {:ok, {_filename, zip_binary}} = :zip.create(~c"#{root}.zip", files, [:memory])
    zip_binary
  end

  defp add_merged_audio(files, session_dir, root) do
    path = Path.join([session_dir, "trimmed", "merged.m4a"])

    if File.exists?(path) do
      [{~c"#{root}/#{root} Merged.m4a", File.read!(path)} | files]
    else
      files
    end
  end

  defp add_tracks(files, session_dir, root) do
    trimmed_dir = Path.join(session_dir, "trimmed")

    if File.dir?(trimmed_dir) do
      trimmed_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".flac"))
      |> Enum.sort()
      |> Enum.reduce(files, fn flac, acc ->
        path = Path.join(trimmed_dir, flac)
        [{~c"#{root}/tracks/#{flac}", File.read!(path)} | acc]
      end)
    else
      files
    end
  end

  defp add_transcripts(files, session, root) do
    raw_turns = Transcript.parse_turns(session.transcript_json)
    corrected_turns = Transcript.apply_corrections(raw_turns, Session.corrections(session))
    srt = session.transcript_srt || Transcript.segments_to_srt(corrected_turns)

    corrected_json =
      Jason.encode!(
        %{
          "segments" =>
            Enum.map(corrected_turns, fn turn ->
              %{
                "speaker" => turn.speaker,
                "start" => turn.start,
                "end" => turn.end,
                "text" => turn.text
              }
            end)
        },
        pretty: true
      )

    files
    |> then(&[{~c"#{root}/transcripts/merged.json", corrected_json} | &1])
    |> then(&[{~c"#{root}/transcripts/merged.srt", srt} | &1])
  end

  defp add_vocab(files, session_dir, root) do
    path = Path.join(session_dir, "vocab.txt")

    if File.exists?(path) do
      [{~c"#{root}/vocab.txt", File.read!(path)} | files]
    else
      files
    end
  end
end
