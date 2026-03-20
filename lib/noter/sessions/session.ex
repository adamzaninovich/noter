defmodule Noter.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(uploading uploaded trimmed transcribing transcribed reviewing done)

  schema "sessions" do
    field :name, :string
    field :slug, :string
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
    |> generate_slug()
    |> unique_constraint([:campaign_id, :slug],
      message: "a session with this name already exists in this campaign"
    )
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
