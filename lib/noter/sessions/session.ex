defmodule Noter.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(uploading trimming transcribing reviewing noting done)

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
    field :context, :string
    field :session_notes, :string
    field :notes_error, :string

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
    |> Noter.Slug.generate_slug(:name)
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

  def notes_changeset(session, attrs) do
    session
    |> cast(attrs, [:session_notes, :notes_error, :context, :status, :transcript_srt])
    |> validate_inclusion(:status, @valid_statuses)
  end

  def corrections(%__MODULE__{corrections: c}), do: c || %{}
  def replacements(%__MODULE__{corrections: c}), do: Map.get(c || %{}, "replacements", %{})
  def edits(%__MODULE__{corrections: c}), do: Map.get(c || %{}, "edits", %{})

  def put_corrections(%__MODULE__{corrections: c}, key, value) do
    Map.put(c || %{}, key, value)
  end
end
