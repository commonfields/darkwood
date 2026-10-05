defmodule DarkwoodWeb.SignalIngestController do
  @moduledoc """
  Signal-first ingest: accepts raw evidence with no incident reference.

  POST /api/v1/ingest
  Accepts JSON: %{kind, level, message, metadata?, fingerprint?, occurred_at?}

  Unlike `POST /api/v1/incidents/:id/ingest`, the caller does not need to know
  which incident a signal belongs to — or that an incident exists yet. The
  detector routes it: it may open a new incident, join an open one, or persist
  the signal unrouted while it stays below threshold.

  Responses:

    * `201` — a new incident was opened for this signal
    * `200` — the signal was attached to an existing incident
    * `202` — the signal is durable but below threshold and currently unrouted
    * `401` / `429` / `422` — boundary and validation failures

  `202` here still means the signal is committed to PostgreSQL, never merely
  queued. Detection is synchronous and there is no queue behind it.
  """
  use DarkwoodWeb, :controller

  alias Darkwood.Detection

  def create(conn, params) do
    with :ok <- DarkwoodWeb.ApiAuth.check(conn) do
      attrs = %{
        "kind" => params["kind"],
        "level" => params["level"],
        "message" => params["message"],
        "metadata" => metadata_param(params),
        "fingerprint" => params["fingerprint"],
        "occurred_at" => params["occurred_at"]
      }

      case Detection.ingest_signal(attrs) do
        {:ok, %{outcome: :opened, incident: incident, signal: signal}} ->
          conn
          |> put_status(:created)
          |> json(%{
            status: "incident_opened",
            incident_id: incident.id,
            incident_title: incident.title,
            severity: incident.severity,
            signal_id: signal.id
          })

        {:ok, %{outcome: :joined, incident: incident, signal: signal, claimed: claimed}} ->
          conn
          |> put_status(:ok)
          |> json(%{
            status: "attached",
            incident_id: incident.id,
            signal_id: signal.id,
            claimed_signals: claimed
          })

        {:ok, %{outcome: :unrouted, signal: signal}} ->
          conn
          |> put_status(:accepted)
          |> json(%{
            status: "accepted",
            signal_id: signal.id,
            below_threshold: true
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: changeset_detail(changeset)}})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{errors: %{detail: "Invalid API key"}})

      {:error, :throttled} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "Rate limit exceeded"}})
    end
  end

  # Default only on missing/nil so invalid types still fail validation.
  defp metadata_param(params) do
    case Map.fetch(params, "metadata") do
      :error -> %{}
      {:ok, nil} -> %{}
      {:ok, value} -> value
    end
  end

  defp changeset_detail(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.find_value("is invalid", fn {_field, messages} -> List.first(messages) end)
  end
end
