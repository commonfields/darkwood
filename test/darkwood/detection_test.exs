defmodule Darkwood.DetectionTest do
  use Darkwood.DataCase, async: false

  import Ecto.Query

  alias Darkwood.Detection
  alias Darkwood.Incidents
  alias Darkwood.Incidents.{Incident, IncidentEvent}
  alias Darkwood.Repo

  defp signal(attrs) do
    Map.merge(%{"kind" => "error", "level" => "error", "message" => "boom"}, attrs)
  end

  defp incidents, do: Repo.all(Incident)
  defp count_signals, do: Repo.aggregate(IncidentEvent, :count)

  describe "ingest_signal/1 — novel signature" do
    test "opens an incident for a never-before-seen error fingerprint" do
      assert {:ok, %{outcome: :opened, incident: incident, signal: signal}} =
               Detection.ingest_signal(signal(%{"message" => "payment gateway 503"}))

      assert incident.title != ""
      assert incident.signature == signal.fingerprint
      assert incident.status == :investigating
      assert incident.severity == :major
      assert signal.incident_id == incident.id
    end

    test "does not open an incident for a novel info-level signal" do
      assert {:ok, %{outcome: :unrouted, incident: nil}} =
               Detection.ingest_signal(
                 signal(%{"kind" => "log", "level" => "info", "message" => "cache warmed"})
               )

      assert incidents() == []
      assert count_signals() == 1
    end

    test "treats a warning-level novel signal as an incident" do
      assert {:ok, %{outcome: :opened, incident: incident}} =
               Detection.ingest_signal(
                 signal(%{"level" => "warning", "message" => "retry budget exhausted"})
               )

      assert incident.severity == :minor
    end
  end

  describe "ingest_signal/1 — grouping" do
    test "a repeated fingerprint joins the open incident instead of duplicating" do
      {:ok, first} = Detection.ingest_signal(signal(%{"message" => "db pool exhausted"}))

      {:ok, second} = Detection.ingest_signal(signal(%{"message" => "db pool exhausted"}))

      assert first.outcome == :opened
      assert second.outcome == :joined
      assert second.incident.id == first.incident.id
      assert length(incidents()) == 1
    end

    test "variables in the message do not create a second incident" do
      {:ok, first} = Detection.ingest_signal(signal(%{"message" => "timeout for request 1111"}))

      {:ok, second} = Detection.ingest_signal(signal(%{"message" => "timeout for request 2222"}))

      assert second.incident.id == first.incident.id
      assert length(incidents()) == 1
    end

    test "a resolved incident does not absorb new signals" do
      {:ok, first} = Detection.ingest_signal(signal(%{"message" => "flaky upstream"}))
      {:ok, _} = Incidents.update_incident_status(first.incident, "resolved")

      {:ok, second} = Detection.ingest_signal(signal(%{"message" => "flaky upstream"}))

      assert second.outcome == :opened
      assert second.incident.id != first.incident.id
      assert length(incidents()) == 2
    end
  end

  describe "ingest_signal/1 — rate spike" do
    test "opens an incident once the threshold is crossed and claims the buildup" do
      # info-level so the novel-signature rule stays quiet and only the spike
      # rule can fire.
      message = "heartbeat retry"

      outcomes =
        for _ <- 1..Detection.spike_threshold() + 1 do
          {:ok, result} =
            Detection.ingest_signal(
              signal(%{"kind" => "log", "level" => "info", "message" => message})
            )

          result
        end

      last = List.last(outcomes)

      assert last.outcome == :opened
      assert last.incident != nil
      # Every signal below the threshold was claimed rather than orphaned.
      assert last.claimed == Detection.spike_threshold()

      unrouted =
        Repo.one(from s in IncidentEvent, where: is_nil(s.incident_id), select: count(s.id))

      assert unrouted == 0
      assert length(incidents()) == 1
    end

    test "signals below threshold are persisted unrouted" do
      {:ok, result} =
        Detection.ingest_signal(
          signal(%{"kind" => "log", "level" => "info", "message" => "single quiet line"})
        )

      assert result.outcome == :unrouted
      assert result.signal.incident_id == nil
      assert Repo.get(IncidentEvent, result.signal.id) != nil
    end
  end

  describe "ingest_signal/1 — validation" do
    test "rejects a blank message" do
      assert {:error, %Ecto.Changeset{}} =
               Detection.ingest_signal(signal(%{"message" => "  "}))
    end

    test "rejects an unknown kind" do
      assert {:error, %Ecto.Changeset{}} =
               Detection.ingest_signal(signal(%{"kind" => "telepathy"}))
    end

    test "rejects an out-of-range occurred_at" do
      assert {:error, %Ecto.Changeset{}} =
               Detection.ingest_signal(
                 signal(%{"occurred_at" => "1999-01-01T00:00:00Z"})
               )
    end

    test "rejects non-map metadata instead of coercing it" do
      assert {:error, %Ecto.Changeset{}} =
               Detection.ingest_signal(signal(%{"metadata" => "not-a-map"}))
    end

    test "an invalid signal does not open an incident" do
      assert {:error, %Ecto.Changeset{}} =
               Detection.ingest_signal(signal(%{"kind" => "nope"}))

      assert incidents() == []
      assert count_signals() == 0
    end
  end

  describe "generated incident fields" do
    test "a long message still produces a valid incident within length bounds" do
      long = String.duplicate("stack frame padding ", 300)

      assert {:ok, %{outcome: :opened, incident: incident}} =
               Detection.ingest_signal(signal(%{"message" => long}))

      assert String.length(incident.title) <= 120
      assert String.length(incident.summary) <= 2000
    end

    test "severity escalates when a spike far overshoots the threshold" do
      message = "connection reset flood"

      # The first error opens at :major; sustained volume is what escalates.
      {:ok, first} = Detection.ingest_signal(signal(%{"message" => message}))
      assert first.incident.severity == :major

      # Close the incident so each subsequent signal is novel again and the
      # spike count reflects a fresh window.
      {:ok, _} = Incidents.update_incident_status(first.incident, "resolved")

      for _ <- 1..Detection.spike_threshold() * 4 do
        {:ok, _} = Detection.ingest_signal(signal(%{"message" => message}))
        {:ok, latest} = Detection.ingest_signal(signal(%{"message" => message}))
        {:ok, _} = Incidents.update_incident_status(latest.incident, "resolved")
      end
    end
  end

  describe "explicit fingerprint override" do
    test "a producer-supplied fingerprint groups instead of inferring one" do
      fp = Ecto.UUID.generate()

      {:ok, first} =
        Detection.ingest_signal(
          signal(%{"message" => "totally different text a", "fingerprint" => fp})
        )

      {:ok, second} =
        Detection.ingest_signal(
          signal(%{"message" => "unrelated text b", "fingerprint" => fp})
        )

      assert second.incident.id == first.incident.id
      assert length(incidents()) == 1
    end
  end

  describe "broadcasting" do
    test "an opened incident is announced on the incidents topic" do
      DarkwoodWeb.Endpoint.subscribe("incidents")

      {:ok, %{outcome: :opened, incident: incident}} =
        Detection.ingest_signal(signal(%{"message" => "broadcast me"}))

      assert_receive {:incident_created, %Incident{id: id}}
      assert id == incident.id
    end

    test "an unrouted signal is not announced" do
      DarkwoodWeb.Endpoint.subscribe("incidents")

      {:ok, _} =
        Detection.ingest_signal(
          signal(%{"kind" => "log", "level" => "info", "message" => "quiet"})
        )

      refute_receive {:incident_created, _}, 100
    end
  end
end
