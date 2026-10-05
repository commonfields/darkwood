defmodule Darkwood.Detection.FingerprintTest do
  use ExUnit.Case, async: true

  alias Darkwood.Detection.Fingerprint

  describe "template/1" do
    test "collapses UUIDs" do
      a = Fingerprint.template("checkout failed for user 550e8400-e29b-41d4-a716-446655440000")
      b = Fingerprint.template("checkout failed for user 6ba7b810-9dad-11d1-80b4-00c04fd430c8")

      assert a == b
      assert a =~ "<uuid>"
    end

    test "collapses durations, timestamps, and counts" do
      a = Fingerprint.template("query latency 842ms at 2026-10-05T13:57:08.123Z row_count=41923")
      b = Fingerprint.template("query latency 91ms at 2026-01-01T00:00:00.000Z row_count=7")

      assert a == b
    end

    test "collapses IPv4 addresses" do
      a = Fingerprint.template("upstream 10.0.4.19 refused connection")
      b = Fingerprint.template("upstream 192.168.77.2 refused connection")

      assert a == b
      assert a =~ "<ip>"
    end

    test "collapses quoted values" do
      assert Fingerprint.template(~s|route "/api/v1/a" timed out|) ==
               Fingerprint.template(~s|route "/api/v2/b" timed out|)
    end

    test "collapses long hex tokens" do
      a = Fingerprint.template("trace a1b2c3d4e5f60718 failed")
      b = Fingerprint.template("trace ffeeddccbbaa9988 failed")

      assert a == b
      assert a =~ "<hex>"
    end

    test "is case insensitive" do
      assert Fingerprint.template("Connection REFUSED") == Fingerprint.template("connection refused")
    end

    test "collapses whitespace" do
      assert Fingerprint.template("a   b") == Fingerprint.template("a b")
    end

    test "does not mask ordinary prose as hex" do
      refute Fingerprint.template("connection refused") =~ "<hex>"
    end

    test "keeps distinct faults distinct" do
      refute Fingerprint.template("disk full") == Fingerprint.template("out of memory")
    end
  end

  describe "compute/2" do
    test "is stable for the same kind and equivalent message" do
      a = Fingerprint.compute(:error, "timeout after 500ms")
      b = Fingerprint.compute(:error, "timeout after 1200ms")

      assert a == b
      assert String.length(a) == 64
    end

    test "differs across kinds" do
      refute Fingerprint.compute(:error, "boom") == Fingerprint.compute(:log, "boom")
    end

    test "differs across genuinely different messages" do
      refute Fingerprint.compute(:error, "disk full") == Fingerprint.compute(:error, "oom kill")
    end
  end
end
