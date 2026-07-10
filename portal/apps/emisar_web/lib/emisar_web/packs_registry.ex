defmodule EmisarWeb.PacksRegistry do
  @moduledoc """
  Compile-time catalog of published action packs — drives the marketing
  `/packs` registry pages (index + per-pack detail) and any portal
  surfaces that need to enumerate available actions.

  ## Source of truth

  The pack YAML files at `packs/<id>/pack.yaml` plus
  `packs/<id>/actions/*.yaml`. This module walks that
  directory at compile time, parses every file with `YamlElixir`, and
  bakes the result into the BEAM module. **There is no hardcoded list.**

  Adding a new pack means dropping its YAML files into the packs dir;
  the next compile picks it up. The `@external_resource` tags ensure
  recompilation on any pack change.

  ## Lookup path

  By default the packs dir is resolved relative to this module's
  source file (`apps/emisar_web/lib/emisar_web/packs_registry.ex` →
  up 5 → repo root → `packs`). Override at compile
  time with `EMISAR_PACKS_DIR=/absolute/path` when building in a
  different layout (e.g. CI artifacts, Docker build).
  """

  alias EmisarWeb.PacksRegistry.{Action, Pack}

  @repo_url "https://github.com/andrewdryga/emisar"
  @packs_root "#{@repo_url}/tree/main/packs"

  # Ubiquitous helper binaries — present on nearly every host and used by
  # many packs only to TALK to a service (curl hits an HTTP API). They say
  # nothing about which services run here, so they're stripped when deriving
  # a pack's detect signal from its `requires`. Maintaining the list HERE,
  # server-side, means it evolves on a portal deploy — no runner release. A
  # pack that needs a real signal declares an explicit `detect:` block.
  @generic_binaries ~w(curl wget nc ncat netcat socat jq openssl)

  # -- Compile-time scan -----------------------------------------------

  @packs_path System.get_env("EMISAR_PACKS_DIR") ||
                Path.expand("../../../../../packs", __DIR__)

  unless File.dir?(@packs_path) do
    raise """
    EmisarWeb.PacksRegistry: packs dir not found.

    Expected at: #{@packs_path}

    Override with the EMISAR_PACKS_DIR env var if your build layout
    differs from the repo default (e.g. Docker, CI artifacts).
    """
  end

  # Tag every YAML file as an external resource so Elixir recompiles
  # this module whenever any pack content changes.
  @manifest_paths Path.wildcard("#{@packs_path}/*/pack.yaml")
  @action_paths Path.wildcard("#{@packs_path}/*/actions/*.yaml")

  for path <- @manifest_paths ++ @action_paths do
    @external_resource path
  end

  # Compile-time YAML → struct conversion. Inlined into the @packs
  # attribute via a single anonymous function so the helpers don't
  # need to be defined before they're called.
  @packs (
           parse_yaml! = fn path ->
             case YamlElixir.read_from_file(path) do
               {:ok, data} ->
                 data

               {:error, reason} ->
                 raise "PacksRegistry: failed to parse #{path}: #{inspect(reason)}"
             end
           end

           # Exec-kind command template (binary + argv, placeholders intact),
           # or nil for a script-kind action (no single-line invocation to
           # preview). The shape mirrors the runner's actionspec.
           exec_command = fn data ->
             case {Map.get(data, "kind", "exec"), get_in(data, ["execution", "command"])} do
               {"exec", %{"binary" => binary, "argv" => argv}}
               when is_binary(binary) and is_list(argv) ->
                 %{binary: binary, argv: argv}

               _ ->
                 nil
             end
           end

           build_action = fn data ->
             %Action{
               id: Map.fetch!(data, "id"),
               title: Map.get(data, "title", ""),
               kind: Map.get(data, "kind", "exec"),
               risk: Map.get(data, "risk", "low"),
               command: exec_command.(data)
             }
           end

           # Content hash matching the Go runner's computePackHash
           # (runner/internal/packs/loader.go): for pack.yaml + every
           # action file listed in the manifest's `actions:` + every
           # referenced script, hash sort-by-relpath of
           # `relpath <0x00> bytes <0x00>`. Verified byte-for-byte
           # against `emisar pack validate` for every pack (see
           # packs_registry_test.exs).
           content_hash = fn pack_dir, manifest ->
             action_rels = Map.get(manifest, "actions", []) || []

             action_entries =
               Enum.flat_map(action_rels, fn rel ->
                 full = Path.join(pack_dir, rel)
                 action = parse_yaml!.(full)
                 base = [{rel, File.read!(full)}]

                 case get_in(action, ["execution", "script", "path"]) do
                   nil -> base
                   spath -> base ++ [{spath, File.read!(Path.join(pack_dir, spath))}]
                 end
               end)

             iodata =
               [{"pack.yaml", File.read!(Path.join(pack_dir, "pack.yaml"))} | action_entries]
               |> Enum.sort_by(fn {rel, _} -> rel end)
               |> Enum.map(fn {rel, data} -> [rel, <<0>>, data, <<0>>] end)

             "sha256:" <> Base.encode16(:crypto.hash(:sha256, iodata), case: :lower)
           end

           # Effective detect signal: an explicit `detect:` block wins;
           # otherwise derive binaries from `requires` minus generic helpers
           # (so a curl-only pack collapses to an empty binary signal and
           # leans on declared processes/ports — or is unsuggestable).
           detect_signal = fn manifest, requires_binaries ->
             declared = Map.get(manifest, "detect", %{}) || %{}
             declared_bins = Map.get(declared, "binaries", []) || []

             binaries =
               if declared_bins == [],
                 do: Enum.reject(requires_binaries, &(&1 in @generic_binaries)),
                 else: declared_bins

             %{
               binaries: binaries,
               processes: Map.get(declared, "processes", []) || [],
               ports: Map.get(declared, "ports", []) || []
             }
           end

           build_pack = fn manifest_path ->
             pack_dir = Path.dirname(manifest_path)
             manifest = parse_yaml!.(manifest_path)
             requires = Map.get(manifest, "requires", %{}) || %{}
             requires_binaries = Map.get(requires, "binaries", []) || []
             action_rels = Map.get(manifest, "actions", []) || []

             actions =
               action_rels
               |> Enum.map(&Path.join(pack_dir, &1))
               |> Enum.map(parse_yaml!)
               |> Enum.map(build_action)
               |> Enum.sort_by(& &1.id)

             %Pack{
               id: Map.fetch!(manifest, "id"),
               name: Map.fetch!(manifest, "name"),
               version: to_string(Map.fetch!(manifest, "version")),
               description:
                 manifest
                 |> Map.get("description", "")
                 |> to_string()
                 |> String.trim()
                 |> String.replace(~r/\s+/, " "),
               vendor: Map.get(manifest, "vendor", "emisar"),
               homepage: Map.get(manifest, "homepage") || @repo_url,
               requires_os: Map.get(requires, "os", []) || [],
               requires_binaries: requires_binaries,
               detect: detect_signal.(manifest, requires_binaries),
               content_hash: content_hash.(pack_dir, manifest),
               actions: actions
             }
           end

           @manifest_paths
           |> Enum.map(build_pack)
           |> Enum.sort_by(& &1.id)
         )

  # -- Per-pack tarballs (compile-time, compressed) --------------------
  #
  # Bake a gzip tarball of each pack's files into the module so the
  # registry can serve a single pack over HTTP without the runtime
  # container needing the source files on disk. Compressed, the whole
  # catalog is ~1 MB. Entries are flat (relative to the pack dir:
  # pack.yaml, actions/…) which is exactly what `emisar pack install`
  # extracts and re-hashes — tar order/mtime are irrelevant since the
  # runner hashes file CONTENTS, not the archive.
  @pack_tarballs (
                   build_targz = fn dir ->
                     entries =
                       "#{dir}/**"
                       |> Path.wildcard(match_dot: false)
                       |> Enum.filter(&File.regular?/1)
                       |> Enum.map(fn abs ->
                         rel = Path.relative_to(abs, dir)
                         {String.to_charlist(rel), String.to_charlist(abs)}
                       end)

                     tmp =
                       Path.join(
                         System.tmp_dir!(),
                         "emisar-pack-build-#{:erlang.unique_integer([:positive])}.tar.gz"
                       )

                     :ok = :erl_tar.create(String.to_charlist(tmp), entries, [:compressed])
                     bin = File.read!(tmp)
                     File.rm(tmp)
                     bin
                   end

                   @manifest_paths
                   |> Enum.map(fn mp ->
                     {:ok, m} = YamlElixir.read_from_file(mp)
                     {Map.fetch!(m, "id"), build_targz.(Path.dirname(mp))}
                   end)
                   |> Map.new()
                 )

  # -- Public API ------------------------------------------------------

  @doc "All packs, ordered alphabetically by id."
  @spec list() :: [Pack.t()]
  def list, do: @packs

  @doc "Total number of published packs."
  @spec pack_count() :: non_neg_integer()
  def pack_count, do: length(@packs)

  @doc "Total declared actions across every published pack."
  @spec action_count() :: non_neg_integer()
  def action_count, do: @packs |> Enum.map(&length(&1.actions)) |> Enum.sum()

  # Curated display grouping for the /packs registry — {label, anchor_slug,
  # [pack ids]} in display order. Presentation metadata only; the catalog
  # itself stays YAML-driven. A pack not listed here falls into a trailing
  # "Other" group (see grouped/0), so a newly-dropped pack still appears —
  # move it into a category when you add it.
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
    by_id = Map.new(@packs, &{&1.id, &1})

    categorized =
      @pack_categories
      |> Enum.map(fn {label, slug, ids} ->
        {label, slug, Enum.flat_map(ids, &List.wrap(Map.get(by_id, &1)))}
      end)
      |> Enum.reject(fn {_label, _slug, packs} -> packs == [] end)

    listed =
      for {_label, _slug, packs} <- categorized, pack <- packs, into: MapSet.new(), do: pack.id

    leftovers = Enum.reject(@packs, &MapSet.member?(listed, &1.id))

    if leftovers == [], do: categorized, else: categorized ++ [{"Other", "other", leftovers}]
  end

  @doc """
  Lean index for `emisar pack suggest` — per pack, only what host-matching
  needs: id, name, OS allowlist, and the detect signal (binaries/processes/
  ports, with ubiquitous helpers already stripped). Packs whose detect is
  all-empty are omitted: with no signal there's nothing to suggest them on
  (e.g. remote-API packs like cloudflare), and leaving them out keeps the
  payload small and the runner honest.
  """
  @spec suggest_index() :: [map()]
  def suggest_index do
    @packs
    |> Enum.map(fn p -> %{id: p.id, name: p.name, os: p.requires_os, detect: p.detect} end)
    |> Enum.reject(&detect_empty?(&1.detect))
  end

  defp detect_empty?(%{binaries: b, processes: pr, ports: po}),
    do: b == [] and pr == [] and po == []

  @doc """
  Gzip tarball bytes for a single pack id, or `:error` if unknown.
  Flat entries (pack.yaml, actions/…) — what `emisar pack install`
  fetches from `/packs/<id>/pack.tar.gz`.
  """
  @spec tarball(String.t()) :: {:ok, binary()} | :error
  def tarball(id) when is_binary(id) do
    case Map.fetch(@pack_tarballs, id) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  @doc "Fetch a single pack by id, or nil if not in the registry."
  @spec get(String.t()) :: Pack.t() | nil
  def get(id) when is_binary(id), do: Enum.find(@packs, &(&1.id == id))

  @doc """
  The exec-kind command template (`%{binary, argv}`, placeholders intact)
  for an action — but only when we can prove our compiled pack is the one the
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
  def source_url(%Pack{id: id}), do: "#{@packs_root}/#{id}"

  @doc "Repo source URL for a single action YAML inside a pack."
  @spec action_source_url(Pack.t(), Action.t()) :: String.t()
  def action_source_url(%Pack{id: pack_id}, %Action{id: action_id}) do
    # Action YAML filenames mirror the unqualified action id:
    #   linux.disk_usage → actions/disk_usage.yaml
    file = action_id |> String.split(".", parts: 2) |> List.last()
    "#{@packs_root}/#{pack_id}/actions/#{file}.yaml"
  end

  @doc """
  Install snippet operators paste on a runner host.

  `emisar pack install <id>` fetches just this pack from the registry
  (`/packs/<id>/pack.tar.gz`), re-validates it, and verifies its content
  hash against `--hash` before copying it into the packs dir. The
  `--hash` pin means a tampered mirror is rejected — the runner only
  installs the exact bytes this page was rendered against.
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
