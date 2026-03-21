defmodule Noter.Repo.Migrations.AddDurationToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :duration_seconds, :float
    end
  end
end
