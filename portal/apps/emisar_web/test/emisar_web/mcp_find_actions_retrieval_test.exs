defmodule EmisarWeb.MCPFindActionsRetrievalTest do
  @moduledoc """
  Retrieval benchmark for `find_actions` at production catalog scale.

  Seeds the founder fleet's real 37-pack set (~700 actions from the shipped
  catalog) across three role-shaped runners, then asserts a golden set of
  operator-language queries each surface their action on PAGE ONE — the page a
  model acts on. Every ranking regression shows up here deterministically,
  without an LLM in the loop.
  """
  use EmisarWeb.ConnCase, async: true
  import EmisarWeb.MCPContractAssertions
  alias Emisar.{ApiKeys, Catalog}

  @catalog :emisar
           |> Application.app_dir("priv/packs/catalog.json")
           |> File.read!()
           |> Jason.decode!()

  # The production trust ledger (2026-07-20), split by realistic host role.
  # Base packs ride on every host, mirroring a real fleet's overlap.
  @base_packs ~w(linux-core systemd-deep debian debugging time-sync showcase)
  @role_packs %{
    "edge-fra-01" =>
      ~w(haproxy traefik envoy network-tls firewall tailscale nic bonding vector cloud-init fs-search),
    "api-iad-02" =>
      ~w(docker nomad consul elixir-beam java-jvm redis typesense zot github-cli git-local grafana victoriametrics victorialogs),
    "pg-primary-iad" =>
      ~w(postgres cassandra process-forensics iscsi multipath pure-flasharray dell-ipmi frr)
  }

  # {operator query, action ids accepted on page one}. Multiple ids only where
  # the catalog genuinely offers equivalent answers; the FIRST id is the
  # canonical one. Symptom language over tool names wherever an operator would
  # phrase it that way.
  @goldens [
    {"postgres replication is lagging behind", ~w(postgres.replication_lag)},
    {"what queries are running right now in postgres",
     ~w(postgres.activity_detail postgres.longest_running_queries)},
    {"top slow postgres queries", ~w(postgres.slow_queries postgres.pg_stat_statements_top)},
    {"postgres connections by state", ~w(postgres.activity_states postgres.connections)},
    {"blocked queries waiting on locks", ~w(postgres.lock_blocking_chains postgres.locks)},
    {"is autovacuum keeping up", ~w(postgres.vacuum_status)},
    {"largest tables by size", ~w(postgres.table_sizes postgres.largest_tables_full)},
    {"unused indexes wasting space", ~w(postgres.unused_indexes)},
    {"terminate a stuck postgres backend", ~w(postgres.terminate_backend postgres.cancel_query)},
    {"how close is postgres to transaction id wraparound", ~w(postgres.xid_wraparound_proximity)},
    {"filesystem disk usage on this host", ~w(linux.disk_usage debugging.disk_free)},
    {"running out of inodes", ~w(linux.inode_usage)},
    {"which process owns tcp port 5432", ~w(debugging.lsof_port)},
    {"oom killer events", ~w(debugging.dmesg_oom)},
    {"top processes by cpu", ~w(debugging.processes_top)},
    {"top processes by memory", ~w(debugging.mem_top)},
    {"system uptime and load average", ~w(linux.uptime debugging.loadavg)},
    {"recent failed login attempts", ~w(linux.failed_logins)},
    {"recent kernel messages", ~w(debugging.dmesg_tail)},
    {"software raid array status", ~w(linux.mdadm_status)},
    {"smart health of a disk", ~w(linux.disk_smart)},
    {"restart a systemd service", ~w(linux.systemctl_restart systemd.unit_restart)},
    {"which systemd units failed", ~w(systemd.failed_units)},
    {"why is boot slow", ~w(systemd.analyze_blame systemd.analyze_critical_chain)},
    {"how much disk is the journal using", ~w(systemd.journal_disk_usage)},
    {"list running docker containers", ~w(docker.ps)},
    {"docker disk usage", ~w(docker.system_df)},
    {"logs of a docker container", ~w(docker.logs docker.compose_logs)},
    {"restart a docker container", ~w(docker.restart docker.compose_restart)},
    {"status of a nomad job", ~w(nomad.job_status_one nomad.job_status_all)},
    {"restart a nomad allocation", ~w(nomad.alloc_restart)},
    {"tail logs of a nomad task", ~w(nomad.alloc_logs nomad.alloc_logs_stderr)},
    {"drain a nomad node for maintenance", ~w(nomad.node_drain)},
    {"nomad raft peers", ~w(nomad.operator_raft_list_peers)},
    {"consul cluster members", ~w(consul.members)},
    {"services registered in consul", ~w(consul.list_services consul.agent_services)},
    {"which consul health checks are failing", ~w(consul.list_checks_critical)},
    {"read a consul kv key", ~w(consul.kv_get)},
    {"cassandra ring status", ~w(cassandra.nodetool_status cassandra.nodetool_ring)},
    {"cassandra compaction backlog", ~w(cassandra.nodetool_compactionstats)},
    {"run a cassandra repair", ~w(cassandra.nodetool_repair)},
    {"redis memory used by a key", ~w(redis.memory_usage)},
    {"redis slow log", ~w(redis.slowlog)},
    {"is this redis a master or replica", ~w(redis.role redis.info)},
    {"sentinel address of the current master",
     ~w(redis.sentinel_get_master_addr redis.sentinel_master)},
    {"when does the tls certificate expire", ~w(net.tls_cert_expiry traefik.acme_cert_expiry)},
    {"dns lookup for a record", ~w(net.dig_record)},
    {"trace the network path with packet loss", ~w(net.traceroute_mtr)},
    {"haproxy backend server status",
     ~w(haproxy.show_servers_state haproxy.show_backend haproxy.show_stat)},
    {"take a haproxy server out of rotation", ~w(haproxy.disable_server)},
    {"bgp session state", ~w(frr.bgp_summary frr.bgp_neighbors)},
    {"current iptables rules", ~w(fw.iptables_filter fw.nft_list_ruleset)},
    {"block an ip address", ~w(fw.iptables_block_ip)},
    {"is tailscale connected", ~w(tailscale.status tailscale.netcheck)},
    {"is the clock in sync with ntp", ~w(time.chrony_tracking time.timedatectl time.ntpq_peers)},
    {"find files larger than a gigabyte", ~w(fs.find_large_files)},
    {"world writable files", ~w(fs.find_world_writable)},
    {"git status of a checkout", ~w(git.status)},
    {"list open pull requests", ~w(gh.pr_list)},
    {"rerun a failed github workflow", ~w(gh.workflow_rerun)},
    {"which grafana alerts are firing", ~w(grafana.alerting_state grafana.alerting_rules)},
    {"thread dump of a java process", ~w(jvm.jstack jvm.jstack_blocked)},
    {"jvm heap summary", ~w(jvm.heap_summary)},
    {"top beam processes of an elixir release", ~w(beam.release_top_processes)},
    {"strace a pid for a few seconds", ~w(forensics.strace_pid_short forensics.strace_summary)},
    {"server power state via the bmc", ~w(ipmi.power_status ipmi.chassis_status)},
    {"hardware sensor readings", ~w(ipmi.sensor ipmi.sdr)},
    {"flash array capacity", ~w(pure.arrays_space pure.volumes_space)},
    {"multipath topology", ~w(multipath.topology)},
    {"active iscsi sessions", ~w(iscsi.sessions)},
    {"query logs in victorialogs", ~w(vl.query)},
    {"run an instant promql query", ~w(vm.query_instant)},
    {"tags of an image in the registry", ~w(zot.tags)},
    {"recent 5xx responses from traefik", ~w(traefik.log_grep_5xx)},
    {"pending security updates", ~w(debian.apt_security_check)},
    {"reboot the host", ~w(linux.reboot_host)},
    {"cloud-init status", ~w(cloud-init.status)}
  ]

  setup %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    _policy = Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)
    {:ok, raw, _key} = ApiKeys.create_key(%{name: "retrieval", kind: :mcp}, subject)

    packs_by_id = Map.new(@catalog["packs"], &{&1["id"], &1})

    for {name, role_packs} <- @role_packs do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: name)
      pack_ids = Enum.filter(@base_packs ++ role_packs, &Map.has_key?(packs_by_id, &1))

      packs =
        Map.new(pack_ids, fn pack_id ->
          pack = packs_by_id[pack_id]
          {pack_id, %{"version" => pack["version"], "hash" => pack["content_hash"]}}
        end)

      actions =
        Enum.flat_map(pack_ids, fn pack_id ->
          Enum.map(packs_by_id[pack_id]["actions"], &Map.put(&1, "pack_id", pack_id))
        end)

      assert {:ok, _runner} =
               Catalog.observe_state(runner, %{
                 "hostname" => runner.hostname,
                 "version" => runner.runner_version,
                 "labels" => runner.labels,
                 "packs" => packs,
                 "actions" => actions
               })
    end

    trust_pending!(subject)

    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    {:ok, conn: conn}
  end

  test "every golden operator query surfaces its action on page one", %{conn: conn} do
    inventory =
      Enum.flat_map(@catalog["packs"], fn pack -> Enum.map(pack["actions"], & &1["id"]) end)

    misses =
      Enum.flat_map(@goldens, fn {query, accepted} ->
        unknown = Enum.reject(accepted, &(&1 in inventory))

        assert unknown == [],
               "golden expects actions absent from the catalog: #{inspect(unknown)}"

        found =
          conn
          |> find_actions(query)
          |> Enum.map(& &1["action_id"])

        if Enum.any?(accepted, &(&1 in found)) do
          []
        else
          [{query, accepted, Enum.take(found, 5)}]
        end
      end)

    assert misses == [],
           Enum.map_join(misses, "\n", fn {query, accepted, found} ->
             "#{inspect(query)} wanted #{inspect(accepted)}, page one led with #{inspect(found)}"
           end)
  end

  test "an exact action id outranks every lexical distractor", %{conn: conn} do
    for action_id <- ~w(postgres.replication_lag nomad.alloc_logs redis.info linux.disk_usage) do
      assert [%{"action_id" => ^action_id} | _rest] =
               conn |> rpc_find_actions(%{"action_id" => action_id}) |> Map.fetch!("candidates")
    end
  end

  defp find_actions(conn, query) do
    conn |> rpc_find_actions(%{"query" => query}) |> Map.fetch!("candidates")
  end

  defp rpc_find_actions(conn, arguments) do
    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{"name" => "find_actions", "arguments" => arguments}
    }

    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/mcp/rpc", Jason.encode!(body))
      |> json_response(200)
      |> get_in(["result", "structuredContent"])

    assert_valid_tool_result("find_actions", result)
    assert result["ok"], "find_actions failed: #{inspect(result["error"])}"
    result
  end

  defp trust_pending!(subject) do
    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)
  end
end
