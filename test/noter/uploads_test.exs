defmodule Noter.UploadsTest do
  use Noter.DataCase, async: true

  alias Noter.Campaigns
  alias Noter.Sessions
  alias Noter.Uploads

  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    stub(Noter.SystemCmd.Mock, :find_executable, fn "ffmpeg" -> "/usr/bin/ffmpeg" end)

    {:ok, campaign} =
      Campaigns.create_campaign(%{name: "Test Campaign", player_map: %{"coolgamer" => "Thorin"}})

    {:ok, session} = Sessions.create_session(campaign, %{name: "Session 1"})

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
    test "extracts zip, renames flacs, and mixes to wav", %{campaign: campaign, session: session} do
      tmp_dir =
        Path.join(System.tmp_dir!(), "noter_upload_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      renamed_dir = Path.join(Uploads.session_dir(session.id), "renamed")
      File.mkdir_p!(renamed_dir)

      flac_path = Path.join(renamed_dir, "coolgamer.flac")
      File.write!(flac_path, "fake flac content")

      zip_path = Path.join(tmp_dir, "recording.zip")

      {:ok, _} =
        :zip.create(~c"#{zip_path}", [{~c"coolgamer.flac", flac_path}], cwd: ~c"#{tmp_dir}")

      vocab_path = Path.join(tmp_dir, "vocab.txt")
      File.write!(vocab_path, "dragon\nwizard")

      expect(Noter.SystemCmd.Mock, :cmd, fn "unzip", ["-o", ^zip_path, "-d", _], _opts ->
        File.mkdir_p!(Path.join(Uploads.session_dir(session.id), "extracted"))

        File.cp!(
          flac_path,
          Path.join(Uploads.session_dir(session.id), "extracted/coolgamer.flac")
        )

        {"", 0}
      end)

      expect(Noter.SystemCmd.Mock, :cmd, fn "ffmpeg", args, _opts ->
        output_path = Enum.at(args, -1)
        File.write!(output_path, "fake wav content")
        {"", 0}
      end)

      {:ok, renamed} = Uploads.process_uploads(session, campaign, zip_path, vocab_path)

      assert renamed == [{"coolgamer", "Thorin"}]

      session_dir = Uploads.session_dir(session.id)
      assert File.exists?(Path.join(session_dir, "renamed/Thorin.flac"))
      assert File.exists?(Path.join(session_dir, "merged.wav"))
      assert File.exists?(Path.join(session_dir, "vocab.txt"))

      refute File.exists?(zip_path)
      refute File.dir?(Path.join(session_dir, "extracted"))

      File.rm_rf!(tmp_dir)
    end
  end

  describe "mix_tracks_to_wav/2" do
    test "mixes FLAC tracks into a mono WAV file", %{session: session} do
      renamed_dir = Path.join(Uploads.session_dir(session.id), "renamed")
      File.mkdir_p!(renamed_dir)

      File.write!(Path.join(renamed_dir, "Thorin.flac"), "fake flac")
      File.write!(Path.join(renamed_dir, "Gandalf.flac"), "fake flac")

      output_wav = Path.join(Uploads.session_dir(session.id), "merged.wav")

      expect(Noter.SystemCmd.Mock, :cmd, fn "ffmpeg", args, _opts ->
        output_path = Enum.at(args, -1)
        File.write!(output_path, "fake wav content")
        {"", 0}
      end)

      assert :ok = Uploads.mix_tracks_to_wav(renamed_dir, output_wav)
      assert File.exists?(output_wav)
    end

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
    test "trims FLACs and WAV but does not encode M4A", %{campaign: campaign, session: session} do
      session = %{session | campaign: campaign}
      base_dir = Uploads.session_dir(session.id)
      renamed_dir = Path.join(base_dir, "renamed")
      File.mkdir_p!(renamed_dir)

      File.write!(Path.join(renamed_dir, "Thorin.flac"), "fake flac")

      wav_path = Path.join(base_dir, "merged.wav")
      File.write!(wav_path, "fake wav")

      expect(Noter.SystemCmd.Mock, :open_port, 2, fn {:spawn_executable, _path}, opts ->
        args = Keyword.fetch!(opts, :args)
        output_path = Enum.at(args, -1)
        caller = self()
        output_ref = make_ref()

        spawn(fn ->
          File.write!(output_path, "fake trimmed content")
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=500000\n"}})
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=1000000\n"}})
          send(caller, {output_ref, {:exit_status, 0}})
        end)

        output_ref
      end)

      assert :ok = Uploads.trim_session(session, 0.0, 1.0)

      trimmed_dir = Path.join(base_dir, "trimmed")
      assert File.exists?(Path.join(trimmed_dir, "Thorin.flac"))
      assert File.exists?(Path.join(trimmed_dir, "merged.wav"))
      refute File.exists?(Path.join(trimmed_dir, "merged.m4a"))
    end
  end

  describe "encode_merged_m4a/3" do
    test "encodes trimmed WAV to M4A and removes the WAV", %{session: session} do
      base_dir = Uploads.session_dir(session.id)
      trimmed_dir = Path.join(base_dir, "trimmed")
      File.mkdir_p!(trimmed_dir)

      trimmed_wav = Path.join(trimmed_dir, "merged.wav")
      File.write!(trimmed_wav, "fake wav content")

      expect(Noter.SystemCmd.Mock, :open_port, fn {:spawn_executable, _path}, opts ->
        args = Keyword.fetch!(opts, :args)
        output_path = Enum.at(args, -1)
        caller = self()
        output_ref = make_ref()

        spawn(fn ->
          File.write!(output_path, "fake m4a content")
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=500000\n"}})
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=1000000\n"}})
          send(caller, {output_ref, {:exit_status, 0}})
        end)

        output_ref
      end)

      assert :ok = Uploads.encode_merged_m4a(session.id, 1.0)

      assert File.exists?(Path.join(trimmed_dir, "merged.m4a"))
      refute File.exists?(trimmed_wav)
    end

    test "reports progress via callback", %{session: session} do
      base_dir = Uploads.session_dir(session.id)
      trimmed_dir = Path.join(base_dir, "trimmed")
      File.mkdir_p!(trimmed_dir)

      trimmed_wav = Path.join(trimmed_dir, "merged.wav")
      File.write!(trimmed_wav, "fake wav content")

      test_pid = self()
      on_progress = fn pct -> send(test_pid, {:m4a_progress, pct}) end

      expect(Noter.SystemCmd.Mock, :open_port, fn {:spawn_executable, _path}, opts ->
        args = Keyword.fetch!(opts, :args)
        output_path = Enum.at(args, -1)
        caller = self()
        output_ref = make_ref()

        spawn(fn ->
          File.write!(output_path, "fake m4a content")
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=500000\n"}})
          :timer.sleep(10)
          send(caller, {output_ref, {:data, "out_time_us=1000000\n"}})
          send(caller, {output_ref, {:exit_status, 0}})
        end)

        output_ref
      end)

      assert :ok = Uploads.encode_merged_m4a(session.id, 1.0, on_progress)

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
