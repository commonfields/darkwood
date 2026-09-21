defmodule DarkwoodWeb.IngestController do
  @moduledoc """
  Synchronous ingestion API for external log/error payloads.

  POST /api/v1/incidents/:id/ingest
  Accepts JSON: %{kind, level, message, metadata?, fingerprint?, occurred_at?}
  Persists (or atomically aggregates) the event in PostgreSQL before
  responding. `202` means the evidence is durable and accepted for
  downstream processing — never merely queued.
  """
  use DarkwoodWeb, :controller

  alias Darkwood.Incidents
  alias Darkwood.Incidents.Incident
  alias Darkwood.Repo

  @kinds ~w(request query http log error)
  @levels ~w(info warning error)

  def create(conn, %{"id" => id} = params) do
    with :ok <- check_auth(conn),
         :ok <- check_rate_limit(conn) do
      case safe_get(id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "Incident not found"}})

        %Incident{id: incident_id} ->
          attrs = %{
            "kind" => params["kind"],
            "level" => params["level"],
            "message" => params["message"],
            # Default only on missing/nil so invalid types still fail validation.
            "metadata" => ingest_metadata(params),
            "fingerprint" => params["fingerprint"],
            "occurred_at" => params["occurred_at"]
          }

          case validate(attrs) do
            :ok ->
              # Durable boundary: success is returned only after the event
              # (or its aggregation) commits. Any error tuple or raised
              # transaction failure must never produce a success response.
              case Incidents.ingest_event(incident_id, attrs) do
                {:ok, _event} ->
                  conn
                  |> put_status(:accepted)
                  |> json(%{status: "accepted", incident_id: incident_id})

                {:error, :not_found} ->
                  conn
                  |> put_status(:not_found)
                  |> json(%{errors: %{detail: "Incident not found"}})

                {:error, %Ecto.Changeset{} = changeset} ->
                  conn
                  |> put_status(:unprocessable_entity)
                  |> json(%{errors: %{detail: changeset_detail(changeset)}})
              end

            {:error, detail} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: %{detail: detail}})
          end
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

  defp check_auth(conn) do
    case Application.get_env(:darkwood, :ingest_api_key) do
      nil -> :ok
      "" -> :ok
      expected -> if valid_key?(conn, expected), do: :ok, else: {:error, :unauthorized}
    end
  end

  defp valid_key?(conn, expected) do
    provided =
      conn |> get_req_header("x-api-key") |> List.first() ||
        bearer_token(conn) || conn.params["api_key"]

    is_binary(provided) and Plug.Crypto.secure_compare(provided, expected)
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp check_rate_limit(conn) do
    ip = conn.remote_ip |> Tuple.to_list() |> Enum.join(".")
    Darkwood.Ingestion.RateLimiter.check(ip)
  rescue
    _ -> :ok
  end

  defp safe_get(id) do
    Repo.get(Incident, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp ingest_metadata(params) do
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

  defp metadata_too_large?(metadata) when is_map(metadata) do
    try do
      :erlang.external_size(metadata) > 32_768
    rescue
      _ -> true
    end
  end

  defp metadata_too_large?(_), do: false

  defp validate(%{"kind" => kind, "level" => level, "message" => message, "metadata" => metadata} = attrs) do
    cond do
      is_nil(message) or (is_binary(message) and String.trim(message) == "") ->
        {:error, "message can't be blank"}

      is_binary(message) and String.length(message) > 5000 ->
        {:error, "message is too long"}

      to_string(kind || "") not in @kinds ->
        {:error, "kind is invalid"}

      to_string(level || "") not in @levels ->
        {:error, "level is invalid"}

      not is_map(metadata) ->
        {:error, "metadata is invalid"}

      map_size(metadata) > 50 ->
        {:error, "metadata has too many keys"}

      metadata_too_large?(metadata) ->
        {:error, "metadata is too large"}

      (attrs["fingerprint"] || "") != "" and String.length(to_string(attrs["fingerprint"] || "")) > 128 ->
        {:error, "fingerprint is too long"}

      true ->
        :ok
    end
  end
end
