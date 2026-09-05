defmodule Emisar.Catalog.PackBaseline do
  @moduledoc """
  The canonical pack hashes we publish right now, read from the live
  published registry.

  Used by `Catalog.observe_state/2` to decide what to do on first sight
  of a `(pack_id, version)`:

    * **Hash matches the published baseline** → auto-pin as trusted.
      That's "these are the bytes we publish, no human review needed".
    * **Hash differs from the published baseline** → record but mark as
      `pending`. Operator must Trust or Reject in the UI.
    * **Unknown pack id** (third-party / custom pack) → record its
      first hash as pending for operator review.

  ## Trust window

  The baseline carries the current version of every published pack **and
  the last few previous versions** (`previous_versions` in the catalog),
  so a runner advertising a slightly-older published version still
  auto-pins as trusted instead of landing in pending review. The window is
  pruned below a pack's retirement watermark when the catalog is built, so
  a retired version is absent from the map and can never auto-pin.

  ## Retirement

  A pack's `retired_below` watermark (set on a critical fix) marks every
  version strictly below it as retired. `retired?/2` is consulted at
  dispatch: a previously-trusted retired version is refused unless an
  admin has explicitly overridden it. Publishing a watermark therefore
  fails a vulnerable version closed without waiting on a portal deploy, but
  it lands per instance: each one starts refusing that version at its own
  next successful registry refresh, not the moment we publish.

  ## Source of truth

  The live published `catalog.json`, read from
  `Emisar.Catalog.PublishedRegistry.Cache` — the same snapshot the pack
  pages render, refreshed on that cache's timer, validated as a complete
  document, and pinned to the configured registry base. The bundled
  `priv/packs/catalog.json` is the boot seed and the last-good floor: a
  registry outage or a malformed publish degrades to the copy the release
  shipped, never to "trust nothing" (which would block dispatch fleet-wide)
  and never to "trust anything".

  Reading trust live is a deliberate, recorded trade. The expected hash and
  the bytes now arrive by the same channel, so write access to the registry
  bucket is enough to auto-trust a pack — a bucket in our own GCP project,
  written only by the `packs-publish` CD job through workload identity
  federation behind an environment approval, which is the trust root the
  portal image already depends on. We accepted it because the alternative
  was worse: the portal marked our own correctly-published packs as
  pending, which teaches operators to click through the one signal on a
  security product they must take seriously. Stored `trusted_manifest`
  snapshots stay immutable per exact `(pack_id, version, hash)`, so a later
  catalog change can never retroactively alter what an already-trusted pack
  claims to do.
  """

  alias Emisar.Catalog.PublishedRegistry.Cache

  @doc """
  Canonical hash for a `(pack_id, version)` from the published library
  (current version or a windowed previous version), or `nil` if the pack
  isn't part of what we publish (third-party / custom) or the version is
  outside the trust window.
  """
  @spec lookup(String.t(), String.t()) :: String.t() | nil
  def lookup(pack_id, version) when is_binary(pack_id) and is_binary(version),
    do: Map.get(Cache.trust_snapshot().baseline, {pack_id, version})

  def lookup(_, _), do: nil

  @doc """
  Complete trusted manifest for an exact published `(pack_id, version,
  hash)`, or `nil` when that historical artifact predates descriptor retention.

  The hash is part of the lookup deliberately: a descriptor from one set of
  bytes must never authorize or describe another.
  """
  @spec manifest(String.t(), String.t(), String.t()) :: map() | nil
  def manifest(pack_id, version, hash)
      when is_binary(pack_id) and is_binary(version) and is_binary(hash),
      do: Map.get(Cache.trust_snapshot().manifests, {pack_id, version, hash})

  def manifest(_, _, _), do: nil

  @doc """
  The current published version for a pack id — the fixed version an operator
  on a retired version should update to — or `nil` if we don't publish the pack.
  """
  @spec current_version(String.t()) :: String.t() | nil
  def current_version(pack_id) when is_binary(pack_id),
    do: Map.get(Cache.trust_snapshot().current_versions, pack_id)

  def current_version(_), do: nil

  @doc """
  The newest trusted version strictly BELOW the pack's current one, or `nil`
  when the trust window holds only the current version.

  The inverse of `newer_version/2`, and the one a caller needs to stand
  something deliberately one version behind — the demo seeds advertise a pack
  here so the console's "update available" nudge has something to point at.
  Deriving it keeps that fixture alive as the window rolls; a pinned literal
  breaks the moment its version leaves the baseline.
  """
  @spec previous_version(String.t()) :: String.t() | nil
  def previous_version(pack_id) when is_binary(pack_id) do
    with current when is_binary(current) <- current_version(pack_id),
         {:ok, current_parsed} <- Version.parse(current) do
      Cache.trust_snapshot().baseline
      |> Enum.flat_map(fn
        {{^pack_id, version}, _hash} ->
          case Version.parse(version) do
            {:ok, parsed} ->
              if Version.compare(parsed, current_parsed) == :lt, do: [parsed], else: []

            :error ->
              []
          end

        _other ->
          []
      end)
      |> case do
        [] -> nil
        older -> older |> Enum.max(Version) |> to_string()
      end
    else
      _ -> nil
    end
  end

  def previous_version(_), do: nil

  @doc """
  The strictly-newer published version an operator could update `(pack_id,
  version)` to — `current_version/1` when it is strictly ahead of `version` — or
  `nil` when we don't publish the pack, `version` already is (or is ahead of) the
  current, or the runner advertises an unparseable version. The fail direction
  is the OPPOSITE of retirement: junk yields `nil` (no false "update
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
  Whether `(pack_id, version)` is retired per the published catalog's
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
  def all, do: Cache.trust_snapshot().baseline

  @doc "Whole retirement-watermark map (`pack_id => version`), mostly for tests."
  @spec retired_below() :: %{String.t() => String.t()}
  def retired_below, do: Cache.trust_snapshot().retired_below
end
