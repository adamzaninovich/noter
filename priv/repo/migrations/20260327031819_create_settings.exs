defmodule Noter.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :text

      timestamps()
    end

    create unique_index(:settings, [:key])

    execute(
      """
      INSERT INTO settings (key, value, inserted_at, updated_at)
      VALUES ('transcription_url', '"http://tycho.protogen.cloud:8000"', datetime('now'), datetime('now'))
      """,
      "DELETE FROM settings WHERE key = 'transcription_url'"
    )
  end
end
