defmodule DarkwoodWeb.SignalIngestControllerTest do
  use DarkwoodWeb.ConnCase, async: false

  alias Darkwood.Repo
  alias Darkwood.Incidents.{Incident, IncidentEvent}

  defp payload(overrides) do
    Map.merge(
      %{"kind" => "error", "level" => "error", "message" => "checkout 500 from stripe"},
      overrides
    )
  end

  defp count_incidents, do: Repo.aggregate(Incident, :count)
  defp count_signals, do: Repo.aggregate(IncidentEvent, :count)

  describe "POST /api/v1/ingest" do
    test "opens an incident and returns 201", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/ingest", payload(%{}))

      assert %{"status" => "incident_opened", "incident_id" => id} = json_response(conn, 201)
      assert is_integer(id)
      assert Repo.get(Incident, id)
    end

    test "attaches a repeat signal and returns 200", %{conn: conn} do
      post(conn, ~p"/api/v1/ingest", payload(%{}))
      conn = post(conn, ~p"/api/v1/ingest", payload(%{}))

      assert %{"status" => "attached", "incident_id" => _id} = json_response(conn, 200)
      assert count_incidents() == 1
    end

    test "returns 202 and stays unrouted below threshold", %{conn: conn} do
      conn =
        post(
          conn,
          ~p"/api/v1/ingest",
          payload(%{"kind" => "log", "level" => "info", "message" => "nothing to see"})
        )

      assert %{"status" => "accepted", "below_threshold" => true} = json_response(conn, 202)
      assert count_incidents() == 0
      # Still durable: the signal is committed even though no incident exists.
      assert count_signals() == 1
    end

    test "groups messages that differ only by a variable", %{conn: conn} do
      post(conn, ~p"/api/v1/ingest", payload(%{"message" => "timeout after 100ms"}))
      conn = post(conn, ~p"/api/v1/ingest", payload(%{"message" => "timeout after 900ms"}))

      assert json_response(conn, 200)["status"] == "attached"
      assert count_incidents() == 1
    end

    test "rejects a blank message with 422", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/ingest", payload(%{"message" => ""}))

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
      assert count_incidents() == 0
    end

    test "rejects an unknown kind with 422", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/ingest", payload(%{"kind" => "telepathy"}))

      assert json_response(conn, 422)
      assert count_signals() == 0
    end

    test "rejects a malformed occurred_at with 422", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/ingest", payload(%{"occurred_at" => "not-a-date"}))

      assert json_response(conn, 422)
      assert count_signals() == 0
    end

    test "accepts a valid occurred_at", %{conn: conn} do
      occurred_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      conn = post(conn, ~p"/api/v1/ingest", payload(%{"occurred_at" => occurred_at}))

      assert json_response(conn, 201)
    end

    test "does not require an incident to exist", %{conn: conn} do
      # No incident exists; the endpoint must not 404 looking for one.
      conn = post(conn, ~p"/api/v1/ingest", payload(%{}))

      refute conn.status == 404
      assert conn.status == 201
    end
  end
end
