defmodule Noter.Repo.Migrations.CreateChunkExtractions do
  use Ecto.Migration

  def change do
    create table(:chunk_extractions) do
      add :session_path, :string, null: false
      add :chunk_index, :integer, null: false
      add :chunk_hash, :string, null: false
      add :result, :text, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:chunk_extractions, [:session_path, :chunk_index, :chunk_hash])
  end
end
