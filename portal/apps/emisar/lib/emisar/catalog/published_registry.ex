defmodule Emisar.Catalog.PublishedRegistry do
  @moduledoc """
  The read boundary over the PUBLISHED pack catalog — the library of packs
  we ship to the world. It answers what a pack is, where its immutable
  bytes live, and what an action declares (command template and args); the
  rest of `Emisar.Catalog` judges what a runner actually advertises against
  it.

  Drives the marketing `/packs` registry pages, the machine `/packs.json` /
  `/packs/suggest.json` / `/packs/:id/pack.tar.gz` endpoints, and the
  approval-page command preview.

  ## Source of truth

  A published `catalog.json` (built out-of-band by `emisar pack catalog
  build`, so the portal, the runner, and the catalog agree on every content
  hash byte-for-byte). `Cache` loads the bundled catalog at boot and
  refreshes from the published URL, keeping the last-good copy on any
  outage. This module reads the current catalog from that cache — it holds
  no pack bytes and does no scanning.

  Adding or changing a pack means republishing the catalog + its immutable
  tarball; the portal picks it up on the next cache refresh, no redeploy.

  Account-scoped by nothing: the published catalog is the same public
  document for every tenant, so these reads take no `%Auth.Subject{}`.
  """

  alias Emisar.Catalog.PublishedRegistry.{Action, Cache, Pack}

  @doc "All packs, ordered alphabetically by id."
  @spec list() :: [Pack.t()]
  def list, do: Cache.current()

  @doc "Total number of published packs."
  @spec pack_count() :: non_neg_integer()
  def pack_count, do: length(list())

  @doc "Total declared actions across every published pack."
  @spec action_count() :: non_neg_integer()
  def action_count, do: list() |> Enum.map(&length(&1.actions)) |> Enum.sum()

  @doc """
  Lean index for `emisar pack suggest` — per pack, only what host-matching
  needs: id, name, OS allowlist, and the detect signal (binaries/processes/
  ports) exactly as the pack authored it; a runtime requirement is never
  promoted into a signal. Packs whose detect is all-empty are omitted: with
  no authored evidence there's nothing to suggest them on (e.g. remote-API
  packs like cloudflare), and leaving them out keeps the payload small and
  the runner honest.
  """
  @spec suggest_index() :: [map()]
  def suggest_index do
    list()
    |> Enum.map(fn p -> %{id: p.id, name: p.name, os: p.requires_os, detect: p.detect} end)
    |> Enum.reject(&detect_empty?(&1.detect))
  end

  defp detect_empty?(%{binaries: b, processes: pr, ports: po}),
    do: b == [] and pr == [] and po == []

  @doc """
  The immutable, content-addressed tarball URL for a single pack id, or
  `:error` if the id is unknown. The `/packs/:id/pack.tar.gz` endpoint
  302-redirects here; the bytes live in the pack registry bucket, not the
  release.
  """
  @spec tarball_url(String.t()) :: {:ok, String.t()} | :error
  def tarball_url(id) when is_binary(id) do
    case get(id) do
      %Pack{tarball_url: url} -> {:ok, url}
      nil -> :error
    end
  end

  @doc """
  The immutable tarball URL for a specific pack VERSION — the pack's current
  version or any version still in its carried-forward history — or `:error`
  if the id is unknown or the version is neither current nor remembered. The
  `/packs/:id/versions/:version/pack.tar.gz` endpoint 302-redirects here, so
  `emisar pack install <id>=<version>` resolves an exact prior release.
  """
  @spec tarball_url(String.t(), String.t()) :: {:ok, String.t()} | :error
  def tarball_url(id, version) when is_binary(id) and is_binary(version) do
    case get(id) do
      %Pack{} = pack -> Pack.tarball_url(pack, version)
      nil -> :error
    end
  end

  @doc "Fetch a single pack by id, or nil if not in the registry."
  @spec get(String.t()) :: Pack.t() | nil
  def get(id) when is_binary(id), do: Enum.find(list(), &(&1.id == id))

  @doc """
  One exec-kind action — its command template (`%{binary, argv}`, placeholders
  intact) together with its declared args — but only when we can prove our
  catalog pack is byte-for-byte the one the runner holds. Drives the
  approval-page command preview, which renders template and args as a pair.

  The proof is content hashes only. A run's pinned `expected_pack_hash` is
  authoritative: it AND the runner's `advertised_pack_hash` must equal our
  content hash. An unpinned run is proven by the advertised hash alone. A
  version is never evidence — it is a label a pack author chooses, so it can
  name bytes we don't have.

  `:error` on any mismatch or missing hash, an unknown pack/action, or a
  script-kind action (no single-line command to render).
  """
  @spec resolve_action(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Action.t()} | :error
  def resolve_action(pack_id, action_id, expected_pack_hash, advertised_pack_hash)
      when is_binary(pack_id) and is_binary(action_id) do
    with %Pack{} = pack <- get(pack_id),
         true <- hashes_prove_pack?(pack, expected_pack_hash, advertised_pack_hash),
         %Action{command: %{}} = action <- Enum.find(pack.actions, &(&1.id == action_id)) do
      {:ok, action}
    else
      _ -> :error
    end
  end

  def resolve_action(_pack_id, _action_id, _expected_pack_hash, _advertised_pack_hash), do: :error

  defp hashes_prove_pack?(%Pack{content_hash: hash}, expected_hash, advertised_hash)
       when is_binary(expected_hash),
       do: expected_hash == hash and advertised_hash == hash

  defp hashes_prove_pack?(%Pack{content_hash: hash}, nil, advertised_hash)
       when is_binary(advertised_hash),
       do: advertised_hash == hash

  defp hashes_prove_pack?(_pack, _expected_hash, _advertised_hash), do: false
end
