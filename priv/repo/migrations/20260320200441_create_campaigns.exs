defmodule Noter.Repo.Migrations.CreateCampaigns do
  use Ecto.Migration

  def change do
    create table(:campaigns) do
      add :name, :string, null: false
      add :player_map, :map, default: %{}

      timestamps()
    end
  end
end
