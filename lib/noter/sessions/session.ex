defmodule Noter.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(uploading uploaded trimming trimmed transcribing transcribed reviewing done)

  schema "sessions" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "uploading"
    field :duration_seconds, :float
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
    |> cast(attrs, [:name, :status, :duration_seconds, :trim_start_seconds, :trim_end_seconds])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:trim_start_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:trim_end_seconds, greater_than_or_equal_to: 0)
    |> generate_slug()
    |> validate_required([:slug], message: "name must contain at least one letter or number")
    |> unique_constraint([:campaign_id, :slug],
      message: "a session with a similar name already exists in this campaign"
    )
  end

  def transcription_changeset(session, attrs) do
    session
    |> cast(attrs, [:status, :transcription_job_id, :transcript_json])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end

  def corrections_changeset(session, attrs) do
    session
    |> cast(attrs, [:corrections, :status, :transcript_srt])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
