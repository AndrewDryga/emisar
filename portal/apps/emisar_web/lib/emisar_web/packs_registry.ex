defmodule EmisarWeb.PacksRegistry do
  @moduledoc """
  How the published pack catalog is PRESENTED on the marketing `/packs`
  registry pages — the curated category grouping, the repo source links,
  and the install snippet an operator pastes on a runner host.

  The catalog itself is domain-owned: `Emisar.Catalog.PublishedRegistry`
  parses, caches, and resolves it (list, lookup, tarball URLs, the suggest
  projection, the command preview's template). Nothing here validates,
  fetches, or pins anything.
  """

  alias Emisar.Catalog

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
     ~w(aws-ec2 aws-s3 aws-rds aws-iam aws-cloudwatch aws-cost gcp-compute gcp-cloudsql gcp-storage gcp-networking gcp-load-balancing gcp-dns gcp-iam gcp-certificates gcp-monitoring cloudflare terraform-readonly hcp-terraform)},
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
  @spec grouped([Catalog.PublishedRegistry.Pack.t()]) :: [
          {String.t(), String.t(), [Catalog.PublishedRegistry.Pack.t()]}
        ]
  def grouped(packs) when is_list(packs) do
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

  @doc "Repo source URL for a pack, suitable for an external link."
  @spec source_url(Catalog.PublishedRegistry.Pack.t()) :: String.t()
  def source_url(%Catalog.PublishedRegistry.Pack{source_url: url}), do: url

  @doc "Repo source URL for a single action YAML inside a pack."
  @spec action_source_url(
          Catalog.PublishedRegistry.Pack.t(),
          Catalog.PublishedRegistry.Action.t()
        ) :: String.t()
  def action_source_url(
        %Catalog.PublishedRegistry.Pack{source_url: source_url},
        %Catalog.PublishedRegistry.Action{id: action_id}
      ) do
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
  copying it into the runner's packs dir. The `--hash` pin means a tampered
  mirror is rejected — the runner installs only the exact bytes this page was
  rendered against — and the command reloads a running daemon itself, so there
  is no manual restart. `--dest` defaults to the runner's configured packs dir,
  so it's only needed to override it.
  """
  @spec install_snippet(Catalog.PublishedRegistry.Pack.t()) :: String.t()
  def install_snippet(%Catalog.PublishedRegistry.Pack{id: id, content_hash: hash}) do
    "sudo emisar pack install #{id} --hash #{hash}"
  end
end
