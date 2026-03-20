defmodule Noter.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "uploading"
      add :trim_start_seconds, :float
      add :trim_end_seconds, :float
      add :transcription_job_id, :string
      add :transcript_json, :text
      add :transcript_srt, :text
      add :corrections, :map, default: %{}

      timestamps()
    end

    create index(:sessions, [:campaign_id])
  end
end
