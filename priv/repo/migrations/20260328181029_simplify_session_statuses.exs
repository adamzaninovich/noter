defmodule Noter.Repo.Migrations.SimplifySessionStatuses do
  use Ecto.Migration

  def up do
    # Map intermediate statuses to their simplified equivalents
    execute "UPDATE sessions SET status = 'trimming' WHERE status = 'uploaded'"
    execute "UPDATE sessions SET status = 'transcribing' WHERE status = 'trimmed'"
    execute "UPDATE sessions SET status = 'reviewing' WHERE status IN ('transcribed', 'reviewed')"

    alter table(:sessions) do
      remove :notes_status
    end
  end

  def down do
    execute "UPDATE sessions SET status = 'uploaded' WHERE status = 'trimming'"
    execute "UPDATE sessions SET status = 'trimmed' WHERE status = 'transcribing'"
    execute "UPDATE sessions SET status = 'transcribed' WHERE status = 'reviewing'"
    execute "UPDATE sessions SET status = 'reviewed' WHERE status = 'noting'"

    alter table(:sessions) do
      add :notes_status, :string
    end
  end
end
