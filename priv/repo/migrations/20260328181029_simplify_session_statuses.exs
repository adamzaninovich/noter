defmodule Noter.Repo.Migrations.SimplifySessionStatuses do
  use Ecto.Migration

  def up do
    # Map intermediate statuses to their simplified equivalents
    execute "UPDATE sessions SET status = 'trimming' WHERE status IN ('uploaded', 'trimmed')"
    execute "UPDATE sessions SET status = 'reviewing' WHERE status IN ('transcribed', 'reviewed')"

    alter table(:sessions) do
      remove :notes_status
    end
  end

  def down do
    alter table(:sessions) do
      add :notes_status, :string
    end
  end
end
