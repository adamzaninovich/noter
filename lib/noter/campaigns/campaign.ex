defmodule Noter.Campaigns.Campaign do
  use Ecto.Schema
  import Ecto.Changeset

  schema "campaigns" do
    field :name, :string
    field :player_map, :map, default: %{}

    has_many :sessions, Noter.Sessions.Session

    timestamps()
  end

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, [:name, :player_map])
    |> validate_required([:name])
  end
end
