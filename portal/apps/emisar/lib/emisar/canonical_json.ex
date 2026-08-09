defmodule Emisar.CanonicalJSON do
  @moduledoc """
  One canonical JSON encoding, and the SHA-256 digest taken over it.

  Two identity digests are computed this way — the action-contract hash a client
  compares to decide `target_contract_changed`, and a runbook's `definition_hash`
  — and `.agent/kb/specs/compatibility.md` freezes both at 1.0. They were
  computed by byte-identical private copies of the same three steps in two
  modules, which is the worst place for this repo's paired-path drift: a peer
  compares the two values, so any divergence in ordering shows up as a false
  "contract changed" rather than as a failing test.

  Encoding is deterministic through key order alone: maps are sorted by key and
  emitted as `Jason.OrderedObject`, lists keep their order (position is meaning),
  and scalars pass through. The input is a decoded JSON value — both callers
  digest a validated JSON-compatible map — so no struct reaches the map clause.
  """

  @doc "Stable SHA-256 identity, hex-encoded, for one JSON-compatible value."
  @spec digest(map()) :: String.t()
  def digest(value) when is_map(value) do
    value
    |> encode!()
    |> Emisar.Crypto.hash_hex()
  end

  @doc "The canonical JSON text `digest/1` hashes."
  @spec encode!(term()) :: String.t()
  def encode!(value), do: value |> canonical() |> Jason.encode!()

  @doc """
  The same canonical value, one JSON token per line.

  Indentation is presentation, so this never feeds `digest/1` — identity stays
  the compact form. It exists so two versions of one document can be compared
  line by line against the very text whose hash is their identity.
  """
  @spec encode_pretty!(term()) :: String.t()
  def encode_pretty!(value), do: value |> canonical() |> Jason.encode!(pretty: true)

  defp canonical(%{} = value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, child} -> {key, canonical(child)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
