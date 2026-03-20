defmodule Noter.Uploads do
  alias Noter.Prep

  def session_dir(session_id) do
    Path.join([Application.app_dir(:noter, "priv"), "uploads", to_string(session_id)])
  end

  def process_uploads(session, campaign, zip_path, aac_path, vocab_path) do
    base_dir = session_dir(session.id)
    extracted_dir = Path.join(base_dir, "extracted")
    renamed_dir = Path.join(base_dir, "renamed")

    File.mkdir_p!(base_dir)
    File.mkdir_p!(extracted_dir)

    # Move consumed files into session dir
    aac_dest = Path.join(base_dir, "merged.aac")
    vocab_dest = Path.join(base_dir, "vocab.txt")

    if aac_path, do: File.rename!(aac_path, aac_dest)
    if vocab_path, do: File.rename!(vocab_path, vocab_dest)

    # Extract zip, rename FLACs, clean up intermediates
    with :ok <- Prep.extract_zip(zip_path, extracted_dir),
         {:ok, renamed} <- Prep.rename_flacs(extracted_dir, renamed_dir, campaign.player_map) do
      File.rm(zip_path)
      File.rm_rf(extracted_dir)
      {:ok, renamed}
    end
  end

  def list_renamed_files(session_id) do
    dir = Path.join(session_dir(session_id), "renamed")

    if File.dir?(dir) do
      dir
      |> Prep.find_flac_files()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()
    else
      []
    end
  end
end
