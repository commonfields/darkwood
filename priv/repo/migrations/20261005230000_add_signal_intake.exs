defmodule Darkwood.Repo.Migrations.AddSignalIntake do
  use Ecto.Migration

  def change do
    # Signal-first ingest: a signal may arrive before, or without, any incident.
    # The grouper decides whether it opens one or joins an open one. This is
    # what makes Darkwood a pager instead of a container a human must create
    # before evidence can be attached.
    alter table(:incident_events) do
      modify :incident_id, references(:incidents, on_delete: :delete_all), null: true
    end

    # The fingerprint that opened an incident, so a repeat signal can be routed
    # to the open incident it belongs to instead of opening a duplicate.
    alter table(:incidents) do
      add :signature, :string
    end

    create index(:incidents, [:signature])
    create index(:incidents, [:signature, :status])

    # Detection counts signals per fingerprint across ALL incidents, including
    # unrouted ones. The existing dedup index is incident-scoped and therefore
    # unusable for that query.
    create index(:incident_events, [:fingerprint, :inserted_at])
  end
end
