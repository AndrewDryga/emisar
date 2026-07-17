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

  ## Trust window

  The baseline carries the current version of every shipped pack **and
  the last few previous versions** (`previous_versions` in the catalog),
  so a runner advertising a slightly-older shipped version still auto-pins
  as trusted instead of landing in pending review. The window is
  pruned below a pack's retirement watermark at build time, so a retired
  version is absent from the map and can never auto-pin.

  ## Retirement

  A pack's `retired_below` watermark (set on a critical fix) marks every
  version strictly below it as retired. `retired?/2` is consulted at
  dispatch: a previously-trusted retired version is refused unless an
  admin has explicitly overridden it. Retirement is release-controlled
  like auto-trust — it consults this bundled catalog only, so a
  compromised remote catalog can neither auto-trust nor mass-retire.

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

  alias Emisar.Catalog.TrustedManifest

  @catalog_path Path.expand("../../../priv/packs/catalog.json", __DIR__)
  @external_resource @catalog_path

  @packs @catalog_path |> File.read!() |> Jason.decode!() |> Map.fetch!("packs")

  @version_entries Enum.flat_map(@packs, fn %{
                                              "id" => id,
                                              "version" => version,
                                              "content_hash" => hash,
                                              "actions" => actions
                                            } = pack ->
                     history =
                       Enum.map(pack["previous_versions"] || [], fn previous ->
                         %{
                           pack_id: id,
                           version: to_string(Map.fetch!(previous, "version")),
                           hash: Map.fetch!(previous, "content_hash"),
                           actions: previous["actions"],
                           current?: false
                         }
                       end)

                     [
                       %{
                         pack_id: id,
                         version: to_string(version),
                         hash: hash,
                         actions: actions,
                         current?: true
                       }
                       | history
                     ]
                   end)

  @baseline Map.new(@version_entries, fn entry ->
              {{entry.pack_id, entry.version}, entry.hash}
            end)

  @manifest_pairs Enum.flat_map(@version_entries, fn
                    %{actions: nil} ->
                      []

                    %{
                      pack_id: id,
                      version: version,
                      hash: hash,
                      actions: actions,
                      current?: current?
                    } ->
                      case TrustedManifest.from_catalog_actions(actions) do
                        {:ok, manifest} ->
                          [{{id, version, hash}, manifest}]

                        {:error, :invalid_manifest} when current? ->
                          raise "PackBaseline: #{id}@#{version}/#{hash} has an invalid action manifest"

                        {:error, :invalid_manifest} ->
                          []
                      end
                  end)

  @manifests Map.new(@manifest_pairs)

  # The current shipped version of every pack — `id => version` — the fixed
  # version a runner on a retired version should update to. `@packs` is never
  # empty, so this is typed `map()` (no empty-map warning; see `retired_below`).
  @current_versions Map.new(@packs, fn %{"id" => id, "version" => version} ->
                      {id, to_string(version)}
                    end)

  # Baked as a list, not a map: the shipped catalog carries no watermark
  # until the first critical-fix retirement, so a baked `%{}` would be
  # typed `empty_map()` and make `Map.get/2` in `retired?/2` a compile
  # warning. `retired_below/0` builds the map through `Map.new/1` (typed
  # `map()`), which launders that away.
  @retired_below_pairs for %{"id" => id} = pack <- @packs,
                           is_binary(pack["retired_below"]),
                           do: {id, pack["retired_below"]}

  # Compile-time contract: every version the release ships — current,
  # windowed history, and retirement watermark — MUST parse as SemVer,
  # because the retirement compare relies on it. All shipped packs are
  # x.y.z; a junk version in our own artifact fails the build here, not a
  # dispatch.
  for {{id, version}, _hash} <- @baseline, match?(:error, Version.parse(version)) do
    raise "PackBaseline: pack #{id} ships an unparseable version #{inspect(version)}"
  end

  for {id, watermark} <- @retired_below_pairs, match?(:error, Version.parse(watermark)) do
    raise "PackBaseline: pack #{id} has an unparseable retired_below #{inspect(watermark)}"
  end

  @doc """
  Canonical hash for a `(pack_id, version)` from the shipped library
  (current version or a windowed previous version), or `nil` if the pack
  isn't part of what we publish (third-party / custom) or the version is
  outside the trust window.
  """
  @spec lookup(String.t(), String.t()) :: String.t() | nil
  def lookup(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: Map.get(@baseline, {pack_id, version})

  def lookup(_, _), do: nil

  @doc """
  Complete trusted manifest for an exact release-frozen `(pack_id, version,
  hash)`, or `nil` when that historical artifact predates descriptor retention.

  The hash is part of the lookup deliberately: a descriptor from one set of
  bytes must never authorize or describe another.
  """
  @spec manifest(String.t(), String.t(), String.t()) :: map() | nil
  def manifest(pack_id, version, hash)
      when is_binary(pack_id) and is_binary(version) and is_binary(hash),
      do: Map.get(@manifests, {pack_id, version, hash})

  def manifest(_, _, _), do: nil

  @doc """
  The current shipped version for a pack id — the fixed version an operator on
  a retired version should update to — or `nil` if we don't ship the pack.
  """
  @spec current_version(String.t()) :: String.t() | nil
  def current_version(pack_id) when is_binary(pack_id),
    do: Map.get(@current_versions, pack_id)

  def current_version(_), do: nil

  @doc """
  The strictly-newer shipped version an operator could update `(pack_id,
  version)` to — `current_version/1` when it is strictly ahead of `version` — or
  `nil` when we don't ship the pack, `version` already is (or is ahead of) the
  current, or the runner advertises an unparseable version. Pure. The fail
  direction is the OPPOSITE of retirement: junk yields `nil` (no false "update
  available"), because an update hint is a convenience, never a gate — it must
  never fire on a garbage version string.
  """
  @spec newer_version(String.t(), String.t()) :: String.t() | nil
  def newer_version(pack_id, version) when is_binary(pack_id) and is_binary(version) do
    with current when is_binary(current) <- current_version(pack_id),
         {:ok, advertised_version} <- Version.parse(version),
         {:ok, current_parsed} <- Version.parse(current),
         :lt <- Version.compare(advertised_version, current_parsed) do
      current
    else
      _ -> nil
    end
  end

  def newer_version(_, _), do: nil

  @doc """
  Whether `(pack_id, version)` is retired per the shipped catalog's
  `retired_below` watermark for that pack. False when the pack has no
  watermark; fail-closed for an unparseable advertised version against a
  present watermark (see `version_retired?/2`).
  """
  @spec retired?(String.t(), String.t()) :: boolean()
  def retired?(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: version_retired?(version, Map.get(retired_below(), pack_id))

  def retired?(_, _), do: false

  @doc """
  Whether an `advertised` version is retired relative to a `watermark`
  (a pack's `retired_below`). Pure — the fail-closed compare on hostile
  runner input: a nil watermark retires nothing, a version strictly
  below the watermark is retired, and an UNPARSEABLE advertised version
  against a present watermark is treated as retired so a hostile runner
  cannot dodge retirement with a junk version string.
  """
  @spec version_retired?(String.t(), String.t() | nil) :: boolean()
  def version_retired?(_advertised, nil), do: false

  def version_retired?(advertised, watermark)
      when is_binary(advertised) and is_binary(watermark) do
    with {:ok, advertised_version} <- Version.parse(advertised),
         {:ok, watermark_version} <- Version.parse(watermark) do
      Version.compare(advertised_version, watermark_version) == :lt
    else
      :error -> true
    end
  end

  @doc "Whole baseline, mostly for tests + debugging."
  @spec all() :: %{{String.t(), String.t()} => String.t()}
  def all, do: @baseline

  @doc "All complete exact-hash manifests, mostly for tests + debugging."
  @spec all_manifests() :: %{{String.t(), String.t(), String.t()} => map()}
  def all_manifests, do: @manifests

  @doc "Whole retirement-watermark map (`pack_id => version`), mostly for tests."
  @spec retired_below() :: %{String.t() => String.t()}
  def retired_below, do: Map.new(@retired_below_pairs)
end
