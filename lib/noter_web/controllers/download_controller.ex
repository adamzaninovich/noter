defmodule NoterWeb.DownloadController do
  use NoterWeb, :controller

  alias Noter.Sessions
  alias Noter.Sessions.Session
  alias Noter.Transcription.Transcript
  alias Noter.Uploads

  def download(conn, %{"session_id" => session_id}) do
    session = Sessions.get_session_with_campaign!(session_id)

    if session.status != "done" do
      conn
      |> put_flash(:error, "Session must be finalized before downloading.")
      |> redirect(to: ~p"/campaigns/#{session.campaign.slug}/sessions/#{session.slug}")
    else
      session_dir = Uploads.session_dir(session.id)
      root = "#{session.campaign.name} #{session.name}"

      entries =
        []
        |> add_merged_audio(session_dir, root)
        |> add_tracks(session_dir, root)
        |> add_transcripts(session, root)
        |> add_vocab(session_dir, root)

      filename = "#{root}.zip"

      entries
      |> Packmatic.build_stream()
      |> Packmatic.Conn.send_chunked(conn, filename)
    end
  end

  defp add_merged_audio(entries, session_dir, root) do
    path = Path.join([session_dir, "trimmed", "merged.m4a"])

    if File.exists?(path) do
      # method: :store skips compression since audio files are already compressed
      [[source: {:file, path}, path: "#{root}/#{root} Merged.m4a", method: :store] | entries]
    else
      entries
    end
  end

  defp add_tracks(entries, session_dir, root) do
    trimmed_dir = Path.join(session_dir, "trimmed")

    if File.dir?(trimmed_dir) do
      trimmed_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".flac"))
      |> Enum.sort()
      |> Enum.reduce(entries, fn flac, acc ->
        path = Path.join(trimmed_dir, flac)
        # method: :store skips compression since audio files are already compressed
        [[source: {:file, path}, path: "#{root}/tracks/#{flac}", method: :store] | acc]
      end)
    else
      entries
    end
  end

  defp add_transcripts(entries, session, root) do
    raw_turns = Transcript.parse_turns(session.transcript_json)

    corrected_turns =
      Transcript.apply_corrections(
        raw_turns,
        Session.replacements(session),
        Session.edits(session)
      )

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

    entries
    |> then(
      &[[source: {:stream, [corrected_json]}, path: "#{root}/transcripts/merged.json"] | &1]
    )
    |> then(&[[source: {:stream, [srt]}, path: "#{root}/transcripts/merged.srt"] | &1])
  end

  defp add_vocab(entries, session_dir, root) do
    path = Path.join(session_dir, "vocab.txt")

    if File.exists?(path) do
      [[source: {:file, path}, path: "#{root}/vocab.txt"] | entries]
    else
      entries
    end
  end
end
