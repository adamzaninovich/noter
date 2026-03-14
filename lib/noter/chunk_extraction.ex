defmodule Noter.ChunkExtraction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chunk_extractions" do
    field :session_path, :string
    field :chunk_index, :integer
    field :chunk_hash, :string
    field :result, :string

    timestamps(updated_at: false)
  end

  def changeset(extraction, attrs) do
    extraction
    |> cast(attrs, [:session_path, :chunk_index, :chunk_hash, :result])
    |> validate_required([:session_path, :chunk_index, :chunk_hash, :result])
    |> unique_constraint([:session_path, :chunk_index, :chunk_hash])
  end
end
