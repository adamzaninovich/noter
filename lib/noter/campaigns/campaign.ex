defmodule Noter.Campaigns.Campaign do
  use Ecto.Schema
  import Ecto.Changeset

  schema "campaigns" do
    field :name, :string
    field :slug, :string
    field :player_map, :map, default: %{}
    field :common_replacements, :map, default: %{}

    has_many :sessions, Noter.Sessions.Session

    field :session_count, :integer, virtual: true, default: 0

    timestamps()
  end

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:name, :player_map, :common_replacements])
    |> validate_required([:name])
    |> Noter.Slug.generate_slug(:name)
    |> validate_required([:slug], message: "name must contain at least one letter or number")
    |> unique_constraint(:slug, message: "a campaign with a similar name already exists")
  end
end
