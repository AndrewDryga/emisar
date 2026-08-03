defmodule Emisar.Catalog.PublishedRegistry do
  @moduledoc """
  The read boundary over the PUBLISHED pack catalog — the library of packs
  we ship to the world. It answers what a pack is, where its immutable
  bytes live, and which command template an action declares; the rest of
  `Emisar.Catalog` judges what a runner actually advertises against it.

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
  ports, with ubiquitous helpers already stripped in the catalog). Packs
  whose detect is all-empty are omitted: with no signal there's nothing to
  suggest them on (e.g. remote-API packs like cloudflare), and leaving them
  out keeps the payload small and the runner honest.
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
  The exec-kind command template (`%{binary, argv}`, placeholders intact)
  for an action — but only when we can prove our catalog pack is the one the
  runner holds, so the template is exactly what will run. Drives the
  approval-page command preview.

  The proof uses the strongest evidence available: a run's pinned
  `expected_pack_hash` must equal our content hash byte-for-byte; if the run
  carries no pinned hash, the runner's advertised `pack_version` must equal
  ours (a contract change always bumps the version, and pack trust couples
  version to hash, so a version match means the same argv template). A pinned
  hash that *differs* is a genuine drift and never falls back to the version.

  `:error` on a drift, an unknown pack/action, a script-kind action (no
  single-line command to render), or when neither hash nor version matches.
  """
  @spec resolve_command(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{binary: String.t(), argv: [String.t()]}} | :error
  def resolve_command(pack_id, action_id, expected_pack_hash, pack_version)
      when is_binary(pack_id) and is_binary(action_id) do
    with %Pack{} = pack <- get(pack_id),
         true <- pack_matches?(pack, expected_pack_hash, pack_version),
         %Action{command: %{} = command} <- Enum.find(pack.actions, &(&1.id == action_id)) do
      {:ok, command}
    else
      _ -> :error
    end
  end

  def resolve_command(_pack_id, _action_id, _expected_pack_hash, _pack_version), do: :error

  # A pinned hash is authoritative — require an exact match, never downgrade to
  # the version. With no pinned hash, an advertised version match is the proof.
  defp pack_matches?(%Pack{content_hash: hash}, expected_hash, _version)
       when is_binary(expected_hash),
       do: hash == expected_hash

  defp pack_matches?(%Pack{version: version}, _expected_hash, pack_version)
       when is_binary(pack_version),
       do: version == pack_version

  defp pack_matches?(_pack, _expected_hash, _version), do: false
end
