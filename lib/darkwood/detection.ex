defmodule Darkwood.Detection do
  @moduledoc """
  Signal-first detection: turns raw signals into incidents.

  `POST /api/v1/incidents/:id/ingest` requires an incident to exist before
  evidence can be attached, which inverts how a pager works — you detect a
  problem *and then* name it. This module inverts that: a signal arrives with
  no incident reference, and the grouper decides whether it opens a new
  incident or joins an open one.

  ## Rules

  Two stateless rules, deliberately. Both need no learned baseline, so both are
  testable without historical data.

    * **Novel signature** — a fingerprint that has never been observed before
      opens an incident, but only at `warning` or `error` level. A new
      `info` line is not an incident.
    * **Rate spike** — the number of signals sharing a fingerprint inside the
      detection window reaches the spike threshold. Severity escalates with
      overshoot.

  A third rule, **error ratio**, is intentionally absent: it needs a learned
  baseline per route, which is a materially different problem.

  ## Grouping

  Signals carry a normalized fingerprint, not a byte-exact message. Before
  opening a second incident the grouper looks for an open incident already
  tracking the same signature and attaches to it instead. Signals that arrived
  below threshold are unrouted and are claimed when the threshold is crossed,
  so the buildup is preserved rather than orphaned.

  ## Invariants

  Ingest stays synchronous and durable: the signal is committed before any
  broadcast, and a detection failure never loses the signal. Detection is
  deliberately not doing error-ratio or auto-remediation, and must not write
  incident status.
  """

  import Ecto.Query
  require Logger

  alias Darkwood.Repo
  alias Darkwood.Detection.Fingerprint
  alias Darkwood.Incidents
  alias Darkwood.Incidents.{Incident, IncidentEvent}

  @default_window_seconds 300
  @default_spike_threshold 5
  @open_statuses [:investigating, :identified, :mitigated]
  @notifying_levels ["warning", "error"]
  @lock_namespace 4_112_001

  @doc "Length of the sliding window used by the rate-spike rule, in seconds."
  def window_seconds do
    :darkwood
    |> Application.get_env(:detection, [])
    |> Keyword.get(:window_seconds, @default_window_seconds)
  end

  @doc "Number of same-fingerprint signals inside the window that opens an incident."
  def spike_threshold do
    :darkwood
    |> Application.get_env(:detection, [])
    |> Keyword.get(:spike_threshold, @default_spike_threshold)
  end

  @doc """
  Ingests one raw signal and routes it.

  Returns `{:ok, %{signal: event, incident: incident | nil, outcome: atom}}`
  where `outcome` is one of:

    * `:opened` — this signal created a new incident
    * `:joined` — this signal joined an open incident for the same signature
    * `:unrouted` — below threshold; persisted without an incident and claimed
      later if the threshold is crossed

  On validation failure returns `{:error, %Ecto.Changeset{}}`.
  """
  def ingest_signal(attrs) when is_map(attrs) do
    kind = attrs["kind"] || attrs[:kind]
    level = attrs["level"] || attrs[:level]
    message = attrs["message"] || attrs[:message]
    metadata = Incidents.normalize_ingest_metadata_value(attrs)
    fingerprint = resolve_fingerprint(attrs, kind, message)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    now_iso = DateTime.to_iso8601(now)

    with :ok <- Incidents.validate_ingest(kind, level, message, metadata, fingerprint),
         {:ok, occurred_at} <- Incidents.parse_occurred_at(attrs, now) do
      attrs = %{
        kind: kind,
        level: level,
        message: message,
        metadata: metadata,
        fingerprint: fingerprint,
        occurred_at: occurred_at,
        now: now,
        now_iso: now_iso
      }

      route_signal(attrs)
    end
  end

  defp resolve_fingerprint(attrs, kind, message) do
    case attrs["fingerprint"] || attrs[:fingerprint] do
      nil -> Fingerprint.compute(kind, message)
      "" -> Fingerprint.compute(kind, message)
      fp -> to_string(fp)
    end
  end

  defp route_signal(%{fingerprint: fingerprint} = attrs) do
    # Serialize concurrent signals for the same fingerprint so the
    # open/join decision and the claim of prior unrouted signals are atomic.
    # Transaction-scoped advisory lock.
    lock_key = :erlang.phash2(fingerprint)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, lock_key])

        case open_incident_for(fingerprint) do
          %Incident{} = incident ->
            # An incident is already tracking this signature, so this signal is
            # the same ongoing problem rather than a new one. Attach instead
            # of opening a duplicate.
            claimed = claim_unrouted(fingerprint, incident.id)

            case insert_signal(attrs, incident.id) do
              {:ok, signal} -> {:joined, incident, signal, claimed}
              {:error, _} = err -> Repo.rollback(err)
            end

          nil ->
            if should_open?(fingerprint, attrs) do
              open_and_attach(attrs)
            else
              # Below threshold. Persist unrouted so the buildup is available
              # if the threshold is crossed moments later.
              case insert_signal(attrs, nil) do
                {:ok, signal} -> {:unrouted, nil, signal, 0}
                {:error, _} = err -> Repo.rollback(err)
              end
            end
        end
      end)

    case result do
      {:ok, {outcome, incident, signal, claimed}} ->
        broadcast(outcome, incident, signal)
        {:ok, %{signal: signal, incident: incident, outcome: outcome, claimed: claimed}}

      {:error, {:error, _} = err} ->
        err

      {:error, _} = err ->
        err
    end
  end

  defp open_and_attach(attrs) do
    %{fingerprint: fingerprint} = attrs

    case insert_incident_for(attrs) do
      {:ok, incident} ->
        claimed = claim_unrouted(fingerprint, incident.id)

        case insert_signal(attrs, incident.id) do
          {:ok, signal} -> {:opened, incident, signal, claimed}
          {:error, _} = err -> Repo.rollback(err)
        end

      {:error, _} = err ->
        Repo.rollback(err)
    end
  end

  defp should_open?(fingerprint, %{level: level, now: now}) do
    novel_signature?(fingerprint, level) or rate_spike?(fingerprint, now)
  end

  # A fingerprint we have never seen is novel, but only noisy enough to matter.
  defp novel_signature?(fingerprint, level) do
    to_string(level) in @notifying_levels and
      not Repo.exists?(from s in IncidentEvent, where: s.fingerprint == ^fingerprint)
  end

  defp rate_spike?(fingerprint, now) do
    cutoff = DateTime.add(now, -window_seconds(), :second)

    Repo.one(
      from s in IncidentEvent,
        where: s.fingerprint == ^fingerprint and s.inserted_at >= ^cutoff,
        select: count(s.id)
    ) >= spike_threshold()
  end

  defp open_incident_for(fingerprint) do
    Repo.one(
      from i in Incident,
        where: i.signature == ^fingerprint and i.status in ^@open_statuses,
        order_by: [desc: i.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  # Attach every previously unrouted signal for this fingerprint so the
  # buildup that justified opening the incident is not orphaned.
  defp claim_unrouted(fingerprint, incident_id) do
    {count, _} =
      Repo.update_all(
        from(s in IncidentEvent,
          where: is_nil(s.incident_id) and s.fingerprint == ^fingerprint
        ),
        set: [incident_id: incident_id, updated_at: DateTime.utc_now()]
      )

    count
  end

  defp insert_incident_for(%{fingerprint: fingerprint, kind: kind, level: level} = attrs) do
    template = Fingerprint.template(attrs.message)
    now = attrs.now
    cutoff = DateTime.add(now, -window_seconds(), :second)

    occurrences =
      Repo.one(
        from s in IncidentEvent,
          where: s.fingerprint == ^fingerprint and s.inserted_at >= ^cutoff,
          select: count(s.id)
      )

    %Incident{}
    |> Incident.changeset(%{
      title: title_for(template, level),
      summary: summary_for(template, kind, occurrences),
      severity: severity_for(level, occurrences),
      status: :investigating
    })
    |> Ecto.Changeset.put_change(:signature, fingerprint)
    |> Repo.insert()
  end

  defp insert_signal(attrs, incident_id) do
    %IncidentEvent{}
    |> IncidentEvent.changeset(%{
      kind: attrs.kind,
      level: attrs.level,
      message: attrs.message,
      fingerprint: attrs.fingerprint,
      occurred_at: attrs.occurred_at,
      metadata: %{
        "count" => 1,
        "first_seen" => attrs.now_iso,
        "last_seen" => attrs.now_iso
      }
    })
    |> Ecto.Changeset.put_change(:incident_id, incident_id)
    |> Repo.insert()
  end

  # Titles are user-visible and bounded to 3..120 characters by the changeset.
  defp title_for(template, level) do
    base = template |> String.slice(0, 110) |> String.trim()

    if String.length(base) < 3,
      do: "auto-detected #{level} signal",
      else: base
  end

  # Summaries are bounded to 2000 characters by the changeset, and the template
  # can be as long as the source message, so it must be truncated or the insert
  # would fail validation and roll back the signal.
  defp summary_for(template, kind, occurrences) do
    normalized = template |> String.slice(0, 400) |> String.trim()

    "Detected automatically by Darkwood. #{occurrences + 1} #{kind} signal(s) " <>
      "sharing one normalized signature. Signature: #{normalized}"
  end

  # Escalate on overshoot: a spike far past the threshold is not the same event
  # as one that merely crossed it.
  defp severity_for(level, occurrences) do
    cond do
      to_string(level) == "error" and occurrences >= spike_threshold() * 4 -> :critical
      to_string(level) == "error" -> :major
      true -> :minor
    end
  end

  # Persist first, broadcast second. A detection failure must never lose a
  # signal, and a broadcast failure must never fail the ingest.
  defp broadcast(:unrouted, _incident, _signal), do: :ok

  defp broadcast(outcome, incident, signal) do
    # Auto-opened incidents must appear on the index without a reload.
    if outcome == :opened do
      Phoenix.PubSub.broadcast(
        Darkwood.PubSub,
        Incidents.incidents_topic(),
        {:incident_created, incident}
      )
    end

    Incidents.broadcast(incident.id, {:event_created, signal})
    :ok
  end
end
