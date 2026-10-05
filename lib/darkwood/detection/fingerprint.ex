defmodule Darkwood.Detection.Fingerprint do
  @moduledoc """
  Collapses a raw signal into a stable signature.

  Detection, grouping, and incident creation all key on this value. If it does
  not collapse, nothing downstream works: every occurrence of the same fault
  looks novel, the grouper opens one incident per event, and the product
  degenerates into a log viewer.

  Hashing `kind <> message` directly is not sufficient. Real log lines embed
  values that change per occurrence — request ids, durations, timestamps, row
  counts — so a byte-exact hash is unique every time and never groups.

  The strategy is template normalization: replace the variable parts with
  placeholders, then hash the resulting template. Ordering matters — specific
  patterns run before generic ones so a UUID is masked as a UUID rather than
  being shredded by the numeric rule.
  """

  # {regex, replacement}, applied in order.
  @rules [
    # ISO-8601 / RFC3339 timestamps, optional fractional seconds and zone.
    {~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/, "<ts>"},
    # UUIDs.
    {~r/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/,
     "<uuid>"},
    # IPv4 addresses, before the numeric rules shred them.
    {~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, "<ip>"},
    # Durations and sizes: 842ms, 1.5s, 12us, 3MB.
    {~r/\b\d+(?:\.\d+)?(?:ns|us|µs|ms|sec|secs|seconds|s|mins|min|h|kb|mb|gb)\b/,
     "<dur>"},
    # Long hex tokens: trace ids, hashes, object ids. Must run before the
    # numeric rules or a long all-digit id is labelled as a hex token.
    {~r/\b[0-9a-fA-F]{8,}\b/, "<hex>"},
    # Quoted values.
    {~r/"[^"]*"/, "<str>"},
    {~r/'[^']*'/, "<str>"},
    # Percentages.
    {~r/\b\d+(?:\.\d+)?%/, "<pct>"},
    # Remaining multi-digit numbers: ids, counts, ports, offsets.
    {~r/\b\d{2,}\b/, "<num>"},
    # Remaining single digits.
    {~r/\b\d\b/, "<num>"}
  ]

  @doc """
  Returns the normalized template for `message`, without hashing.

  Useful in the UI and in tests: two signals collapse iff their templates are
  equal.
  """
  def template(message) when is_binary(message) do
    message
    |> String.downcase()
    |> Enum.reduce(@rules, fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def template(message), do: message |> to_string() |> template()

  @doc """
  Returns the fingerprint for a signal, hashing the normalized template.

  Callers may supply an explicit `fingerprint` to override normalization when
  the producer can group more precisely than we can infer.
  """
  def compute(kind, message) do
    :crypto.hash(:sha256, "#{to_string(kind)}:#{template(message)}")
    |> Base.encode16(case: :lower)
  end
end
