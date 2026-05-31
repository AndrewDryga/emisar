# Seeds for local dev. Run with `mix run apps/emisar/priv/repo/seeds.exs`
# or via `mix ecto.setup`. Idempotent — safe to re-run.
#
# Goal: produce a believable live-account state so the dashboard,
# runs list, approvals, runners, audit, and grants pages all show
# real-shaped data when an operator first opens the app — instead of
# empty-state cards everywhere.

alias Emisar.{Accounts, Approvals, Audit, Catalog, Policies, Repo, Runbooks, Runners, Runs}
alias Emisar.Accounts.User
alias Emisar.Approvals.Request, as: ApprovalRequest
alias Emisar.Auth.Subject
# Approval emails go through Swoosh; in dev that's fine, but the seed
# shouldn't depend on the mailer being reachable.
Application.put_env(:emisar, :notify_approvers_async?, false)

now = fn -> DateTime.utc_now() |> DateTime.truncate(:microsecond) end
mins_ago = fn n -> DateTime.add(now.(), -n * 60, :second) end
hours_ago = fn n -> DateTime.add(now.(), -n * 3600, :second) end
days_ago = fn n -> DateTime.add(now.(), -n * 86_400, :second) end

# -- Demo account + owner --------------------------------------------

demo_email = "demo@emisar.dev"

user =
  case Accounts.fetch_user_by_email(demo_email) do
    {:error, :not_found} ->
      {:ok, u} =
        Accounts.register_user(%{
          full_name: "Demo User",
          email: demo_email,
          password: "Sleep-tight-1234"
        })

      {:ok, u} = Accounts.confirm_user(u)
      u

    {:ok, %User{full_name: nil} = u} ->
      {:ok, u} = Accounts.update_user_profile(u, %{full_name: "Demo User"}, Subject.system())
      u

    {:ok, %User{} = u} ->
      u
  end

account =
  case Accounts.fetch_account_by_slug("demo") do
    {:error, :not_found} ->
      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Demo Corp", slug: "demo", plan: "team"},
          user
        )

      account

    {:ok, a} ->
      a
  end

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Demo account ready (slug=demo, owner=#{demo_email}, password=Sleep-tight-1234)" <>
    IO.ANSI.reset()
)

# -- Default policy ---------------------------------------------------

if Policies.peek_policy_for_account(account.id) == nil do
  {:ok, _} = Policies.seed_policy(account.id, user.id)
  IO.puts(IO.ANSI.cyan() <> "✓ Seeded default policy" <> IO.ANSI.reset())
end

system_subject = Subject.system(account)

# -- Invited teammates ------------------------------------------------

owner_subject = Subject.for_user(
  user,
  account,
  %Emisar.Accounts.Membership{role: "owner", user_id: user.id, account_id: account.id}
)

invite_member = fn email, full_name, role ->
  case Accounts.fetch_user_by_email(email) do
    {:ok, %User{} = u} ->
      u

    {:error, :not_found} ->
      {:ok, %{user: invited, membership: m}} =
        Accounts.invite_user_to_account(email, role, owner_subject)

      {:ok, _u} = Accounts.update_user_profile(invited, %{full_name: full_name}, system_subject)
      {:ok, confirmed} = Accounts.confirm_user(invited)
      {:ok, _m} = Accounts.mark_invitation_accepted(m)
      confirmed
  end
end

alex = invite_member.("alex@emisar.dev", "Alex Kim", "admin")
sam = invite_member.("sam@emisar.dev", "Sam Patel", "operator")
IO.puts(IO.ANSI.cyan() <> "✓ Teammates: alex (admin), sam (operator)" <> IO.ANSI.reset())

# -- Sample runbook (skip if exists) ---------------------------------

unless (
         {:ok, list, _} = Runbooks.list_runbooks(system_subject)
         Enum.find(list, &(&1.slug == "cassandra-rolling-repair"))
       ) do
  {:ok, _rb} =
    Runbooks.create_runbook(
      %{
        name: "cassandra-rolling-repair",
        slug: "cassandra-rolling-repair",
        title: "Cassandra rolling repair",
        description: "Pre-flight check → run nodetool repair on each Cassandra node in turn.",
        status: "published",
        definition: %{
          "steps" => [
            %{
              "id" => "preflight",
              "action_id" => "cassandra.nodetool_status",
              "runner_selector" => %{"group" => "cassandra-us-east1"}
            },
            %{
              "id" => "assert_healthy",
              "kind" => "assert",
              "expression" => "preflight.exit_code == 0"
            },
            %{
              "id" => "repair",
              "action_id" => "cassandra.nodetool_repair",
              "runner_selector" => %{"group" => "cassandra-us-east1"},
              "args" => %{"keyspace" => "system_auth"}
            }
          ]
        }
      },
      system_subject
    )

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded sample runbook" <> IO.ANSI.reset())
end

# -- Runners ----------------------------------------------------------
#
# Mix of states so RunnersLive + dashboard show variety. We won't try
# to "really" connect them — just stamp the DB row in the right state.

runner_specs = [
  %{name: "cass-prod-01", group: "cassandra-us-east1", hostname: "ip-10-0-1-12", state: :connected, version: "0.4.1", last_seen_min: 1, action_load: 0},
  %{name: "cass-prod-02", group: "cassandra-us-east1", hostname: "ip-10-0-1-13", state: :connected, version: "0.4.1", last_seen_min: 2, action_load: 1},
  %{name: "cass-prod-03", group: "cassandra-us-east1", hostname: "ip-10-0-1-14", state: :disconnected, version: "0.4.0", last_seen_min: 42, action_load: 0},
  %{name: "db-prod-01", group: "db-prod", hostname: "ip-10-0-2-7", state: :connected, version: "0.4.1", last_seen_min: 1, action_load: 0},
  %{name: "db-prod-02", group: "db-prod", hostname: "ip-10-0-2-8", state: :disconnected, version: "0.4.0", last_seen_min: 95, action_load: 0},
  %{name: "edge-west-01", group: "edge-us-west", hostname: "ip-10-1-0-3", state: :disabled, version: "0.3.9", last_seen_min: 7 * 24 * 60, action_load: 0}
]

# Use create_runner; idempotent via (account_id, name) unique index.
ensure_runner = fn spec ->
  {:ok, all_runners, _} = Runners.list_runners_for_account(owner_subject)

  case Enum.find(all_runners, &(&1.name == spec.name)) do
    %{} = existing ->
      existing

    nil ->
      {:ok, r} =
        Runners.create_runner(%{
          "name" => spec.name,
          "group" => spec.group,
          "hostname" => spec.hostname,
          "runner_version" => spec.version
        }, owner_subject)

      r
  end
end

stamp_runner_state = fn runner, spec ->
  # Bypass the lifecycle API; we want exact backdated timestamps.
  seen_at = mins_ago.(spec.last_seen_min)

  attrs =
    case spec.state do
      :connected ->
        %{
          status: "connected",
          last_connected_at: seen_at,
          last_heartbeat_at: seen_at,
          action_load: spec.action_load
        }

      :disconnected ->
        %{
          status: "disconnected",
          last_connected_at: mins_ago.(spec.last_seen_min + 60),
          last_disconnected_at: seen_at,
          last_disconnect_reason: "websocket dropped",
          last_heartbeat_at: seen_at,
          action_load: 0
        }

      :disabled ->
        %{
          status: "disabled",
          last_connected_at: days_ago.(8),
          last_heartbeat_at: days_ago.(7),
          disabled_at: days_ago.(7),
          action_load: 0
        }
    end

  runner
  |> Ecto.Changeset.change(attrs)
  |> Repo.update!()
end

runners =
  Enum.map(runner_specs, fn spec ->
    spec |> ensure_runner.() |> stamp_runner_state.(spec)
  end)

IO.puts(IO.ANSI.cyan() <> "✓ Seeded #{length(runners)} runners" <> IO.ANSI.reset())

# -- Catalog: actions on each runner ---------------------------------

cass_actions = [
  %{
    "id" => "cassandra.nodetool_status",
    "title" => "nodetool status",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Show cluster gossip + load.",
    "side_effects" => [],
    "args" => []
  },
  %{
    "id" => "cassandra.nodetool_repair",
    "title" => "nodetool repair",
    "kind" => "exec",
    "risk" => "high",
    "description" => "Run an anti-entropy repair on a keyspace.",
    "side_effects" => ["disk_io", "network_traffic"],
    "args" => [%{"name" => "keyspace", "type" => "string", "required" => true}]
  },
  %{
    "id" => "cassandra.flush",
    "title" => "nodetool flush",
    "kind" => "exec",
    "risk" => "medium",
    "description" => "Flush memtables to SSTables.",
    "side_effects" => ["disk_io"],
    "args" => [%{"name" => "keyspace", "type" => "string", "required" => false}]
  },
  %{
    "id" => "cassandra.drain",
    "title" => "nodetool drain",
    "kind" => "exec",
    "risk" => "critical",
    "description" => "Stop accepting writes (precedes shutdown).",
    "side_effects" => ["downtime"],
    "args" => []
  }
]

db_actions = [
  %{
    "id" => "postgres.uptime",
    "title" => "postgres uptime",
    "kind" => "exec",
    "risk" => "low",
    "description" => "pg_stat_database — uptime + connection count.",
    "side_effects" => [],
    "args" => []
  },
  %{
    "id" => "postgres.vacuum",
    "title" => "vacuum analyze",
    "kind" => "exec",
    "risk" => "medium",
    "description" => "VACUUM ANALYZE on a table.",
    "side_effects" => ["disk_io"],
    "args" => [%{"name" => "table", "type" => "string", "required" => true}]
  },
  %{
    "id" => "postgres.kill_idle",
    "title" => "kill idle connections",
    "kind" => "exec",
    "risk" => "high",
    "description" => "Terminate connections idle > 30 min.",
    "side_effects" => ["disconnects_clients"],
    "args" => []
  }
]

linux_actions = [
  %{
    "id" => "linux.uptime",
    "title" => "uptime",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Show uptime + load average.",
    "side_effects" => [],
    "args" => []
  },
  %{
    "id" => "linux.disk_usage",
    "title" => "df -h",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Show filesystem usage.",
    "side_effects" => [],
    "args" => []
  }
]

advertise = fn runner, actions ->
  payload = %{
    "hostname" => runner.hostname,
    "labels" => runner.labels || %{},
    "version" => runner.runner_version,
    "packs" => %{
      "showcase" => %{"version" => "0.4.1", "hash" => "sha256:seed"}
    },
    "actions" => Enum.map(actions, &Map.put(&1, "pack_id", "showcase"))
  }

  {:ok, _} = Catalog.observe_state(runner, payload)
end

Enum.each(runners, fn r ->
  case r.group do
    "cassandra-us-east1" -> advertise.(r, cass_actions ++ linux_actions)
    "db-prod" -> advertise.(r, db_actions ++ linux_actions)
    _ -> advertise.(r, linux_actions)
  end
end)

IO.puts(IO.ANSI.cyan() <> "✓ Advertised actions on every runner" <> IO.ANSI.reset())

# -- Runs across various states --------------------------------------
#
# Skip everything below if any runs already exist — we don't want
# duplicate seed data to pile up on re-runs.

policy = Policies.peek_policy_for_account(account.id)

connected = Enum.filter(runners, &(&1.status == "connected"))
[cass1, cass2 | _] = Enum.filter(connected, &(&1.group == "cassandra-us-east1"))
[db1 | _] = Enum.filter(connected, &(&1.group == "db-prod"))

existing_runs =
  case Runs.list_recent_runs(system_subject, limit: 1) do
    {:ok, list, _meta} -> list
    _ -> []
  end

if existing_runs == [] do
  insert_run = fn attrs ->
    {:ok, run} =
      attrs
      |> Map.merge(%{
        account_id: account.id,
        source: attrs[:source] || "operator",
        requested_by_id: attrs[:requested_by_id] || user.id,
        policy_id: policy && policy.id,
        policy_decision: attrs[:policy_decision] || "allow",
        policy_reason: attrs[:policy_reason] || "tier default for low: allow"
      })
      |> Runs.create_run()

    run
  end

  # Backdate a run by editing the row after insertion.
  backdate = fn run, datetime ->
    run
    |> Ecto.Changeset.change(inserted_at: datetime, queued_at: datetime)
    |> Repo.update!()
  end

  finalize_success = fn run, finished_at, duration_ms ->
    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "success",
        "exit_code" => 0,
        "duration_ms" => duration_ms,
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(finished_at: finished_at, sent_at: DateTime.add(finished_at, -duration_ms, :millisecond))
    |> Repo.update!()
  end

  finalize_failure = fn run, finished_at, exit_code, reason ->
    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "failed",
        "exit_code" => exit_code,
        "duration_ms" => 4500,
        "reason" => reason,
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(finished_at: finished_at)
    |> Repo.update!()
  end

  # Successful runs across the last ~36 hours.
  successes = [
    {cass1, "cassandra.nodetool_status", mins_ago.(8), 2300, %{}, sam},
    {cass2, "cassandra.nodetool_status", mins_ago.(25), 2100, %{}, sam},
    {cass1, "linux.uptime", mins_ago.(50), 320, %{}, user},
    {db1, "postgres.uptime", hours_ago.(2), 410, %{}, user},
    {cass1, "cassandra.flush", hours_ago.(5), 8200, %{"keyspace" => "user_data"}, alex},
    {db1, "postgres.vacuum", hours_ago.(11), 41_000, %{"table" => "events"}, alex},
    {cass2, "linux.disk_usage", hours_ago.(20), 280, %{}, sam},
    {db1, "postgres.uptime", hours_ago.(30), 390, %{}, user}
  ]

  Enum.each(successes, fn {runner, action_id, started_at, dur_ms, args, who} ->
    finished_at = DateTime.add(started_at, dur_ms, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: "scheduled check",
      requested_by_id: who.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_success.(finished_at, dur_ms)
  end)

  # In-flight runs — leave in "running" state.
  Enum.each(
    [
      {cass1, "cassandra.flush", mins_ago.(2), %{"keyspace" => "system_auth"}, alex},
      {cass2, "linux.disk_usage", mins_ago.(1), %{}, sam},
      {db1, "postgres.kill_idle", mins_ago.(1), %{}, alex}
    ],
    fn {runner, action_id, started_at, args, who} ->
      insert_run.(%{
        runner_id: runner.id,
        action_id: action_id,
        args: args,
        reason: "investigating prod latency",
        requested_by_id: who.id,
        status: "running"
      })
      |> backdate.(started_at)
      |> Ecto.Changeset.change(sent_at: started_at, started_at: started_at)
      |> Repo.update!()
    end
  )

  # Two failures so the dashboard "Recent failures" tile lights up.
  failed_specs = [
    {cass2, "cassandra.flush", mins_ago.(40), 1, "node unreachable", %{"keyspace" => "ghost_ks"}, sam},
    {db1, "postgres.vacuum", hours_ago.(3), 1, "permission denied for table audit", %{"table" => "audit"}, alex}
  ]

  Enum.each(failed_specs, fn {runner, action_id, started_at, exit_code, reason, args, who} ->
    finished_at = DateTime.add(started_at, 4500, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: "manual investigation",
      requested_by_id: who.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_failure.(finished_at, exit_code, reason)
  end)

  # One cancelled run.
  cancelled =
    insert_run.(%{
      runner_id: cass1.id,
      action_id: "cassandra.nodetool_repair",
      args: %{"keyspace" => "system_auth"},
      reason: "rolling repair",
      requested_by_id: alex.id,
      status: "running"
    })
    |> backdate.(hours_ago.(8))

  {:ok, _} = Runs.mark_cancelled(cancelled, "operator cancelled — repair window moved")

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded 14 runs across success/running/failed/cancelled states" <> IO.ANSI.reset())

  # -- Pending approvals (so dashboard "Needs attention" lights up) ---

  pending1 =
    insert_run.(%{
      runner_id: cass1.id,
      action_id: "cassandra.nodetool_repair",
      args: %{"keyspace" => "user_data"},
      reason: "monthly user_data repair",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "tier default for high: require_approval"
    })
    |> backdate.(mins_ago.(5))

  {:ok, _req1} =
    Approvals.create_request(
      Repo.preload(pending1, []),
      sam.id,
      "Operator-requested rolling repair on user_data — needs admin sign-off because risk=high"
    )

  pending2 =
    insert_run.(%{
      runner_id: db1.id,
      action_id: "postgres.kill_idle",
      args: %{},
      reason: "freeing connection pool",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "tier default for high: require_approval"
    })
    |> backdate.(mins_ago.(18))

  {:ok, _req2} =
    Approvals.create_request(
      Repo.preload(pending2, []),
      sam.id,
      "Pool is at 95% — need to free idle backends before alerts fire"
    )

  # An already-approved one (just to show history in the approvals
  # list filter when an operator clicks "Approved").
  approved_run =
    insert_run.(%{
      runner_id: cass1.id,
      action_id: "cassandra.nodetool_repair",
      args: %{"keyspace" => "system_auth"},
      reason: "scheduled monthly repair",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "tier default for high: require_approval"
    })
    |> backdate.(hours_ago.(26))

  {:ok, %ApprovalRequest{} = approved_req} =
    Approvals.create_request(approved_run, sam.id, "monthly system_auth repair")

  # Manually mark approved (don't actually dispatch) + backdate the
  # decision so it doesn't pollute "pending" lists.
  approved_req
  |> Ecto.Changeset.change(
    status: "approved",
    decided_by_id: alex.id,
    decided_at: hours_ago.(25),
    decision_reason: "windowed, system_auth repair OK"
  )
  |> Repo.update!()

  approved_run
  |> Ecto.Changeset.change(status: "success", finished_at: hours_ago.(24))
  |> Repo.update!()

  # A denied one too.
  denied_run =
    insert_run.(%{
      runner_id: cass2.id,
      action_id: "cassandra.drain",
      args: %{},
      reason: "node retirement",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "tier default for critical: deny"
    })
    |> backdate.(days_ago.(2))

  {:ok, denied_req} =
    Approvals.create_request(denied_run, sam.id, "draining cass-prod-02 for hardware replacement")

  denied_req
  |> Ecto.Changeset.change(
    status: "denied",
    decided_by_id: user.id,
    decided_at: days_ago.(2),
    decision_reason: "Use the runbook — manual drain is risky."
  )
  |> Repo.update!()

  denied_run
  |> Ecto.Changeset.change(status: "cancelled", finished_at: days_ago.(2))
  |> Repo.update!()

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded 2 pending + 1 approved + 1 denied approval requests" <> IO.ANSI.reset())

  # -- Standing grants ------------------------------------------------
  #
  # Mint an API key + a couple of grants tied to it, so the Grants
  # page has rows to render.

  {:ok, _raw, api_key} =
    Emisar.ApiKeys.mint_quick_key(owner_subject,
      name: "Demo MCP key"
    )

  # Anchor each grant to the real `approved_req` row above — the
  # `approval_request_id` FK rejects synthetic IDs. The synthetic
  # `run` shape is still fine because Grant doesn't FK on it (just
  # copies action_id/runner_id/api_key_id/args_sha256 off the map).
  for {action, scope, duration} <- [
        {"cassandra.nodetool_status", :any_args, :ninety_days},
        {"postgres.vacuum", :exact_args, :thirty_days}
      ] do
    fake_run = %{
      account_id: account.id,
      api_key_id: api_key.id,
      runner_id: if(action =~ "postgres", do: db1.id, else: cass1.id),
      action_id: action,
      args_sha256: :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower)
    }

    {:ok, _grant} =
      Approvals.create_grant(approved_req, fake_run, user.id, %{
        duration: duration,
        scope: scope
      })
  end

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded 2 standing grants" <> IO.ANSI.reset())

  # -- A handful of plain audit events --------------------------------
  #
  # Most of the above already wrote audit rows (approval.*, runner.*,
  # run.*); add a couple of operator-action events so the audit page
  # shows variety.

  Audit.log(account.id, "user.signed_in",
    actor_kind: "user",
    actor_id: alex.id,
    payload: %{ip: "203.0.113.42"}
  )

  Audit.log(account.id, "runner.disabled",
    actor_kind: "user",
    actor_id: user.id,
    subject_kind: "runner",
    subject_id: List.last(runners).id,
    subject_label: "edge-west-01",
    payload: %{reason: "decommissioned"}
  )
end

# -- Bootstrap auth key (unchanged) ----------------------------------

case Runners.list_auth_keys(owner_subject) do
  {:ok, [], _} ->
    case System.get_env("EMISAR_DEV_FIXED_AUTH_KEY") do
      fixed when is_binary(fixed) and byte_size(fixed) >= 27 ->
        {:ok, _key} =
          Runners.create_auth_key_with_secret(fixed, account.id, user.id, %{
            description: "Dev fixed auth key (docker-compose)",
            group: "cassandra-us-east1",
            reusable: true
          })

        IO.puts(IO.ANSI.green() <> "✓ Seeded dev fixed auth key" <> IO.ANSI.reset())

      _ ->
        {:ok, raw, _key} =
          Runners.create_auth_key(%{
            description: "Demo auth key",
            group: "cassandra-us-east1",
            reusable: true
          }, owner_subject)

        IO.puts("")
        IO.puts(IO.ANSI.green() <> "Bootstrap a runner:" <> IO.ANSI.reset())
        IO.puts("  curl -sSL https://emisar.dev/install.sh | sudo EMISAR_AUTH_KEY=#{raw} bash")
        IO.puts("")
    end

    Audit.log(account.id, "auth_key.created",
      actor_kind: "system",
      subject_kind: "auth_key",
      payload: %{seeded: true}
    )

  _ ->
    :ok
end
