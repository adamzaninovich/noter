defmodule Noter.Repo.Migrations.AddNotesFieldsAndReviewedStatus do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :context, :text
      add :session_notes, :text
      add :notes_status, :string
      add :notes_error, :text
    end

    execute "UPDATE sessions SET status = 'reviewed' WHERE status = 'done'",
            "UPDATE sessions SET status = 'done' WHERE status = 'reviewed'"
  end
end
