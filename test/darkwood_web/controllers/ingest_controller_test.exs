defmodule DarkwoodWeb.IngestControllerTest do
  use DarkwoodWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Darkwood.Incidents
  alias Darkwood.Ingestion.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "POST returns 202 only after the event is durable", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API ingest test"})

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "error",
        level: "error",
        message: "external boom",
        metadata: %{service: "worker"}
      })

    assert json_response(conn, 202)["status"] == "accepted"

    # Synchronous durability: no polling — the row must exist immediately.
    assert [%{message: "external boom"}] = Incidents.list_events(incident.id)
  end

  test "deduplicated ingestion is durable when the request succeeds", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API dedup test"})
    payload = %{kind: "error", level: "error", message: "dup", metadata: %{}}
    path = ~p"/api/v1/incidents/#{incident.id}/ingest"

    assert %{"status" => "accepted"} = conn |> post(path, payload) |> json_response(202)
    assert %{"status" => "accepted"} = recycle(conn) |> post(path, payload) |> json_response(202)

    assert [event] = Incidents.list_events(incident.id)
    assert event.metadata["count"] == 2
  end

  test "malformed occurred_at is rejected and persists nothing", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API bad timestamp test"})

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "error",
        level: "error",
        message: "bad time",
        occurred_at: "not-a-timestamp"
      })

    assert json_response(conn, 422)
    assert Incidents.list_events(incident.id) == []
  end

  test "out-of-range occurred_at does not return success", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API future timestamp test"})

    future = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "error",
        level: "error",
        message: "from the future",
        occurred_at: future
      })

    assert json_response(conn, 422)
    assert Incidents.list_events(incident.id) == []
  end

  test "invalid payload returns 422", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "API invalid test"})

    conn =
      post(conn, ~p"/api/v1/incidents/#{incident.id}/ingest", %{
        kind: "nope",
        level: "error",
        message: "x"
      })

    assert json_response(conn, 422)
  end

  test "unknown incident returns 404", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/incidents/999999/ingest", %{
        kind: "error",
        level: "error",
        message: "ghost"
      })

    assert json_response(conn, 404)
  end

  test "high-volume identical payloads aggregate and LiveView stays responsive", %{conn: conn} do
    {:ok, incident} = Incidents.create_incident(%{title: "Flood API test"})
    payload = %{kind: "error", level: "error", message: "flood", metadata: %{}}
    path = ~p"/api/v1/incidents/#{incident.id}/ingest"

    for _ <- 1..100 do
      assert %{"status" => "accepted"} = recycle(conn) |> post(path, payload) |> json_response(202)
    end

    # Durable and aggregated synchronously — no waiting.
    events = Incidents.list_events(incident.id)
    assert length(events) in 1..5
    assert hd(events).metadata["count"] != nil

    joined = init_test_session(conn, %{"display_name" => "Alice", "client_id" => Ecto.UUID.generate()})
    {:ok, view, _html} = live(joined, ~p"/incidents/#{incident}")
    assert has_element?(view, "#event-timeline")
    assert has_element?(view, "#annotations")
  end
end
