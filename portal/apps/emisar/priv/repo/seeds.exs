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

# Aggregate stream chunks: total byte size and sha256 of the
# concatenation. Used to populate ActionRun.{stdout,stderr}_{bytes,sha256}
# so the meta strip reads believably.
chunks_bytes = fn chunks, stream ->
  chunks
  |> Enum.filter(fn {s, _} -> s == stream end)
  |> Enum.reduce(0, fn {_, t}, acc -> acc + byte_size(t) end)
end

chunks_sha = fn chunks, stream ->
  blob =
    chunks
    |> Enum.filter(fn {s, _} -> s == stream end)
    |> Enum.map(fn {_, t} -> t end)
    |> Enum.join("")

  case blob do
    "" -> nil
    _ -> :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
  end
end

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

owner_subject =
  Subject.for_user(
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
         Enum.find(list, &(&1.slug == "nightly-edge-health"))
       ) do
  {:ok, _rb} =
    Runbooks.create_runbook(
      %{
        name: "nightly-edge-health",
        slug: "nightly-edge-health",
        title: "Nightly edge fleet health",
        description:
          "Routine 03:00 UTC sweep across every edge runner: uptime + disk usage. " <>
            "Used by oncall to confirm fleet health before the EU traffic peak.",
        status: "published",
        definition: %{
          "steps" => [
            %{
              "id" => "uptime",
              "action_id" => "linux.uptime",
              "runner_selector" => %{"group" => "edge-eu"}
            },
            %{
              "id" => "disk",
              "action_id" => "linux.disk_usage",
              "runner_selector" => %{"group" => "edge-eu"}
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
# Three personality-rich runners that DON'T collide with the docker-
# compose stack (which boots its own `runner-1` / `-2` / `-3` rows).
# This gives the dashboard a realistic mix:
#
#   * a dev laptop that connected once and then closed — typical
#     "operator tested locally" stragglers
#   * a CI bot that runs lint/deploy actions on every push
#   * an edge node humming along in production
#
# The fake "cass-prod-*" / "db-prod-*" / "edge-west-01" rows the old
# seed inserted are gone — they were never going to connect against
# the docker stack and just made the dashboard look stale.

runner_specs = [
  %{
    name: "andrew-mbp",
    group: "laptops",
    hostname: "Andrews-MacBook-Pro.local",
    labels: %{"env" => "dev", "owner" => "andrew"},
    state: :disconnected,
    disconnect_reason: "operator closed lid",
    version: "0.4.1",
    last_seen_min: 95,
    action_load: 0
  },
  %{
    name: "ci-bot-runner",
    group: "ci",
    hostname: "github-actions-runner-04",
    labels: %{"env" => "ci", "purpose" => "lint+deploy"},
    state: :connected,
    version: "0.4.1",
    last_seen_min: 1,
    action_load: 0
  },
  %{
    name: "edge-pop-fra",
    group: "edge-eu",
    hostname: "vmi-fra-3.colocrossing.net",
    labels: %{"region" => "eu-central", "tier" => "edge"},
    state: :connected,
    version: "0.4.1",
    last_seen_min: 2,
    action_load: 1
  }
]

# Use create_runner; idempotent via (account_id, name) unique index.
ensure_runner = fn spec ->
  {:ok, all_runners, _} = Runners.list_runners_for_account(owner_subject)

  case Enum.find(all_runners, &(&1.name == spec.name)) do
    %{} = existing ->
      existing

    nil ->
      {:ok, r} =
        Runners.create_runner(
          %{
            "name" => spec.name,
            "group" => spec.group,
            "hostname" => spec.hostname,
            "labels" => spec.labels,
            "runner_version" => spec.version
          },
          owner_subject
        )

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
          last_disconnect_reason: spec[:disconnect_reason] || "websocket dropped",
          last_heartbeat_at: seen_at,
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

IO.puts(
  IO.ANSI.cyan() <>
    "✓ Seeded #{length(runners)} demo runners (docker runners self-register on boot)" <>
    IO.ANSI.reset()
)

# -- Catalog: actions on each runner ---------------------------------

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
  },
  %{
    "id" => "linux.journalctl_tail",
    "title" => "journalctl tail",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Tail the systemd journal for one unit.",
    "side_effects" => [],
    "args" => [
      %{"name" => "unit", "type" => "string", "required" => true},
      %{"name" => "lines", "type" => "integer", "required" => false}
    ]
  }
]

ci_actions = [
  %{
    "id" => "ci.lint",
    "title" => "Lint repository",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Run mix credo + dialyzer on the current checkout.",
    "side_effects" => [],
    "args" => []
  },
  %{
    "id" => "ci.deploy_canary",
    "title" => "Deploy canary",
    "kind" => "exec",
    "risk" => "high",
    "description" => "Promote the current main HEAD to the canary fleet.",
    "side_effects" => ["state_change", "external_call"],
    "args" => [
      %{"name" => "fleet", "type" => "string", "required" => true},
      %{"name" => "sha", "type" => "string", "required" => true}
    ]
  }
]

edge_actions = [
  %{
    "id" => "nginx.status",
    "title" => "nginx -s status",
    "kind" => "exec",
    "risk" => "low",
    "description" => "Report worker processes + active connections.",
    "side_effects" => [],
    "args" => []
  },
  %{
    "id" => "nginx.reload",
    "title" => "nginx -s reload",
    "kind" => "exec",
    "risk" => "medium",
    "description" => "Gracefully reload nginx after a config change.",
    "side_effects" => ["state_change"],
    "args" => []
  },
  %{
    "id" => "cache.purge",
    "title" => "Purge CDN cache",
    "kind" => "exec",
    "risk" => "high",
    "description" => "Invalidate a path prefix on the local edge cache.",
    "side_effects" => ["state_change", "external_call"],
    "args" => [%{"name" => "prefix", "type" => "string", "required" => true}]
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
    "ci" -> advertise.(r, ci_actions ++ linux_actions)
    "edge-eu" -> advertise.(r, edge_actions ++ linux_actions)
    _ -> advertise.(r, linux_actions)
  end
end)

IO.puts(IO.ANSI.cyan() <> "✓ Advertised actions on every runner" <> IO.ANSI.reset())

# -- Runs across various states --------------------------------------
#
# Skip everything below if any runs already exist — we don't want
# duplicate seed data to pile up on re-runs.

policy = Policies.peek_policy_for_account(account.id)

# Pull each seeded runner out by name so the run-seeding code reads
# like prose. Connected ones can take fresh in-flight runs; the
# disconnected laptop only holds historical rows.
laptop = Enum.find(runners, &(&1.name == "andrew-mbp"))
ci = Enum.find(runners, &(&1.name == "ci-bot-runner"))
edge = Enum.find(runners, &(&1.name == "edge-pop-fra"))

# -- LLM-bridge API key (an "agent") --------------------------------
#
# A personality-rich MCP key so the agents page has a real-looking
# row and we can attribute some of the historical runs to it. The
# audit log entries the create_key call writes give the Audit page
# an actor=api_key example, too.

{:ok, _raw_agent, agent_key} =
  Emisar.ApiKeys.create_key(
    %{
      name: "Claude — Andrew's terminal",
      description:
        "MCP bridge running under Claude Desktop on andrew-mbp. " <>
          "Used for ad-hoc edge cache purges and disk-usage checks.",
      scopes: ["actions:read", "actions:execute"],
      runner_group_filter: ["edge-eu"]
    },
    owner_subject
  )

IO.puts(IO.ANSI.cyan() <> "✓ Seeded MCP API key for the LLM agent" <> IO.ANSI.reset())

# -- Audit-export key ------------------------------------------------
#
# Mirrors the "Mint export token" button on the audit page so a
# freshly-seeded demo account already shows what the SIEM workflow
# looks like — a separate row on the agents page, scoped to
# `audit:read` and nothing else, with no runner restrictions because
# the audit endpoint doesn't dispatch to runners.

{:ok, _raw_export, _export_key} =
  Emisar.ApiKeys.create_key(
    %{
      name: "SIEM export — initial",
      description:
        "Streams audit events as NDJSON to the company SIEM. " <>
          "Read-only — no dispatch rights.",
      scopes: ["audit:read"]
    },
    owner_subject
  )

IO.puts(IO.ANSI.cyan() <> "✓ Seeded audit-export API key" <> IO.ANSI.reset())

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
        policy_reason: attrs[:policy_reason] || "Default for low-risk actions"
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

  # Append a synthetic stdout/stderr chunk to a run so the RunDetail
  # output panel shows realistic terminal output. `seq` is the unique
  # per-run sequence; chunks render in seq order.
  append_chunks = fn run, chunks ->
    Enum.with_index(chunks, 1)
    |> Enum.each(fn {{stream, text}, seq} ->
      {:ok, _} =
        Runs.append_event(run, %{
          seq: seq,
          kind: "progress",
          stream: stream,
          payload: %{"chunk" => text}
        })
    end)
  end

  # Wrap finalize_success to take the realistic-output blob too, and
  # update bytes/sha so the meta strip reads believably.
  finalize_success = fn run, finished_at, duration_ms, chunks ->
    append_chunks.(run, chunks)

    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "success",
        "exit_code" => 0,
        "duration_ms" => duration_ms,
        "stdout_bytes" => chunks_bytes.(chunks, "stdout"),
        "stderr_bytes" => chunks_bytes.(chunks, "stderr"),
        "stdout_sha256" => chunks_sha.(chunks, "stdout"),
        "stderr_sha256" => chunks_sha.(chunks, "stderr"),
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(
      finished_at: finished_at,
      sent_at: DateTime.add(finished_at, -duration_ms, :millisecond)
    )
    |> Repo.update!()
  end

  finalize_failure = fn run, finished_at, exit_code, reason, chunks ->
    append_chunks.(run, chunks)

    {:ok, run} =
      Runs.mark_finished(run, %{
        "status" => "failed",
        "exit_code" => exit_code,
        "duration_ms" => 4500,
        "reason" => reason,
        "stdout_bytes" => chunks_bytes.(chunks, "stdout"),
        "stderr_bytes" => chunks_bytes.(chunks, "stderr"),
        "stdout_sha256" => chunks_sha.(chunks, "stdout"),
        "stderr_sha256" => chunks_sha.(chunks, "stderr"),
        "event_id" => "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(finished_at: finished_at)
    |> Repo.update!()
  end

  # Realistic synthetic output per action — built once, reused below.
  # Each entry is a list of `{stream, chunk_text}` tuples. The
  # RunDetail panel renders stderr in rose so failures stand out.
  uptime_stdout = [
    {"stdout", " 14:02:31 up 18 days,  4:11,  3 users,  load average: 0.41, 0.28, 0.22\n"}
  ]

  df_stdout = [
    {"stdout",
     "Filesystem      Size  Used Avail Use% Mounted on\n" <>
       "/dev/nvme0n1p1  457G  221G  213G  51% /\n" <>
       "tmpfs            16G  124M   16G   1% /run\n" <>
       "/dev/nvme0n1p2  1.8T  1.4T  316G  82% /var/lib/data\n"}
  ]

  nginx_status_stdout = [
    {"stdout",
     "Active connections: 142\n" <>
       "server accepts handled requests\n" <>
       " 91824 91824 304117\n" <>
       "Reading: 0 Writing: 4 Waiting: 138\n"}
  ]

  cache_purge_stdout = [
    {"stdout", "→ purging /static/css/* on edge-pop-fra…\n"},
    {"stdout", "✓ purged 1284 cached objects in 312ms\n"}
  ]

  lint_stdout = [
    {"stdout", "Compiling 17 files (.ex)\n"},
    {"stdout", "Checking 17 files...\n"},
    {"stdout", "  Found 0 issues (282 mods, 1.4s)\n"}
  ]

  lint_failure_output = [
    {"stdout", "Compiling 17 files (.ex)\n"},
    {"stderr",
     "** (CompileError) lib/emisar/runs.ex:621: undefined function policy_attrs/4\n" <>
       "    (emisar 0.4.1) lib/emisar/runs.ex:621: Emisar.Runs.dispatch_run/2\n"},
    {"stderr", "Compilation failed.\n"}
  ]

  journalctl_stdout = [
    {"stdout",
     "-- Logs begin at Sat 2026-05-30 09:01:00 UTC. --\n" <>
       "May 30 13:51:02 ip-10-1-0-3 nginx[1184]: 2026/05/30 13:51:02 [notice] 1184#1184: signal process started\n" <>
       "May 30 13:55:14 ip-10-1-0-3 nginx[1184]: 2026/05/30 13:55:14 [warn] 1184#1184: 8 worker_connections are not enough\n"}
  ]

  deploy_canary_output = [
    {"stdout", "→ resolving canary fleet 'eu-canary'…\n"},
    {"stdout", "  · resolved 2 hosts: edge-pop-fra, edge-pop-ams\n"},
    {"stdout", "→ pulling image emisar/edge:9a7c4f0\n"},
    {"stdout", "→ rolling restart\n"},
    {"stdout", "  · edge-pop-fra: drained 142 conns, restart OK (2.1s)\n"},
    {"stdout", "  · edge-pop-ams: drained 138 conns, restart OK (2.4s)\n"},
    {"stdout", "✓ canary healthy on 2/2 hosts\n"}
  ]

  # Successful operator-driven runs across the last 36 hours.
  successes = [
    {edge, "linux.uptime", mins_ago.(8), 320, %{}, sam, "operator", nil, uptime_stdout},
    {ci, "ci.lint", mins_ago.(35), 5400, %{}, alex, "operator", nil, lint_stdout},
    {edge, "linux.disk_usage", mins_ago.(50), 280, %{}, user, "operator", nil, df_stdout},
    {laptop, "linux.uptime", hours_ago.(2), 410, %{}, user, "operator", nil, uptime_stdout},
    {edge, "nginx.status", hours_ago.(5), 740, %{}, alex, "operator", nil, nginx_status_stdout},
    {ci, "linux.disk_usage", hours_ago.(11), 290, %{}, alex, "operator", nil, df_stdout},
    {edge, "linux.journalctl_tail", hours_ago.(20), 410, %{"unit" => "nginx", "lines" => 100},
     sam, "operator", nil, journalctl_stdout}
  ]

  # MCP/agent-driven runs — these are what Claude dispatches over the
  # bridge. source: "mcp", api_key_id is the agent key. Reason text
  # includes the LLM's prompt summary so it's obvious in the UI who
  # asked.
  agent_runs = [
    {edge, "linux.disk_usage", mins_ago.(12), 260, %{}, "Andrew via Claude: 'is fra disk OK?'",
     df_stdout},
    {edge, "nginx.status", mins_ago.(18), 690, %{},
     "Andrew via Claude: 'why is fra throwing 502s?'", nginx_status_stdout},
    {edge, "cache.purge", hours_ago.(3), 312, %{"prefix" => "/static/css/"},
     "Andrew via Claude: 'flush the CSS cache after the deploy'", cache_purge_stdout}
  ]

  Enum.each(successes, fn {runner, action_id, started_at, dur_ms, args, who, _source, _api_key_id,
                           chunks} ->
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
    |> finalize_success.(finished_at, dur_ms, chunks)
  end)

  Enum.each(agent_runs, fn {runner, action_id, started_at, dur_ms, args, reason, chunks} ->
    finished_at = DateTime.add(started_at, dur_ms, :millisecond)

    insert_run.(%{
      runner_id: runner.id,
      action_id: action_id,
      args: args,
      reason: reason,
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "running"
    })
    |> backdate.(started_at)
    |> finalize_success.(finished_at, dur_ms, chunks)
  end)

  # In-flight runs — leave in "running" state. CI bot mid-lint,
  # operator pulling logs.
  Enum.each(
    [
      {ci, "ci.lint", mins_ago.(2), %{}, alex, "operator", nil},
      {edge, "linux.journalctl_tail", mins_ago.(1), %{"unit" => "nginx", "lines" => 50}, sam,
       "operator", nil}
    ],
    fn {runner, action_id, started_at, args, who, source, api_key_id} ->
      insert_run.(%{
        runner_id: runner.id,
        action_id: action_id,
        args: args,
        reason: "investigating prod 502s",
        requested_by_id: who.id,
        source: source,
        api_key_id: api_key_id,
        status: "running"
      })
      |> backdate.(started_at)
      |> Ecto.Changeset.change(sent_at: started_at, started_at: started_at)
      |> Repo.update!()
    end
  )

  # Two failures so the dashboard "Recent failures" tile lights up.
  failed_specs = [
    {ci, "ci.lint", mins_ago.(40), 1, "compilation error on lib/emisar/runs.ex:621", %{}, alex,
     lint_failure_output},
    {edge, "cache.purge", hours_ago.(3), 1, "upstream cache API returned 503",
     %{"prefix" => "/api/v1/"}, sam,
     [
       {"stdout", "→ purging /api/v1/ on edge-pop-fra…\n"},
       {"stderr", "✗ upstream returned 503 service unavailable after 3 retries\n"}
     ]}
  ]

  Enum.each(failed_specs, fn {runner, action_id, started_at, exit_code, reason, args, who, chunks} ->
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
    |> finalize_failure.(finished_at, exit_code, reason, chunks)
  end)

  # One cancelled run — half-deployed canary, operator hit cancel
  # mid-rollout. Append the partial output so the RunDetail panel
  # shows where it got to before cancellation.
  cancelled =
    insert_run.(%{
      runner_id: ci.id,
      action_id: "ci.deploy_canary",
      args: %{"fleet" => "eu-canary", "sha" => "9a7c4f0"},
      reason: "canary rollout",
      requested_by_id: alex.id,
      status: "running"
    })
    |> backdate.(hours_ago.(8))

  # The first 3 chunks — operator hit cancel right as the rolling
  # restart kicked off.
  append_chunks.(cancelled, Enum.take(deploy_canary_output, 3))

  {:ok, _} =
    Runs.mark_cancelled(cancelled, "operator cancelled — rolling back to previous SHA")

  IO.puts(
    IO.ANSI.cyan() <>
      "✓ Seeded #{length(successes) + length(agent_runs)} successes (#{length(agent_runs)} via MCP agent), 2 in-flight, 2 failed, 1 cancelled" <>
      IO.ANSI.reset()
  )

  # -- Pending approvals (so dashboard "Needs attention" lights up) ---
  #
  # Mix of human-initiated + agent-initiated requests so the approvals
  # page shows both shapes. Sam files the routine one; Claude (the
  # MCP agent) tries a high-risk cache purge and gets held.

  pending1 =
    insert_run.(%{
      runner_id: edge.id,
      action_id: "nginx.reload",
      args: %{},
      reason: "post-deploy nginx reload",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Default for medium-risk actions"
    })
    |> backdate.(mins_ago.(5))

  {:ok, _req1} =
    Approvals.create_request(
      Repo.preload(pending1, []),
      sam.id,
      "Picked up the new nginx config from the canary deploy — needs an admin to bless the reload."
    )

  # Agent-initiated pending — note source: "mcp", api_key_id set.
  pending2 =
    insert_run.(%{
      runner_id: edge.id,
      action_id: "cache.purge",
      args: %{"prefix" => "/static/"},
      reason: "Andrew via Claude: 'something cached looks stale, can you flush /static?'",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Default for high-risk actions"
    })
    |> backdate.(mins_ago.(18))

  {:ok, _req2} =
    Approvals.create_request(
      Repo.preload(pending2, []),
      user.id,
      "Agent-initiated purge of /static/. Risk=high because it can briefly miss-rate the whole site."
    )

  # An already-approved one (just to show history in the approvals
  # list filter when an operator clicks "Approved").
  approved_run =
    insert_run.(%{
      runner_id: ci.id,
      action_id: "ci.deploy_canary",
      args: %{"fleet" => "eu-canary", "sha" => "9a7c4f0"},
      reason: "main → canary, deploy job #4218",
      requested_by_id: sam.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Default for high-risk actions"
    })
    |> backdate.(hours_ago.(26))

  {:ok, %ApprovalRequest{} = approved_req} =
    Approvals.create_request(approved_run, sam.id, "canary rollout for SHA 9a7c4f0")

  # Manually mark approved (don't actually dispatch) + backdate the
  # decision so it doesn't pollute "pending" lists.
  approved_req
  |> Ecto.Changeset.change(
    status: "approved",
    decided_by_id: alex.id,
    decided_at: hours_ago.(25),
    decision_reason: "matches the deploy window, smoke tests green"
  )
  |> Repo.update!()

  approved_run
  |> Ecto.Changeset.change(status: "success", finished_at: hours_ago.(24))
  |> Repo.update!()

  # A denied one too.
  denied_run =
    insert_run.(%{
      runner_id: laptop.id,
      action_id: "linux.disk_usage",
      args: %{},
      reason: "Andrew via Claude: 'check andrew-mbp disk before backup'",
      requested_by_id: user.id,
      source: "mcp",
      api_key_id: agent_key.id,
      status: "awaiting_approval",
      requires_approval: true,
      policy_decision: "require_approval",
      policy_reason: "Override: deny-laptop-from-agent"
    })
    |> backdate.(days_ago.(2))

  {:ok, denied_req} =
    Approvals.create_request(
      denied_run,
      user.id,
      "Agent tried to peek at the dev laptop — denied by policy override."
    )

  denied_req
  |> Ecto.Changeset.change(
    status: "denied",
    decided_by_id: user.id,
    decided_at: days_ago.(2),
    decision_reason: "Agents shouldn't be running anything on the laptops group."
  )
  |> Repo.update!()

  denied_run
  |> Ecto.Changeset.change(status: "cancelled", finished_at: days_ago.(2))
  |> Repo.update!()

  IO.puts(
    IO.ANSI.cyan() <>
      "✓ Seeded 2 pending (1 from agent) + 1 approved + 1 denied approval requests" <>
      IO.ANSI.reset()
  )

  # -- Standing grants ------------------------------------------------
  #
  # Two grants tied to the agent key — so the LLM can call these
  # specific actions without re-asking. Demonstrates the "ask once,
  # then run autonomously" workflow on the Grants page.

  for {action, runner_id, scope, duration} <- [
        {"linux.disk_usage", edge.id, :any_args, :ninety_days},
        {"nginx.status", edge.id, :exact_args, :thirty_days}
      ] do
    fake_run = %{
      account_id: account.id,
      api_key_id: agent_key.id,
      runner_id: runner_id,
      action_id: action,
      args_sha256: :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower)
    }

    {:ok, _grant} =
      Approvals.create_grant(approved_req, fake_run, user.id, %{
        duration: duration,
        scope: scope
      })
  end

  IO.puts(IO.ANSI.cyan() <> "✓ Seeded 2 standing grants for the agent" <> IO.ANSI.reset())

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
    subject_id: laptop.id,
    subject_label: laptop.name,
    payload: %{reason: "operator closed lid"}
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
            group: "dev-docker",
            reusable: true
          })

        IO.puts(IO.ANSI.green() <> "✓ Seeded dev fixed auth key" <> IO.ANSI.reset())

      _ ->
        {:ok, raw, _key} =
          Runners.create_auth_key(
            %{
              description: "Demo auth key",
              group: "edge-eu",
              reusable: true
            },
            owner_subject
          )

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
