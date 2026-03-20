defmodule Noter.PrepTest do
  use ExUnit.Case, async: true

  alias Noter.Prep

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "noter_prep_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "rename_flacs/3" do
    test "renames matched files using player map", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source")
      output = Path.join(tmp_dir, "output")
      File.mkdir_p!(source)

      File.write!(Path.join(source, "coolgamer.flac"), "fake flac")
      File.write!(Path.join(source, "otherplayer.flac"), "fake flac 2")

      player_map = %{"coolgamer" => "Thorin", "otherplayer" => "Gandalf"}
      {:ok, results} = Prep.rename_flacs(source, output, player_map)

      assert Enum.sort(results) == [{"coolgamer", "Thorin"}, {"otherplayer", "Gandalf"}]
      assert File.exists?(Path.join(output, "Thorin.flac"))
      assert File.exists?(Path.join(output, "Gandalf.flac"))
    end

    test "handles numeric-prefixed filenames", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source")
      output = Path.join(tmp_dir, "output")
      File.mkdir_p!(source)

      File.write!(Path.join(source, "2-coolgamer.flac"), "fake flac")

      player_map = %{"coolgamer" => "Thorin"}
      {:ok, results} = Prep.rename_flacs(source, output, player_map)

      assert results == [{"2-coolgamer", "Thorin"}]
      assert File.exists?(Path.join(output, "Thorin.flac"))
    end

    test "keeps original name for unmatched users", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source")
      output = Path.join(tmp_dir, "output")
      File.mkdir_p!(source)

      File.write!(Path.join(source, "unknownuser.flac"), "fake flac")

      {:ok, results} = Prep.rename_flacs(source, output, %{})

      assert results == [{"unknownuser", "unknownuser"}]
      assert File.exists?(Path.join(output, "unknownuser.flac"))
    end

    test "returns empty list when no flacs found", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "source")
      output = Path.join(tmp_dir, "output")
      File.mkdir_p!(source)

      {:ok, results} = Prep.rename_flacs(source, output, %{})
      assert results == []
    end
  end
end
