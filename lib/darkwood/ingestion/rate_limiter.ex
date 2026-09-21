defmodule Darkwood.Ingestion.RateLimiter do
  @moduledoc """
  Minimal fixed-window rate limiter for the ingest API.
  120 requests/minute per client IP (burst-tolerant).
  Window starts on the first request after expiry; increments within
  a live window are atomic via `:ets.update_counter/3`.
  """
  use GenServer

  @table __MODULE__
  @limit 120
  @window_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def check(ip) when is_binary(ip) do
    now = System.monotonic_time(:millisecond)

    try do
      case :ets.lookup(@table, ip) do
        [{^ip, _count, window_start}] when now - window_start < @window_ms ->
          # Atomic increment; races on lookup+insert may under-count by one,
          # which fail-opens a single request rather than dropping valid ones.
          new_count = :ets.update_counter(@table, ip, {2, 1})

          if new_count > @limit do
            {:error, :throttled}
          else
            :ok
          end

        _ ->
          :ets.insert(@table, {ip, 1, now})
          :ok
      end
    rescue
      ArgumentError ->
        # Table missing (not started) or key reaped between lookup and
        # increment — fail open for availability, matching previous behavior.
        try do
          :ets.insert(@table, {ip, 1, now})
        rescue
          _ -> :ok
        end

        :ok
    end
  end

  def check(_), do: :ok

  @doc "Clears all rate-limit buckets. Intended for test isolation."
  def reset do
    try do
      :ets.delete_all_objects(@table)
      :ok
    rescue
      _ -> :ok
    end
  end

  @doc "Clears the bucket for a single key. Intended for test isolation."
  def reset_key(ip) when is_binary(ip) do
    try do
      :ets.delete(@table, ip)
      :ok
    rescue
      _ -> :ok
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    # Opportunistic cleanup every window.
    :timer.send_interval(@window_ms, :prune)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.monotonic_time(:millisecond)

    try do
      :ets.select_delete(@table, [{{:"$1", :"$2", :"$3"}, [{:<, :"$3", now - @window_ms}], [true]}])
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end
end
