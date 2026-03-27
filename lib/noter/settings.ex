defmodule Noter.Settings do
  @moduledoc """
  Database-backed key-value settings store.
  Values are JSON-encoded for type preservation.
  """

  alias Noter.Repo
  alias Noter.Settings.Setting

  def get(key, default \\ nil) do
    case Repo.get_by(Setting, key: key) do
      nil -> default
      setting -> Jason.decode!(setting.value)
    end
  end

  def set(key, value) do
    encoded = Jason.encode!(value)

    case Repo.get_by(Setting, key: key) do
      nil -> %Setting{}
      existing -> existing
    end
    |> Setting.changeset(%{key: key, value: encoded})
    |> Repo.insert_or_update()
  end

  def set!(key, value) do
    case set(key, value) do
      {:ok, setting} ->
        setting

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, changeset: changeset, action: :insert_or_update
    end
  end

  def all do
    Setting
    |> Repo.all()
    |> Map.new(fn setting -> {setting.key, Jason.decode!(setting.value)} end)
  end

  def configured?(key) do
    case get(key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
