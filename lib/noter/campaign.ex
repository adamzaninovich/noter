defmodule Noter.Campaign do
  @moduledoc """
  Loads and parses campaign configuration files from the campaign directory.

  Campaign directory layout:
    players.toml       - discord username → character name
    corrections.toml   - transcript misspelling → correct spelling
    vocab.txt          - whisper vocabulary hints (reviewed each session)
  """

  @doc """
  Walks up the directory tree from `start_dir` looking for `players.toml`,
  mirroring how git finds its config. Returns `{:ok, campaign_dir}` or
  `{:error, :not_found}`.
  """
  def find_campaign_dir(start_dir) do
    start_dir
    |> Path.expand()
    |> do_find()
  end

  defp do_find("/"), do: {:error, :not_found}

  defp do_find(dir) do
    if File.exists?(Path.join(dir, "players.toml")) do
      {:ok, dir}
    else
      do_find(Path.dirname(dir))
    end
  end

  @doc """
  Loads `players.toml` from the campaign directory.
  Returns `{:ok, %{discord_username => character_name}}` or `{:error, reason}`.
  """
  def load_players(campaign_dir) do
    path = Path.join(campaign_dir, "players.toml")

    with {:ok, content} <- File.read(path),
         {:ok, map} <- Toml.decode(content) do
      {:ok, map}
    end
  end

  @doc """
  Loads `corrections.toml` from the campaign directory.
  Returns `{:ok, %{wrong => correct}}` or `{:ok, %{}}` if the file doesn't exist yet.
  """
  def load_corrections(campaign_dir) do
    path = Path.join(campaign_dir, "corrections.toml")

    case File.read(path) do
      {:ok, content} ->
        Toml.decode(content)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Saves `corrections.toml` back to the campaign directory.
  The map keys and values must be strings.
  """
  def save_corrections(campaign_dir, corrections) when is_map(corrections) do
    path = Path.join(campaign_dir, "corrections.toml")

    content =
      corrections
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> ~s(#{k} = "#{v}") end)

    File.write(path, content <> "\n")
  end

  @doc """
  Loads `vocab.txt` from the campaign directory (or session tracks/ subdir).
  Returns a list of vocabulary hint strings.
  """
  def load_vocab(dir) do
    path = Path.join(dir, "vocab.txt")

    case File.read(path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, lines}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
