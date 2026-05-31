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
      }
    ]
  end
end
