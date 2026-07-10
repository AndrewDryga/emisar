defmodule EmisarWeb.PacksRegistry do
  @moduledoc """
  The portal's read boundary over the published pack catalog — drives the
  marketing `/packs` registry pages (index + per-pack detail), the machine
  `/packs.json` / `/packs/suggest.json` / `/packs/:id/pack.tar.gz`
  endpoints, and the approval-page command preview.

  ## Source of truth

  A published `catalog.json` (built out-of-band by `emisar pack catalog
  build`, so the portal, the runner, and the catalog agree on every
  content hash byte-for-byte). `EmisarWeb.PacksRegistry.Cache` loads the
  bundled catalog at boot and refreshes from the published URL, keeping the
  last-good copy on any outage. This module reads the current catalog from
  that cache — it holds no pack bytes and does no scanning.

  Adding or changing a pack means republishing the catalog + its immutable
  tarball; the portal picks it up on the next cache refresh, no redeploy.
  """

  alias EmisarWeb.PacksRegistry.{Action, Cache, Pack}

  # -- Public API ------------------------------------------------------

  @doc "All packs, ordered alphabetically by id."
  @spec list() :: [Pack.t()]
  def list, do: Cache.current()

  @doc "Total number of published packs."
  @spec pack_count() :: non_neg_integer()
  def pack_count, do: length(list())

  @doc "Total declared actions across every published pack."
  @spec action_count() :: non_neg_integer()
  def action_count, do: list() |> Enum.map(&length(&1.actions)) |> Enum.sum()

  # Curated display grouping for the /packs registry — {label, anchor_slug,
  # [pack ids]} in display order. Presentation metadata only; the catalog
  # itself stays the data source. A pack not listed here falls into a
  # trailing "Other" group (see grouped/0), so a newly-published pack still
  # appears — move it into a category when you add it.
  @pack_categories [
    {"Databases & datastores", "databases",
     ~w(postgres mysql mongodb redis cassandra clickhouse cockroach elasticsearch memcached typesense kafka rabbitmq zookeeper)},
    {"Containers & orchestration", "containers", ~w(docker podman kubernetes nomad rke2 consul)},
    {"Observability", "observability",
     ~w(prometheus grafana victoriametrics victorialogs vector)},
    {"Web, proxies & ingress", "web", ~w(nginx apache-httpd caddy haproxy traefik envoy php-fpm)},
    {"Cloud & IaC", "cloud",
     ~w(aws-ec2 aws-s3 aws-rds aws-iam aws-cloudwatch aws-cost cloudflare terraform-readonly)},
    {"Networking, DNS & VPN", "networking",
     ~w(bind frr firewall pfsense wireguard tailscale snmp dell-idrac dell-ipmi nic bonding network-tls iperf3 ssl-local time-sync)},
    {"Storage & filesystems", "storage",
     ~w(zfs nfs iscsi multipath pure-flasharray minio zot fs-search)},
    {"Linux & system", "linux",
     ~w(linux-core systemd-deep debian dnf-rpm debugging process-forensics cloud-init postfix)},
    {"Runtimes & dev tools", "runtimes",
     ~w(java-jvm nodejs-pm2 python-app git-local github-cli showcase)},
    {"Security & secrets", "security", ~w(vault fail2ban shell)}
  ]

  @doc """
  Published packs grouped for the registry page — an ordered list of
  `{category_label, anchor_slug, [Pack.t()]}`. Packs not in a curated
  category fall into a trailing "Other" group so a newly-added pack still
  lists.
  """
  @spec grouped() :: [{String.t(), String.t(), [Pack.t()]}]
  def grouped do
    packs = list()
    by_id = Map.new(packs, &{&1.id, &1})

    categorized =
      @pack_categories
      |> Enum.map(fn {label, slug, ids} ->
        {label, slug, Enum.flat_map(ids, &List.wrap(Map.get(by_id, &1)))}
      end)
      |> Enum.reject(fn {_label, _slug, packs} -> packs == [] end)

    listed =
      for {_label, _slug, packs} <- categorized, pack <- packs, into: MapSet.new(), do: pack.id

    leftovers = Enum.reject(packs, &MapSet.member?(listed, &1.id))

    if leftovers == [], do: categorized, else: categorized ++ [{"Other", "other", leftovers}]
  end

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

  @doc "Repo source URL for a pack, suitable for an external link."
  @spec source_url(Pack.t()) :: String.t()
  def source_url(%Pack{source_url: url}), do: url

  @doc "Repo source URL for a single action YAML inside a pack."
  @spec action_source_url(Pack.t(), Action.t()) :: String.t()
  def action_source_url(%Pack{source_url: source_url}, %Action{id: action_id}) do
    # Action YAML filenames mirror the unqualified action id:
    #   linux.disk_usage → actions/disk_usage.yaml
    file = action_id |> String.split(".", parts: 2) |> List.last()
    "#{source_url}/actions/#{file}.yaml"
  end

  @doc """
  Install snippet operators paste on a runner host.

  `emisar pack install <id>` fetches just this pack from the registry
  (`/packs/<id>/pack.tar.gz`, which redirects to the immutable tarball),
  re-validates it, and verifies its content hash against `--hash` before
  copying it into the packs dir. The `--hash` pin means a tampered mirror is
  rejected — the runner only installs the exact bytes this page was rendered
  against.
  """
  @spec install_snippet(Pack.t()) :: String.t()
  def install_snippet(%Pack{id: id, content_hash: hash}) do
    """
    sudo emisar pack install #{id} \\
      --hash #{hash} \\
      --dest /etc/emisar/packs

    # Reload so the runner re-reads the catalog:
    sudo systemctl reload emisar\
    """
  end
end
