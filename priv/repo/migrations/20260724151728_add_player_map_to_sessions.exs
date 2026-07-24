defmodule Noter.Repo.Migrations.AddPlayerMapToSessions do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :player_map, :map, null: false, default: %{}
    end

    flush()

    # Freeze the current campaign roster onto every existing session.
    # Before this change ships, all existing sessions belong to the
    # current (pre-swap) roster, so this backfill is correct.
    execute("""
    UPDATE sessions
    SET player_map = campaigns.player_map
    FROM campaigns
    WHERE sessions.campaign_id = campaigns.id
    """)
  end

  def down do
    alter table(:sessions) do
      remove :player_map
    end
  end
end
