defmodule Darkwood.Incidents do
  import Ecto.Query
  require Logger
  alias Ecto.Multi
  alias Darkwood.Repo
  alias Darkwood.Incidents.{Annotation, Incident, IncidentEvent}

  @sample_title "Checkout API 500 spike"

  @max_incidents 100
  @max_events 500
  @max_annotations 500
  @max_message_length 5000
  @max_metadata_keys 50
  @max_metadata_bytes 32_768
  @max_fingerprint_length 128

  def list_incidents(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_incidents) |> clamp_limit(@max_incidents)
    Repo.all(from i in Incident, order_by: [desc: i.inserted_at], limit: ^limit)
  end

  def get_incident!(id), do: Repo.get!(Incident, id)

  def get_incident_with_events(id) do
    case Repo.get(Incident, id) do
      nil ->
        nil

      incident ->
        # Newest N events (bounded read), presented oldest-first for the timeline.
        incident =
          Repo.preload(incident,
            events:
              from(e in IncidentEvent,
                order_by: [desc: e.occurred_at, desc: e.id],
                limit: @max_events
              )
          )

        %{incident | events: sort_events_asc(incident.events)}
    end
  end

  def get_incident_with_events!(id) do
    case get_incident_with_events(id) do
      nil -> raise Ecto.NoResultsError, queryable: Incident
      incident -> incident
    end
  end

  defp clamp_limit(n, max) when is_integer(n) and n > 0, do: min(n, max)
  defp clamp_limit(_, max), do: max

  defp sort_events_asc(events) do
    Enum.sort(events, fn a, b ->
      case DateTime.compare(a.occurred_at, b.occurred_at) do
        :lt -> true
        :gt -> false
        :eq -> a.id <= b.id
      end
    end)
  end

  def change_incident(incident \\ %Incident{}, attrs \\ %{}) do
    Incident.changeset(incident, attrs)
  end

  def create_incident(attrs) do
    case %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      {:ok, incident} ->
        broadcast(Darkwood.PubSub, incidents_topic(), {:incident_created, incident})
        {:ok, incident}

      error ->
        error
    end
  end

  def incidents_topic, do: "incidents"
  def subscribe_incidents, do: Phoenix.PubSub.subscribe(Darkwood.PubSub, incidents_topic())

  def list_events(incident_or_id, opts \\ [])
  def list_events(%Incident{id: id}, opts), do: list_events(id, opts)

  def list_events(id, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @max_events) |> clamp_limit(@max_events)

    # Newest N events (bounded read), presented oldest-first for the timeline.
    from(e in IncidentEvent,
      where: e.incident_id == ^id,
      order_by: [desc: e.occurred_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
    |> sort_events_asc()
  end

  def list_annotations(incident_or_id, opts \\ [])
  def list_annotations(%Incident{id: id}, opts), do: list_annotations(id, opts)

  def list_annotations(id, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @max_annotations) |> clamp_limit(@max_annotations)

    # Newest N annotations (bounded read), presented oldest-first.
    from(a in Annotation,
      where: a.incident_id == ^id,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [:event]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  def change_annotation(attrs \\ %{}), do: Annotation.changeset(%Annotation{}, attrs)

  def create_annotation(%Incident{} = incident, attrs) do
    event_id = attrs["event_id"] || attrs[:event_id]

    with :ok <- event_belongs_to_incident(event_id, incident.id),
         {:ok, annotation} <-
           %Annotation{
             incident_id: incident.id,
             author_name: attrs["author_name"] || attrs[:author_name]
           }
           |> Annotation.changeset(attrs)
           |> Repo.insert() do
      broadcast(incident.id, {:annotation_created, annotation})
      {:ok, annotation}
    end
  end

  def update_incident_status(%Incident{} = incident, status) do
    case incident |> Incident.status_changeset(%{status: status}) |> Repo.update() do
      {:ok, updated} ->
        broadcast(updated.id, {:incident_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @aggregation_window_seconds 5

  def aggregation_window_seconds, do: @aggregation_window_seconds

  def ingest_event(%Incident{id: id}, attrs), do: ingest_event(id, attrs)

  def ingest_event(incident_id, attrs) when is_binary(incident_id) do
    case Integer.parse(incident_id) do
      {parsed, ""} -> ingest_event(parsed, attrs)
      _ -> {:error, :not_found}
    end
  end

  def ingest_event(incident_id, attrs) when is_integer(incident_id) do
    case Repo.get(Incident, incident_id) do
      nil -> {:error, :not_found}
      %Incident{} -> do_ingest(incident_id, attrs)
    end
  end

  defp do_ingest(incident_id, attrs) when is_map(attrs) do
    kind = attrs["kind"] || attrs[:kind]
    level = attrs["level"] || attrs[:level]
    message = attrs["message"] || attrs[:message]
    user_metadata = normalize_ingest_metadata(attrs)
    fingerprint = normalize_fingerprint(attrs, kind, message)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    now_iso = DateTime.to_iso8601(now)
    cutoff = DateTime.add(now, -@aggregation_window_seconds, :second)

    with :ok <- validate_ingest_fields(kind, level, message, user_metadata, fingerprint),
         {:ok, occurred_at} <- parse_occurred_at(attrs, now) do
      # Serialize concurrent ingests for the same incident+fingerprint so the
      # 5s dedup check + increment is atomic. Transaction-scoped advisory lock.
      # Persist first, broadcast second (after commit).
      lock_key = :erlang.phash2({incident_id, fingerprint})

      transaction_result =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [incident_id, lock_key])

          case recent_event(incident_id, fingerprint, cutoff) do
            %IncidentEvent{} = existing ->
              case aggregate_existing(existing, now_iso) do
                {:ok, updated} -> {:aggregated, updated}
                {:error, _} = err -> Repo.rollback(err)
              end

            nil ->
              case insert_ingested(incident_id, kind, level, message, fingerprint, occurred_at, user_metadata, now_iso) do
                {:ok, event} -> {:inserted, event}
                {:error, _} = err -> Repo.rollback(err)
              end
          end
        end)

      case transaction_result do
        {:ok, {:aggregated, event}} ->
          broadcast(incident_id, {:event_updated, event})
          {:ok, event}

        {:ok, {:inserted, event}} ->
          broadcast(incident_id, {:event_created, event})
          {:ok, event}

        # Inner function only returns {:aggregated,_}/{:inserted,_} or
        # rolls back, so success-with-error is unreachable; rollback
        # surfaces here.
        {:error, {:error, _} = err} ->
          err

        {:error, _} = err ->
          err
      end
    end
  end

  defp validate_ingest_fields(kind, level, message, metadata, fingerprint) do
    kinds = ~w(request query http log error)
    levels = ~w(info warning error)

    cond do
      is_nil(message) or (is_binary(message) and String.trim(message) == "") ->
        {:error, invalid_ingest_changeset(:message, "can't be blank")}

      is_binary(message) and String.length(message) > @max_message_length ->
        {:error, invalid_ingest_changeset(:message, "is too long")}

      to_string(kind || "") not in kinds ->
        {:error, invalid_ingest_changeset(:kind, "is invalid")}

      to_string(level || "") not in levels ->
        {:error, invalid_ingest_changeset(:level, "is invalid")}

      not is_map(metadata) ->
        {:error, invalid_ingest_changeset(:metadata, "is invalid")}

      map_size(metadata) > @max_metadata_keys ->
        {:error, invalid_ingest_changeset(:metadata, "has too many keys")}

      metadata_too_large?(metadata) ->
        {:error, invalid_ingest_changeset(:metadata, "is too large")}

      not is_nil(fingerprint) and String.length(to_string(fingerprint)) > @max_fingerprint_length ->
        {:error, invalid_ingest_changeset(:fingerprint, "is too long")}

      true ->
        :ok
    end
  end

  # Fail closed: a supplied timestamp must parse and fall within the
  # acceptance window (5min future skew, 30d retention). Anything else is
  # a validation error — never silently replaced with `now`.
  defp parse_occurred_at(attrs, now) do
    case attrs["occurred_at"] || attrs[:occurred_at] do
      nil ->
        {:ok, DateTime.truncate(now, :microsecond)}

      %DateTime{} = dt ->
        check_occurred_at_bounds(DateTime.truncate(dt, :microsecond), now)

      bin when is_binary(bin) ->
        case DateTime.from_iso8601(bin) do
          {:ok, dt, _} -> check_occurred_at_bounds(DateTime.truncate(dt, :microsecond), now)
          _ -> {:error, invalid_ingest_changeset(:occurred_at, "is invalid")}
        end

      _ ->
        {:error, invalid_ingest_changeset(:occurred_at, "is invalid")}
    end
  end

  defp check_occurred_at_bounds(dt, now) do
    if DateTime.compare(dt, DateTime.add(now, 300, :second)) != :gt and
         DateTime.compare(dt, DateTime.add(now, -30 * 24 * 3600, :second)) != :lt do
      {:ok, dt}
    else
      {:error, invalid_ingest_changeset(:occurred_at, "is out of range")}
    end
  end

  defp invalid_ingest_changeset(field, message) do
    %IncidentEvent{}
    |> Ecto.Changeset.cast(%{}, [])
    |> Ecto.Changeset.add_error(field, message)
  end

  defp metadata_too_large?(metadata) do
    try do
      :erlang.external_size(metadata) > @max_metadata_bytes
    rescue
      _ -> true
    end
  end

  defp recent_event(incident_id, fingerprint, cutoff) do
    Repo.one(
      from e in IncidentEvent,
        where: e.incident_id == ^incident_id and e.fingerprint == ^fingerprint,
        where: e.inserted_at >= ^cutoff,
        order_by: [desc: e.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp aggregate_existing(%IncidentEvent{} = existing, now_iso) do
    meta = existing.metadata || %{}
    current = meta["count"] || meta[:count] || 1

    first_seen =
      meta["first_seen"] || meta[:first_seen] ||
        DateTime.to_iso8601(existing.inserted_at)

    updated_metadata =
      meta
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{
        "count" => current + 1,
        "first_seen" => first_seen,
        "last_seen" => now_iso
      })

    existing |> IncidentEvent.changeset(%{metadata: updated_metadata}) |> Repo.update()
  end

  defp insert_ingested(incident_id, kind, level, message, fingerprint, occurred_at, user_metadata, now_iso) do
    full_metadata =
      user_metadata
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{
        "count" => 1,
        "first_seen" => now_iso,
        "last_seen" => now_iso
      })

    attrs = %{
      kind: kind,
      level: level,
      message: message,
      fingerprint: fingerprint,
      occurred_at: occurred_at,
      metadata: full_metadata
    }

    case %IncidentEvent{incident_id: incident_id} |> IncidentEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} -> {:ok, event}
      error -> error
    end
  end

  defp normalize_ingest_metadata(attrs) do
    case attrs["metadata"] || attrs[:metadata] do
      nil -> %{}
      %{} = meta -> meta
      # Preserve invalid values so validate_ingest_fields/5 can reject
      # them instead of silently coercing to %{}.
      other -> other
    end
  end

  defp normalize_fingerprint(attrs, kind, message) do
    case attrs["fingerprint"] || attrs[:fingerprint] do
      nil -> compute_fingerprint(kind, message)
      "" -> compute_fingerprint(kind, message)
      fp -> to_string(fp)
    end
  end

  def compute_fingerprint(kind, message) do
    :crypto.hash(:sha256, "#{to_string(kind)}:#{to_string(message)}")
    |> Base.encode16(case: :lower)
  end

  def topic(id), do: "incident:#{id}"
  def subscribe(id), do: Phoenix.PubSub.subscribe(Darkwood.PubSub, topic(id))

  def create_sample_incident do
    case Repo.get_by(Incident, title: @sample_title) do
      %Incident{} = incident -> {:ok, incident}
      nil -> insert_sample()
    end
  end

  defp insert_sample do
    base = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:microsecond)

    incident =
      Incident.changeset(%Incident{}, %{
        title: @sample_title,
        summary:
          "Elevated checkout failures traced across request, database, and payment upstream boundaries.",
        severity: :critical
      })

    events = [
      %{
        occurred_at: base,
        kind: :request,
        level: :info,
        message: "Checkout request volume crossed alert threshold",
        metadata: %{route: "/api/checkout", rate_per_minute: 184}
      },
      %{
        occurred_at: DateTime.add(base, 45),
        kind: :query,
        level: :warning,
        message: "Inventory reservation query latency increased",
        metadata: %{duration_ms: 842, operation: "reserve_inventory"}
      },
      %{
        occurred_at: DateTime.add(base, 83),
        kind: :query,
        level: :warning,
        message: "Connection pool wait exceeded budget",
        metadata: %{wait_ms: 510, pool: "primary"}
      },
      %{
        occurred_at: DateTime.add(base, 121),
        kind: :http,
        level: :error,
        message: "Payment provider returned upstream 503",
        metadata: %{status: 503, service: "payment-gateway"}
      },
      %{
        occurred_at: DateTime.add(base, 128),
        kind: :error,
        level: :error,
        message: "Checkout API response failed with status 500",
        fingerprint: "checkout-500-upstream",
        metadata: %{route: "/api/checkout", status: 500}
      }
    ]

    Multi.new()
    |> Multi.insert(:incident, incident)
    |> Multi.run(:events, fn repo, %{incident: created} ->
      Enum.reduce_while(events, {:ok, []}, fn attrs, {:ok, acc} ->
        result =
          %IncidentEvent{incident_id: created.id}
          |> IncidentEvent.changeset(attrs)
          |> repo.insert()

        case result do
          {:ok, event} -> {:cont, {:ok, [event | acc]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{incident: incident}} ->
        {:ok, incident}

      {:error, :incident, _changeset, _changes} ->
        {:ok, Repo.get_by!(Incident, title: @sample_title)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp event_belongs_to_incident(nil, _incident_id), do: :ok
  defp event_belongs_to_incident("", _incident_id), do: :ok

  defp event_belongs_to_incident(event_id, incident_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {parsed, ""} -> event_belongs_to_incident(parsed, incident_id)
      _ -> {:error, :event_not_in_incident}
    end
  end

  defp event_belongs_to_incident(event_id, incident_id) when is_integer(event_id) do
    if Repo.exists?(
         from e in IncidentEvent, where: e.id == ^event_id and e.incident_id == ^incident_id
       ) do
      :ok
    else
      {:error, :event_not_in_incident}
    end
  end

  defp event_belongs_to_incident(_event_id, _incident_id), do: {:error, :event_not_in_incident}

  defp broadcast(id, message), do: broadcast(Darkwood.PubSub, topic(id), message)

  defp broadcast(pubsub, topic, message) do
    case Phoenix.PubSub.broadcast(pubsub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("PubSub broadcast to #{topic} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
