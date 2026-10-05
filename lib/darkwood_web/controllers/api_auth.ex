defmodule DarkwoodWeb.ApiAuth do
  @moduledoc """
  Shared API-key authentication and rate limiting for the ingest endpoints.

  Both `POST /api/v1/ingest` and `POST /api/v1/incidents/:id/ingest` must apply
  identical boundary checks, so the logic lives here rather than being
  duplicated per controller.

  ## Known boundary weaknesses (unfixed — tracked as Phase A)

  This module is an extraction of the existing controller logic and
  deliberately preserves current behaviour. It does **not** fix any of these:

    * An unset or empty `:ingest_api_key` authenticates everything. Nothing
      fails closed at boot in prod.
    * A key supplied as the `api_key` query parameter is accepted, which leaks
      it into access logs and `Referer` headers.
    * The rate limiter rescues every error and returns `:ok`, so it fails open.
    * The limiter is keyed on IP and held in per-node ETS. Behind any
      load-balancer every client shares one bucket.

  Auth is additionally untestable as written because `config/test.exs` does not
  set `:ingest_api_key`, so `check_auth/1` short-circuits to `:ok` in the whole
  suite.
  """

  @doc """
  Runs the boundary checks in order: API key, then rate limit.

  Returns `:ok`, `{:error, :unauthorized}`, or `{:error, :throttled}`.
  """
  def check(conn) do
    with :ok <- check_auth(conn) do
      check_rate_limit(conn)
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
end
