defmodule Noter.Repo.Migrations.AddChunkFactsToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :chunk_facts, :map, default: %{}
    end
  end
end
