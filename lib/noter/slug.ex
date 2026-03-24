defmodule Noter.Slug do
  @moduledoc "Shared slug generation for schemas."
  import Ecto.Changeset

  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  def generate_slug(changeset, source_field) do
    case get_change(changeset, source_field) do
      nil -> changeset
      value -> put_change(changeset, :slug, slugify(value))
    end
  end
end
