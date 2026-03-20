defmodule Noter.Repo.Migrations.AddUniqueSessionNamePerCampaign do
  use Ecto.Migration

  def change do
    create unique_index(:sessions, [:campaign_id, :name])
  end
end
