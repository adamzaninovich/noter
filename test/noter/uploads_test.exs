defmodule Noter.UploadsTest do
  use Noter.DataCase, async: true

  alias Noter.Uploads
  alias Noter.Campaigns
  alias Noter.Sessions

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
  end

  describe "process_uploads/5" do
    test "extracts zip and renames flacs", %{campaign: campaign, session: session} do
      # Create a zip with a fake flac
      tmp_dir =
        Path.join(System.tmp_dir!(), "noter_upload_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      flac_content = "fake flac data"
      flac_path = Path.join(tmp_dir, "coolgamer.flac")
      File.write!(flac_path, flac_content)

      zip_path = Path.join(tmp_dir, "recording.zip")
      {:ok, _} = :zip.create(~c"#{zip_path}", [~c"coolgamer.flac"], cwd: ~c"#{tmp_dir}")

      aac_path = Path.join(tmp_dir, "merged.aac")
      File.write!(aac_path, "fake aac")

      vocab_path = Path.join(tmp_dir, "vocab.txt")
      File.write!(vocab_path, "dragon\nwizard")

      {:ok, renamed} = Uploads.process_uploads(session, campaign, zip_path, aac_path, vocab_path)

      assert renamed == [{"coolgamer", "Thorin"}]

      session_dir = Uploads.session_dir(session.id)
      assert File.exists?(Path.join(session_dir, "renamed/Thorin.flac"))
      assert File.exists?(Path.join(session_dir, "merged.aac"))
      assert File.exists?(Path.join(session_dir, "vocab.txt"))

      # Zip and extracted should be cleaned up
      refute File.exists?(zip_path)
      refute File.dir?(Path.join(session_dir, "extracted"))

      File.rm_rf!(tmp_dir)
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
