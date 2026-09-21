defmodule Darkwood.Incidents.Annotation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "annotations" do
    field :author_name, :string
    field :body, :string
    belongs_to :incident, Darkwood.Incidents.Incident
    belongs_to :event, Darkwood.Incidents.IncidentEvent
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [:author_name, :body, :event_id])
    |> validate_required([:author_name, :body])
    |> validate_length(:author_name, min: 1, max: 80)
    |> validate_length(:body, min: 1, max: 2000)
    |> foreign_key_constraint(:incident_id)
    |> foreign_key_constraint(:event_id)
  end
end
