defmodule Noter.Repo.Migrations.AddCommonReplacementsToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :common_replacements, :map, default: %{}, null: false
    end
  end
end
