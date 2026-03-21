defmodule Noter.Campaigns.Campaign do
  use Ecto.Schema
  import Ecto.Changeset

  schema "campaigns" do
    field :name, :string
    field :slug, :string
    field :player_map, :map, default: %{}

    has_many :sessions, Noter.Sessions.Session

    timestamps()
  end

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:name, :player_map])
    |> validate_required([:name])
    |> generate_slug()
    |> validate_required([:slug], message: "name must contain at least one letter or number")
    |> unique_constraint(:slug, message: "a campaign with a similar name already exists")
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
