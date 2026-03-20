defmodule Noter.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(uploading uploaded trimmed transcribing transcribed reviewing done)

  schema "sessions" do
    field :name, :string
    field :status, :string, default: "uploading"
    field :trim_start_seconds, :float
    field :trim_end_seconds, :float
    field :transcription_job_id, :string
    field :transcript_json, :string
    field :transcript_srt, :string
    field :corrections, :map, default: %{}

    belongs_to :campaign, Noter.Campaigns.Campaign

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :status])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
