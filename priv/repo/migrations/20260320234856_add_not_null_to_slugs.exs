defmodule Noter.Repo.Migrations.AddNotNullToSlugs do
  use Ecto.Migration

  def change do
    # Backfill any NULL slugs before adding the constraint
    execute "UPDATE campaigns SET slug = lower(replace(name, ' ', '-')) WHERE slug IS NULL",
            "SELECT 1"

    execute "UPDATE sessions SET slug = lower(replace(name, ' ', '-')) WHERE slug IS NULL",
            "SELECT 1"

    # SQLite doesn't support ALTER COLUMN, so enforce NOT NULL at the application level.
    # The unique indexes on slug already exist, and the schema/changeset always generates slugs.
    # The validate_required(:slug) in the changeset is the enforcement mechanism.
  end
end
