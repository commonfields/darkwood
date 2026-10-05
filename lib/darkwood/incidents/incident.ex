defmodule Darkwood.Incidents.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  schema "incidents" do
    field :title, :string
    field :summary, :string
    field :severity, Ecto.Enum, values: [:minor, :major, :critical], default: :minor

    field :status, Ecto.Enum,
      values: [:investigating, :identified, :mitigated, :resolved],
      default: :investigating

    # The fingerprint that opened this incident. Set only by the grouper, never
    # cast from user input — a repeat signal with the same fingerprint is
    # routed to the open incident that already carries it.
    field :signature, :string

    has_many :events, Darkwood.Incidents.IncidentEvent
    has_many :annotations, Darkwood.Incidents.Annotation
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:title, :summary, :severity])
    |> validate_required([:title, :severity])
    |> validate_length(:title, min: 3, max: 120)
    |> validate_length(:summary, max: 2000)
    |> unique_constraint(:title, name: :incidents_sample_title_index)
  end

  def status_changeset(incident, attrs) do
    incident |> cast(attrs, [:status]) |> validate_required([:status])
  end
end
