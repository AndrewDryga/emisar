defmodule EmisarWeb.PacksRegistry do
  @moduledoc """
  Static, hardcoded manifest of published action packs — drives the
  marketing `/packs` registry pages (index + per-pack detail). Source
  of truth is the YAML files at
  `runner/examples/packs/<id>/pack.yaml` + `actions/*.yaml`; this
  module mirrors their contents so the website can render without
  having to parse YAML at request time or talk to a runner.

  When a new pack is added to the repo, append it here. A future
  enhancement may load from a remote manifest URL so third-party
  packs can register themselves; for now the registry is curated +
  shipped with the cloud release.
  """

  @repo_url "https://github.com/andrewdryga/emisar"
  @packs_root "#{@repo_url}/tree/main/runner/examples/packs"

  defmodule Action do
    @enforce_keys [:id, :title, :kind, :risk]
    defstruct [:id, :title, :kind, :risk]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            kind: String.t(),
            risk: String.t()
          }
  end

  defmodule Pack do
    @enforce_keys [:id, :name, :version, :description, :vendor, :actions]
    defstruct [
      :id,
      :name,
      :version,
      :description,
      :vendor,
      :homepage,
      :requires_os,
      :requires_binaries,
      actions: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            version: String.t(),
            description: String.t(),
            vendor: String.t(),
            homepage: String.t() | nil,
            requires_os: [String.t()],
            requires_binaries: [String.t()],
            actions: [EmisarWeb.PacksRegistry.Action.t()]
          }
  end

  @doc "All packs, ordered alphabetically by id."
  @spec list() :: [Pack.t()]
  def list, do: Enum.sort_by(packs(), & &1.id)

  @doc "Fetch a single pack by id, or nil if not in the registry."
  @spec get(String.t()) :: Pack.t() | nil
  def get(id) when is_binary(id), do: Enum.find(packs(), &(&1.id == id))

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

  @doc "Install snippet operators paste on a runner host."
  @spec install_snippet(Pack.t()) :: String.t()
  def install_snippet(%Pack{id: id}) do
    """
    # Drop the pack into the runner's pack directory and reload:
    sudo curl -L #{@repo_url}/archive/refs/heads/main.tar.gz | \\
        sudo tar -xz -C /etc/emisar/packs --strip-components=3 \\
        emisar-main/runner/examples/packs/#{id}
    sudo systemctl reload emisar\
    """
  end

  # -- Manifest --------------------------------------------------------
  #
  # Hardcoded mirror of every shipped pack. Keep alphabetically sorted
  # within the pack and within its actions for readable diffs.
  defp packs do
    [
      %Pack{
        id: "linux-core",
        name: "Linux core operations",
        version: "0.2.0",
        description:
          "Safe, read-only Linux diagnostics plus narrow service control. Disk, memory, uptime, journalctl, log grep + tail, systemctl status/restart.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: [],
        actions: [
          %Action{id: "linux.disk_usage", title: "Filesystem disk usage", kind: "exec", risk: "low"},
          %Action{id: "linux.grep_log", title: "Grep a log file", kind: "exec", risk: "low"},
          %Action{
            id: "linux.journalctl",
            title: "Recent systemd journal entries",
            kind: "exec",
            risk: "medium"
          },
          %Action{
            id: "linux.journalctl_grep",
            title: "Grep recent systemd journal entries",
            kind: "exec",
            risk: "medium"
          },
          %Action{id: "linux.memory", title: "System memory snapshot", kind: "exec", risk: "low"},
          %Action{
            id: "linux.systemctl_restart",
            title: "Restart a systemd unit",
            kind: "exec",
            risk: "high"
          },
          %Action{
            id: "linux.systemctl_status",
            title: "Systemd unit status",
            kind: "exec",
            risk: "low"
          },
          %Action{id: "linux.tail_log", title: "Tail a log file", kind: "exec", risk: "low"},
          %Action{
            id: "linux.uptime",
            title: "System uptime and load average",
            kind: "exec",
            risk: "low"
          }
        ]
      },
      %Pack{
        id: "cassandra",
        name: "Cassandra operations",
        version: "0.2.0",
        description:
          "Safe Cassandra inspection actions for LLM runners. Ring status, thread pools, compaction stats, table stats, scoped repair, automated disk-pressure analysis.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["nodetool"],
        actions: [
          %Action{
            id: "cassandra.analyze_disk_pressure",
            title: "Analyze Cassandra disk pressure",
            kind: "script",
            risk: "low"
          },
          %Action{
            id: "cassandra.nodetool_compactionstats",
            title: "Cassandra compaction statistics",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "cassandra.nodetool_repair",
            title: "Cassandra repair",
            kind: "exec",
            risk: "high"
          },
          %Action{
            id: "cassandra.nodetool_status",
            title: "Cassandra node ring status",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "cassandra.nodetool_tablestats",
            title: "Cassandra table stats",
            kind: "exec",
            risk: "medium"
          },
          %Action{
            id: "cassandra.nodetool_tpstats",
            title: "Cassandra thread pool stats",
            kind: "exec",
            risk: "low"
          }
        ]
      },
      %Pack{
        id: "showcase",
        name: "Showcase pack",
        version: "0.2.0",
        description:
          "Synthetic reference pack that demonstrates every action-schema feature in one place: all arg types, every validation, both parsers, both kinds, opts envelope bounds, and per-action redaction rules. Use it as a template when authoring your own.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux", "darwin"],
        requires_binaries: [],
        actions: [
          %Action{
            id: "showcase.every_arg_type",
            title: "One arg of every type",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "showcase.json_output",
            title: "JSON output + redaction",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "showcase.opts_envelope",
            title: "Opts envelope clamping",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "showcase.path_validation",
            title: "Path validation knobs",
            kind: "exec",
            risk: "low"
          },
          %Action{
            id: "showcase.script_action",
            title: "Run a packaged shell script",
            kind: "script",
            risk: "low"
          }
        ]
      },
      %Pack{
        id: "postgres",
        name: "Postgres operations",
        version: "0.1.0",
        description:
          "Read-only Postgres diagnostics plus narrow operator actions for cancelling queries, freeing idle-in-transaction backends, and reloading config. Authenticates via PG* env vars on the runner host.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["psql"],
        actions: [
          %Action{id: "postgres.cancel_query", title: "Cancel a running query", kind: "exec", risk: "high"},
          %Action{id: "postgres.connections", title: "Postgres connection summary", kind: "exec", risk: "low"},
          %Action{id: "postgres.kill_idle", title: "Terminate idle-in-transaction backends", kind: "exec", risk: "high"},
          %Action{id: "postgres.locks", title: "Blocking lock graph", kind: "exec", risk: "low"},
          %Action{id: "postgres.reload_conf", title: "Reload postgresql.conf", kind: "exec", risk: "high"},
          %Action{id: "postgres.replication_lag", title: "Replication lag (primary view)", kind: "exec", risk: "low"},
          %Action{id: "postgres.slow_queries", title: "Top slow queries from pg_stat_statements", kind: "exec", risk: "low"},
          %Action{id: "postgres.table_sizes", title: "Top tables by total size", kind: "exec", risk: "low"},
          %Action{id: "postgres.uptime", title: "Postgres uptime and version", kind: "exec", risk: "low"},
          %Action{id: "postgres.vacuum_status", title: "Autovacuum + bloat snapshot", kind: "exec", risk: "low"}
        ]
      },
      %Pack{
        id: "redis",
        name: "Redis operations",
        version: "0.1.0",
        description:
          "Read-only Redis diagnostics plus narrow operator actions for evicting clients and flushing cache databases. Authenticates via REDISCLI_AUTH on the runner host.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["redis-cli"],
        actions: [
          %Action{id: "redis.client_kill", title: "CLIENT KILL", kind: "exec", risk: "high"},
          %Action{id: "redis.client_list", title: "CLIENT LIST", kind: "exec", risk: "low"},
          %Action{id: "redis.command_stats", title: "INFO commandstats", kind: "exec", risk: "low"},
          %Action{id: "redis.config_get", title: "CONFIG GET", kind: "exec", risk: "low"},
          %Action{id: "redis.dbsize", title: "DBSIZE", kind: "exec", risk: "low"},
          %Action{id: "redis.flush_db", title: "FLUSHDB (single database)", kind: "exec", risk: "critical"},
          %Action{id: "redis.info", title: "Redis INFO section", kind: "exec", risk: "low"},
          %Action{id: "redis.latency", title: "LATENCY LATEST + HISTORY", kind: "exec", risk: "low"},
          %Action{id: "redis.memory_stats", title: "MEMORY STATS", kind: "exec", risk: "low"},
          %Action{id: "redis.slowlog", title: "SLOWLOG GET", kind: "exec", risk: "low"}
        ]
      },
      %Pack{
        id: "debian",
        name: "Debian / Ubuntu package operations",
        version: "0.1.0",
        description:
          "Operator pack for Debian/Ubuntu hosts. Read-only inventory and patching diagnostics, plus narrow apt install/remove actions for a single named package.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["apt-get", "dpkg"],
        actions: [
          %Action{id: "debian.apt_autoremove", title: "apt autoremove", kind: "exec", risk: "high"},
          %Action{id: "debian.apt_install", title: "apt install (one package)", kind: "exec", risk: "high"},
          %Action{id: "debian.apt_remove", title: "apt remove (one package)", kind: "exec", risk: "high"},
          %Action{id: "debian.apt_security_check", title: "Pending security upgrades", kind: "exec", risk: "low"},
          %Action{id: "debian.apt_update", title: "apt-get update", kind: "exec", risk: "medium"},
          %Action{id: "debian.apt_upgradable", title: "List upgradable packages", kind: "exec", risk: "low"},
          %Action{id: "debian.dpkg_changes", title: "Recent dpkg installs/removes", kind: "exec", risk: "low"},
          %Action{id: "debian.dpkg_status", title: "dpkg package status", kind: "exec", risk: "low"},
          %Action{id: "debian.kernel_info", title: "Kernel + uptime + reboot-required", kind: "exec", risk: "low"}
        ]
      },
      %Pack{
        id: "debugging",
        name: "Linux debugging toolkit",
        version: "0.1.0",
        description:
          "General-purpose Linux diagnostic actions: process and memory tops, vmstat/iostat snapshots, socket inventories, per-PID inspection, and network reachability checks. All read-only.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["ps", "ss"],
        actions: [
          %Action{id: "debugging.disk_free", title: "df + mounts", kind: "exec", risk: "low"},
          %Action{id: "debugging.dmesg_tail", title: "Recent kernel messages", kind: "exec", risk: "low"},
          %Action{id: "debugging.iostat", title: "iostat per-device sample", kind: "exec", risk: "low"},
          %Action{id: "debugging.loadavg", title: "Load + memory + uptime snapshot", kind: "exec", risk: "low"},
          %Action{id: "debugging.lsof_port", title: "Who owns a TCP port?", kind: "exec", risk: "low"},
          %Action{id: "debugging.mem_top", title: "Top processes by RSS", kind: "exec", risk: "low"},
          %Action{id: "debugging.netstat_connections", title: "Established connection summary", kind: "exec", risk: "low"},
          %Action{id: "debugging.netstat_listen", title: "Listening sockets", kind: "exec", risk: "low"},
          %Action{id: "debugging.pid_cwd", title: "Process cwd + exe", kind: "exec", risk: "low"},
          %Action{id: "debugging.pid_environ", title: "Process environment", kind: "exec", risk: "low"},
          %Action{id: "debugging.pid_fds", title: "Process open file descriptors", kind: "exec", risk: "low"},
          %Action{id: "debugging.ping_host", title: "Ping a host", kind: "exec", risk: "low"},
          %Action{id: "debugging.processes_top", title: "Top processes by CPU", kind: "exec", risk: "low"},
          %Action{id: "debugging.tcp_summary", title: "TCP state counts", kind: "exec", risk: "low"},
          %Action{id: "debugging.vmstat", title: "vmstat sample", kind: "exec", risk: "low"}
        ]
      },
      %Pack{
        id: "nginx",
        name: "Nginx operations",
        version: "0.1.0",
        description:
          "Operator pack for nginx. Read-only status + access-log analysis, plus narrow operator actions (test_config, reload) for the safe edits. Full restart is intentionally not included — use systemd for that.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["nginx"],
        actions: [
          %Action{id: "nginx.access_top_clients", title: "Top client IPs from access log", kind: "exec", risk: "low"},
          %Action{id: "nginx.access_top_urls", title: "Top URLs from access log", kind: "exec", risk: "low"},
          %Action{id: "nginx.active_version", title: "Active nginx version + build", kind: "exec", risk: "low"},
          %Action{id: "nginx.error_tail", title: "Tail nginx error log", kind: "exec", risk: "low"},
          %Action{id: "nginx.reload", title: "nginx reload", kind: "exec", risk: "high"},
          %Action{id: "nginx.status", title: "Nginx stub_status", kind: "exec", risk: "low"},
          %Action{id: "nginx.test_config", title: "nginx -t", kind: "exec", risk: "low"}
        ]
      },
      %Pack{
        id: "docker",
        name: "Docker operations",
        version: "0.1.0",
        description:
          "Operator pack for Docker hosts. Read-only inventory and per-container introspection, plus narrow mutators (restart, system prune). The runner uid must be in the docker group.",
        vendor: "emisar",
        homepage: @repo_url,
        requires_os: ["linux"],
        requires_binaries: ["docker"],
        actions: [
          %Action{id: "docker.images", title: "docker images", kind: "exec", risk: "low"},
          %Action{id: "docker.inspect", title: "docker inspect (one container)", kind: "exec", risk: "low"},
          %Action{id: "docker.logs", title: "docker logs (last N lines)", kind: "exec", risk: "low"},
          %Action{id: "docker.ps", title: "docker ps -a", kind: "exec", risk: "low"},
          %Action{id: "docker.restart", title: "docker restart (one container)", kind: "exec", risk: "high"},
          %Action{id: "docker.stats", title: "docker stats (one shot)", kind: "exec", risk: "low"},
          %Action{id: "docker.system_df", title: "docker system df", kind: "exec", risk: "low"},
          %Action{id: "docker.system_prune", title: "docker system prune", kind: "exec", risk: "high"}
        ]
      }
    ]
  end
end
