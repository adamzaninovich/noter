defmodule Noter.UploadsTest do
  use Noter.DataCase, async: true

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  setup do
    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{"coolgamer" => "Thorin"}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Session 1"})

    # Clean up session uploads dir after test
    on_exit(fn -> File.rm_rf(Uploads.session_dir(session.id)) end)

    {:ok, campaign: campaign, session: session}
  end

  describe "session_dir/1" do
    test "returns the expected path", %{session: session} do
      dir = Uploads.session_dir(session.id)
      assert String.ends_with?(dir, "priv/uploads/#{session.id}")
    end

    test "raises on path traversal attempt" do
      assert_raise ArgumentError, ~r/outside uploads directory/, fn ->
        Uploads.session_dir("../../../etc")
      end
    end
  end

  describe "process_uploads/4" do
    @tag :integration
    test "extracts zip, renames flacs, and mixes to wav", %{campaign: campaign, session: session} do
      tmp_dir =
        Path.join(System.tmp_dir!(), "noter_upload_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Generate a real FLAC file using ffmpeg
      flac_path = Path.join(tmp_dir, "coolgamer.flac")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=1",
          flac_path
        ])

      zip_path = Path.join(tmp_dir, "recording.zip")
      {:ok, _} = :zip.create(~c"#{zip_path}", [~c"coolgamer.flac"], cwd: ~c"#{tmp_dir}")

      vocab_path = Path.join(tmp_dir, "vocab.txt")
      File.write!(vocab_path, "dragon\nwizard")

      {:ok, renamed} = Uploads.process_uploads(session, campaign, zip_path, vocab_path)

      assert renamed == [{"coolgamer", "Thorin"}]

      session_dir = Uploads.session_dir(session.id)
      assert File.exists?(Path.join(session_dir, "renamed/Thorin.flac"))
      assert File.exists?(Path.join(session_dir, "merged.wav"))
      assert File.exists?(Path.join(session_dir, "vocab.txt"))

      # Zip and extracted should be cleaned up
      refute File.exists?(zip_path)
      refute File.dir?(Path.join(session_dir, "extracted"))

      File.rm_rf!(tmp_dir)
    end
  end

  describe "mix_tracks_to_wav/2" do
    @tag :integration
    test "mixes FLAC tracks into a mono WAV file", %{session: session} do
      # Create real FLAC files using ffmpeg (sine wave, 1 second each)
      renamed_dir = Path.join(Uploads.session_dir(session.id), "renamed")
      File.mkdir_p!(renamed_dir)

      for {name, freq} <- [{"Thorin.flac", "440"}, {"Gandalf.flac", "880"}] do
        path = Path.join(renamed_dir, name)

        {_, 0} =
          System.cmd("ffmpeg", [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=#{freq}:duration=1",
            path
          ])
      end

      output_wav = Path.join(Uploads.session_dir(session.id), "merged.wav")

      assert :ok = Uploads.mix_tracks_to_wav(renamed_dir, output_wav)
      assert File.exists?(output_wav)

      # Verify it's a valid mono WAV using ffprobe
      {info, 0} =
        System.cmd("ffprobe", [
          "-v",
          "quiet",
          "-show_entries",
          "stream=channels,codec_name",
          "-of",
          "csv=p=0",
          output_wav
        ])

      assert String.trim(info) == "pcm_s16le,1"
    end

    @tag :integration
    test "returns error for empty directory", %{session: session} do
      empty_dir = Path.join(Uploads.session_dir(session.id), "renamed")
      File.mkdir_p!(empty_dir)
      output_wav = Path.join(Uploads.session_dir(session.id), "merged.wav")

      assert {:error, _reason} = Uploads.mix_tracks_to_wav(empty_dir, output_wav)
    end
  end

  describe "cancel_upload_by_ref/3" do
    alias NoterWeb.SessionLive.UploadHelpers

    test "returns socket unchanged for unrecognized upload ref" do
      socket = %Phoenix.LiveView.Socket{assigns: %{uploads: %{}}}
      result = UploadHelpers.cancel_upload_by_ref(socket, "ref", "unknown-upload-ref")
      assert result == socket
    end
  end

  describe "trim_session/4 does not produce M4A" do
    @tag :integration
    test "trims FLACs and WAV but does not encode M4A", %{campaign: campaign, session: session} do
      session = %{session | campaign: campaign}
      base_dir = Uploads.session_dir(session.id)
      renamed_dir = Path.join(base_dir, "renamed")
      File.mkdir_p!(renamed_dir)

      # Create a short FLAC and merged WAV for trimming
      flac_path = Path.join(renamed_dir, "Thorin.flac")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=2",
          flac_path
        ])

      wav_path = Path.join(base_dir, "merged.wav")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=2",
          wav_path
        ])

      assert :ok = Uploads.trim_session(session, 0.0, 1.0)

      trimmed_dir = Path.join(base_dir, "trimmed")
      assert File.exists?(Path.join(trimmed_dir, "Thorin.flac"))
      assert File.exists?(Path.join(trimmed_dir, "merged.wav"))
      # M4A should NOT be produced by trim_session anymore
      refute File.exists?(Path.join(trimmed_dir, "merged.m4a"))
    end
  end

  describe "encode_merged_m4a/3" do
    @tag :integration
    test "encodes trimmed WAV to M4A and removes the WAV", %{session: session} do
      base_dir = Uploads.session_dir(session.id)
      trimmed_dir = Path.join(base_dir, "trimmed")
      File.mkdir_p!(trimmed_dir)

      trimmed_wav = Path.join(trimmed_dir, "merged.wav")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=1",
          trimmed_wav
        ])

      assert :ok = Uploads.encode_merged_m4a(session.id, 1.0)

      assert File.exists?(Path.join(trimmed_dir, "merged.m4a"))
      # WAV should be cleaned up after encode
      refute File.exists?(trimmed_wav)
    end

    @tag :integration
    test "reports progress via callback", %{session: session} do
      base_dir = Uploads.session_dir(session.id)
      trimmed_dir = Path.join(base_dir, "trimmed")
      File.mkdir_p!(trimmed_dir)

      trimmed_wav = Path.join(trimmed_dir, "merged.wav")

      {_, 0} =
        System.cmd("ffmpeg", [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=1",
          trimmed_wav
        ])

      test_pid = self()
      on_progress = fn pct -> send(test_pid, {:m4a_progress, pct}) end

      assert :ok = Uploads.encode_merged_m4a(session.id, 1.0, on_progress)

      # Should receive at least 0 and 100
      assert_received {:m4a_progress, 0}
      assert_received {:m4a_progress, 100}
    end
  end

  describe "list_renamed_files/1" do
    test "lists files in renamed directory", %{session: session} do
      renamed_dir = Path.join(Uploads.session_dir(session.id), "renamed")
      File.mkdir_p!(renamed_dir)
      File.write!(Path.join(renamed_dir, "Thorin.flac"), "data")
      File.write!(Path.join(renamed_dir, "Gandalf.flac"), "data")

      files = Uploads.list_renamed_files(session.id)
      assert files == ["Gandalf.flac", "Thorin.flac"]
    end

    test "returns empty list when dir doesn't exist", %{session: session} do
      assert Uploads.list_renamed_files(session.id) == []
    end
  end
end
