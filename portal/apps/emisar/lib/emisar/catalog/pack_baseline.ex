defmodule Emisar.Catalog.PackBaseline do
  @moduledoc """
  Release-frozen baseline of canonical pack hashes for every pack the
  release ships, read from the committed catalog artifact.

  Used by `Catalog.observe_state/2` to decide what to do on first sight
  of a `(pack_id, version)`:

    * **Hash matches our shipped baseline** → auto-pin as trusted.
      That's "these are the bytes we publish, no human review needed".
    * **Hash differs from our shipped baseline** → record but mark as
      `pending`. Operator must Trust or Reject in the UI.
    * **Unknown pack id** (third-party / custom pack) → record its
      first hash as pending for operator review.

  ## Source of truth

  The bundled `priv/packs/catalog.json` — the same artifact
  `EmisarWeb.PacksRegistry.Cache` serves from, built by `emisar pack
  catalog build` (the runner's `computePackHash` is the single hash
  source, so a runner with unmodified shipped bytes produces a hash this
  baseline also carries). Baking it at compile time keeps trust
  **release-controlled**: the auto-pin set is exactly what this release
  publishes, never the mutable remote catalog the display cache refreshes
  from — a compromised published catalog cannot auto-trust new hashes.
  """

  @catalog_path Path.expand("../../../priv/packs/catalog.json", __DIR__)
  @external_resource @catalog_path

  @baseline @catalog_path
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("packs")
            |> Map.new(fn %{"id" => id, "version" => version, "content_hash" => hash} ->
              {{id, to_string(version)}, hash}
            end)

  @doc """
  Canonical hash for a `(pack_id, version)` from the shipped library,
  or `nil` if the pack isn't part of what we publish (third-party /
  custom).
  """
  @spec lookup(String.t(), String.t()) :: String.t() | nil
  def lookup(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: Map.get(@baseline, {pack_id, version})

  def lookup(_, _), do: nil

  @doc "Whole baseline, mostly for tests + debugging."
  @spec all() :: %{{String.t(), String.t()} => String.t()}
  def all, do: @baseline
end
