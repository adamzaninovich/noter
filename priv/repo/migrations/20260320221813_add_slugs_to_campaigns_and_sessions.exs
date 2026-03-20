defmodule Noter.Repo.Migrations.AddSlugsToCampaignsAndSessions do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :slug, :string
    end

    alter table(:sessions) do
      add :slug, :string
    end

    create unique_index(:campaigns, [:slug])
    create unique_index(:sessions, [:campaign_id, :slug])

    # Drop the old name-based unique index since slugs are now the uniqueness mechanism
    drop_if_exists index(:sessions, [:campaign_id, :name])
  end
end
