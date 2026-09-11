defmodule Emisar.Seeds.ActionRuns do
  @moduledoc """
  Action runs across every state the console shows: recent successes by
  operators and by the MCP agent, one old failure, one old cancellation, the
  pending / approved / denied approval stories with their audit trails, the
  agent's standing grants, and one typed JSON run.
  """

  alias Emisar.Approvals
  alias Emisar.Approvals.Request, as: ApprovalRequest
  alias Emisar.Audit
  alias Emisar.Catalog
  alias Emisar.OutputSchema
  alias Emisar.Repo
  alias Emisar.Runners
  alias Emisar.Runs
  alias Emisar.Runs.ActionRun
  alias Emisar.Seeds.{Fleet, Helpers}

  @require_approval "The account policy requires approval for high-risk actions by default."

  # Realistic synthetic output per action — built once, reused below.
  # Each entry is a list of `{stream, chunk_text}` tuples.
  @uptime_stdout [
    {"stdout", " 14:02:31 up 18 days,  4:11,  3 users,  load average: 0.41, 0.28, 0.22\n"}
  ]

  @df_stdout [
    {"stdout",
     "Filesystem      Size  Used Avail Use% Mounted on\n" <>
       "/dev/nvme0n1p1  457G  221G  213G  51% /\n" <>
       "tmpfs            16G  124M   16G   1% /run\n" <>
       "/dev/nvme0n1p2  1.8T  1.4T  316G  82% /var/lib/data\n"}
  ]

  @caddy_upstreams_stdout [
    {"stdout",
     Jason.encode!(%{
       "upstreams" => [
         %{"address" => "10.42.8.12:8443", "healthy" => true, "requests" => 1284},
         %{"address" => "10.42.8.13:8443", "healthy" => true, "requests" => 1198}
       ]
     }) <> "\n"}
  ]

  @caddy_access_stdout [
    {"stdout", "203.0.113.21 - - \"GET /checkout\" 200 4821 34ms\n"},
    {"stdout", "198.51.100.44 - - \"POST /api/cart\" 200 812 41ms\n"},
    {"stdout", "203.0.113.29 - - \"GET /assets/app.css\" 304 0 2ms\n"}
  ]

  # Timestamp-free on purpose: the approved-story run is re-dated relative to
  # each seed, and a hardcoded date inside the log lines would contradict it.
  @caddy_reload_stdout [
    {"stdout", "INFO using adjacent Caddyfile\n"},
    {"stdout", "INFO autosaved config\n"},
    {"stdout", "INFO serving initial configuration\n"}
  ]

  @caddy_validate_failure [
    {"stderr",
     "Error: adapting config using caddyfile: upstream app-blue.internal:8443: no healthy SRV records\n"}
  ]

  @journalctl_stdout [
    {"stdout",
     "-- Logs begin at Sat 2026-05-30 09:01:00 UTC. --\n" <>
       "Jun 24 13:51:02 api-iad-02 checkout-api[1184]: latency budget recovered p95=184ms\n" <>
       "Jun 24 13:55:14 api-iad-02 checkout-api[1184]: deploy marker sha=6b7c19d\n"}
  ]

  @postgres_lag_stdout [
    {"stdout", "checkout-read-1|10.42.12.41|streaming|async|0|16384\n"},
    {"stdout", "checkout-read-2|10.42.12.42|streaming|async|0|32768\n"}
  ]

  @postgres_vacuum_stdout [
    {"stdout", "public|orders|1842021|12804|0.69|2026-06-24 10:41:02|2026-06-24 13:20:11\n"},
    {"stdout", "public|carts|931044|8092|0.86|2026-06-24 09:12:18|2026-06-24 13:04:52\n"}
  ]

  @systemd_failed_stdout [
    {"stdout", "0 loaded units listed.\n"}
  ]

  @systemd_restart_output [
    {"stdout", "Stopping checkout-api.service...\n"},
    {"stdout", "Started checkout-api.service.\n"}
  ]

  @doc """
  Seeds the run history, unless the account already has runs — we don't want
  duplicate seed data to pile up on re-runs.
  """
  def run(%{owner_subject: owner_subject} = ctx) do
    existing_runs =
      case Runs.list_recent_runs(owner_subject, limit: 1) do
        {:ok, list, _meta} -> list
        _ -> []
      end

    if existing_runs == [] do
      seed_history(ctx)
    end

    :ok
  end

  defp seed_history(ctx) do
    seed_finished_runs(ctx)
    approved_req = seed_approval_stories(ctx)
    seed_standing_grants(ctx, approved_req)
    seed_sign_in_events(ctx)
  end

  # Pull each seeded runner out by name so the run-seeding code reads
  # like prose.
  defp runner_named(%{runners: runners}, name), do: Enum.find(runners, &(&1.name == name))

  # A live dispatch snapshots the pack contract on the run (pack_ref +
  # expected_pack_hash); the approve-time trust recheck compares the CURRENT
  # catalog hash against that snapshot, so a pending run seeded without one
  # can never be approved (the /security screencast take approves one live).
  # Stamp from the advertised catalog row directly — the seeded advertisement
  # carries the same baseline hash a live runner re-advertises, and the strict
  # dispatch resolver is the APPROVER's gate, not the seeder's. A non-catalog
  # action (nothing advertised) stays snapshot-free like a legacy run.
  defp contract_attrs(%{account: account}, runner_id, action_id) do
    with {:ok, action} <- Catalog.fetch_action_for_account(action_id, runner_id, account.id),
         true <-
           is_binary(action.pack_id) and is_binary(action.pack_version) and
             is_binary(action.pack_hash),
         {:ok, pack_ref} <-
           Catalog.MCPProjection.pack_ref(action.pack_id, action.pack_version, action.pack_hash) do
      %{pack_ref: pack_ref, expected_pack_hash: action.pack_hash}
    else
      _ -> %{}
    end
  end

  defp insert_run(%{account: account, user: user, policy: policy} = ctx, attrs) do
    {:ok, run} =
      ctx
      |> contract_attrs(attrs.runner_id, attrs.action_id)
      |> Map.merge(attrs)
      |> Map.merge(%{
        account_id: account.id,
        source: attrs[:source] || "operator",
        requested_by_id: attrs[:requested_by_id] || user.id,
        policy_id: policy && policy.id,
        policy_decision: attrs[:policy_decision] || "allow",
        policy_reason:
          attrs[:policy_reason] || "The account policy allows low-risk actions by default."
      })
      |> Runs.create_run()

    run
  end

  # Backdate a run by editing the row after insertion.
  defp backdate(run, datetime) do
    run
    |> Ecto.Changeset.change(inserted_at: datetime, queued_at: datetime)
    |> Repo.update!()
  end

  # `finished_at` may come from the caller (a backdated run) — the audit row is
  # stamped at that same moment so the demo audit timeline matches the runs it
  # records instead of bunching every event at seed time.
  defp persist_terminal_run(run, status, attrs) do
    changeset =
      ActionRun.Changeset.transition(run, status, Map.put_new(attrs, :finished_at, Helpers.now()))

    {:ok, %{run: run}} =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:run, changeset)
      |> Ecto.Multi.run(:audit, fn repo, %{run: run} ->
        run
        |> Audit.run_event_changeset()
        |> Ecto.Changeset.change(occurred_at: run.finished_at)
        |> repo.insert()
      end)
      |> Repo.commit_multi()

    run
  end

  defp backdate_request(request, requested_at) do
    request
    |> Ecto.Changeset.change(
      requested_at: requested_at,
      expires_at: DateTime.add(requested_at, 24 * 3600, :second)
    )
    |> Repo.update!()
  end

  # `Runs.create_run` writes the `action_run.pending_approval` hold row at seed
  # time; move it back to the request's claimed moment so the audit timeline
  # stays causally ordered (awaiting -> decided -> terminal).
  defp backdate_dispatch_audit(run, occurred_at) do
    Audit.Event.Query.all()
    |> Repo.all()
    |> Enum.filter(&(&1.request_id == run.request_id))
    |> Enum.each(fn event ->
      event |> Ecto.Changeset.change(occurred_at: occurred_at) |> Repo.update!()
    end)
  end

  # Append a synthetic stdout/stderr chunk to a run so the RunDetail
  # output panel shows realistic terminal output. `seq` is the unique
  # per-run sequence; chunks render in seq order.
  defp append_chunks(run, chunks) do
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
  # update byte counts so the meta strip reads believably.
  defp finalize_success(run, finished_at, duration_ms, chunks) do
    append_chunks(run, chunks)

    run =
      persist_terminal_run(run, :success, %{
        finished_at: finished_at,
        exit_code: 0,
        duration_ms: duration_ms,
        emitted_stdout_bytes: Helpers.chunks_bytes(chunks, "stdout"),
        emitted_stderr_bytes: Helpers.chunks_bytes(chunks, "stderr"),
        output_complete: true,
        event_id: "seed-" <> Ecto.UUID.generate()
      })

    run
    |> Ecto.Changeset.change(sent_at: DateTime.add(finished_at, -duration_ms, :millisecond))
    |> Repo.update!()
  end

  defp finalize_failure(run, finished_at, exit_code, reason, chunks) do
    append_chunks(run, chunks)

    persist_terminal_run(run, :failed, %{
      finished_at: finished_at,
      exit_code: exit_code,
      duration_ms: 4500,
      error_message: reason,
      emitted_stdout_bytes: Helpers.chunks_bytes(chunks, "stdout"),
      emitted_stderr_bytes: Helpers.chunks_bytes(chunks, "stderr"),
      output_complete: true,
      event_id: "seed-" <> Ecto.UUID.generate()
    })
  end

  # -- Finished runs ----------------------------------------------------

  defp seed_finished_runs(%{user: user, jordan: jordan, priya: priya, agent_key: agent_key} = ctx) do
    edge = runner_named(ctx, "edge-fra-01")
    api = runner_named(ctx, "api-iad-02")
    database = runner_named(ctx, "pg-primary-iad")

    # Successful operator-driven runs across the last 36 hours.
    successes = [
      {edge, "linux.uptime", Helpers.mins_ago(8), 320, %{}, priya, "morning edge readiness",
       @uptime_stdout},
      {edge, "caddy.reverse_proxy_upstreams", Helpers.mins_ago(24), 610, %{}, jordan,
       "verify checkout upstream health after deploy", @caddy_upstreams_stdout},
      {database, "postgres.replication_lag", Helpers.mins_ago(46), 840, %{}, user,
       "confirm replicas caught up after catalog import", @postgres_lag_stdout},
      {api, "systemd.failed_units", Helpers.hours_ago(3), 530, %{}, priya,
       "pre-handoff health sweep", @systemd_failed_stdout},
      {database, "postgres.vacuum_status", Helpers.hours_ago(7), 1200,
       %{"schema" => "public", "limit" => 20}, jordan, "check autovacuum before traffic peak",
       @postgres_vacuum_stdout},
      {edge, "linux.disk_usage", Helpers.hours_ago(12), 280, %{"paths" => ["/", "/var/log"]},
       user, "weekly capacity check", @df_stdout},
      {api, "linux.journalctl", Helpers.hours_ago(19), 900,
       %{"unit" => "checkout-api.service", "since" => "2h", "priority" => "warning"}, priya,
       "review checkout-api warnings after release", @journalctl_stdout}
    ]

    # MCP/agent-driven runs — these are what Claude dispatches over the
    # bridge. source: "mcp", api_key_id is the agent key. Reason text
    # includes the LLM's prompt summary so it's obvious in the UI who
    # asked.
    agent_runs = [
      {edge, "caddy.access_log_tail", Helpers.mins_ago(14), 260, %{"lines" => 50},
       "Maya via Claude: summarize checkout traffic after the deploy", @caddy_access_stdout},
      {edge, "caddy.reverse_proxy_upstreams", Helpers.mins_ago(31), 690, %{},
       "Maya via Claude: check whether edge upstreams are healthy", @caddy_upstreams_stdout},
      {database, "postgres.replication_lag", Helpers.hours_ago(2), 620, %{},
       "Maya via Claude: confirm replica lag before the email campaign", @postgres_lag_stdout}
    ]

    Enum.each(successes, fn {runner, action_id, started_at, dur_ms, args, who, reason, chunks} ->
      finished_at = DateTime.add(started_at, dur_ms, :millisecond)

      Helpers.seed_terminal_history(fn ->
        ctx
        |> insert_run(%{
          runner_id: runner.id,
          action_id: action_id,
          args: args,
          reason: reason,
          requested_by_id: who.id,
          status: "running"
        })
        |> backdate(started_at)
        |> finalize_success(finished_at, dur_ms, chunks)
      end)
    end)

    Enum.each(agent_runs, fn {runner, action_id, started_at, dur_ms, args, reason, chunks} ->
      finished_at = DateTime.add(started_at, dur_ms, :millisecond)

      Helpers.seed_terminal_history(fn ->
        ctx
        |> insert_run(%{
          runner_id: runner.id,
          action_id: action_id,
          args: args,
          reason: reason,
          requested_by_id: user.id,
          source: "mcp",
          api_key_id: agent_key.id,
          status: "running"
        })
        |> backdate(started_at)
        |> finalize_success(finished_at, dur_ms, chunks)
      end)
    end)

    # A single old failure for filters/detail screenshots. It is outside the
    # dashboard's 24h headline so the default account reads healthy.
    failed_specs = [
      {edge, "caddy.validate_config", Helpers.days_ago(5), 1,
       "config validation failed before reload", %{"file" => "/etc/caddy/Caddyfile"}, jordan,
       @caddy_validate_failure}
    ]

    Enum.each(failed_specs, fn {runner, action_id, started_at, exit_code, reason, args, who,
                                chunks} ->
      finished_at = DateTime.add(started_at, 4500, :millisecond)

      Helpers.seed_terminal_history(fn ->
        ctx
        |> insert_run(%{
          runner_id: runner.id,
          action_id: action_id,
          args: args,
          reason: "manual investigation",
          requested_by_id: who.id,
          status: "running"
        })
        |> backdate(started_at)
        |> finalize_failure(finished_at, exit_code, reason, chunks)
      end)
    end)

    # One old cancelled run. It gives the Runs filters a realistic terminal
    # non-error without putting a fresh warning on the dashboard.
    cancelled_at = Helpers.days_ago(3)

    Helpers.seed_terminal_history(fn ->
      cancelled =
        ctx
        |> insert_run(%{
          runner_id: api.id,
          action_id: "systemd.unit_restart",
          args: %{"unit" => "checkout-api.service"},
          reason: "cancel after canary rollback completed elsewhere",
          requested_by_id: jordan.id,
          status: "running"
        })
        |> backdate(cancelled_at)

      append_chunks(cancelled, @systemd_restart_output)

      cancelled
      |> persist_terminal_run(:cancelled, %{
        finished_at: cancelled_at,
        cancelled_at: cancelled_at
      })
      |> Ecto.Changeset.change(reason_text: "operator cancelled - rollback already completed")
      |> Repo.update!()
    end)

    Helpers.say(
      "✓ Seeded #{length(successes) + length(agent_runs)} recent successes (#{length(agent_runs)} via MCP agent), 1 old failure, 1 old cancellation"
    )
  end

  # -- Pending approvals (so dashboard "Needs attention" lights up) ---
  #
  # Mix of human-initiated + agent-initiated requests so the approvals
  # page shows both shapes. Claude (the MCP agent) asks for the caddy
  # reload — the same recurring action the approved story below already
  # ran, so the /security screencast frames read as one continuous loop —
  # and Priya files the high-risk restart herself.
  #
  # Returns the approved request, which the standing grants hang off.
  defp seed_approval_stories(
         %{account: account, user: user, jordan: jordan, priya: priya, agent_key: agent_key} =
           ctx
       ) do
    edge = runner_named(ctx, "edge-fra-01")
    api = runner_named(ctx, "api-iad-02")
    database = runner_named(ctx, "pg-primary-iad")

    # The decider for the approved/denied stories below. Their audit rows are
    # seeded through the same `Audit.Events` builders the real approve/deny
    # flow uses, so the demo audit shows the complete trail
    # (awaiting -> decided -> terminal), not just the hold.
    jordan_subject = Helpers.subject_for(account, jordan)

    pending1_at = Helpers.mins_ago(6)

    pending1 =
      ctx
      |> insert_run(%{
        runner_id: edge.id,
        action_id: "caddy.reload_config",
        args: %{"file" => "/etc/caddy/Caddyfile"},
        reason: "Maya via Claude: apply the checked-in Caddyfile after certificate renewal",
        requested_by_id: user.id,
        source: "mcp",
        api_key_id: agent_key.id,
        status: "pending_approval",
        requires_approval: true,
        policy_decision: "require_approval",
        policy_reason: @require_approval
      })
      |> backdate(pending1_at)

    {:ok, req1} =
      Approvals.create_request(
        pending1,
        user.id,
        pending1.reason
      )

    backdate_request(req1, pending1_at)
    backdate_dispatch_audit(pending1, pending1_at)

    pending2_at = Helpers.mins_ago(22)

    pending2 =
      ctx
      |> insert_run(%{
        runner_id: api.id,
        action_id: "systemd.unit_restart",
        args: %{"unit" => "checkout-api.service"},
        reason: "restart checkout-api after deploy smoke test",
        requested_by_id: priya.id,
        status: "pending_approval",
        requires_approval: true,
        policy_decision: "require_approval",
        policy_reason: @require_approval
      })
      |> backdate(pending2_at)

    {:ok, req2} =
      Approvals.create_request(
        pending2,
        priya.id,
        pending2.reason
      )

    backdate_request(req2, pending2_at)
    backdate_dispatch_audit(pending2, pending2_at)

    # The approved-and-executed story: requested by the agent, approved by
    # Jordan, run to success minutes later. Its decision + terminal audit rows
    # are stamped newer than every other terminal event (4-5m vs 8m+), so the
    # audit timeline keeps the whole loop at its top no matter how long after
    # seeding a capture runs. The /security screencast frames this request, its
    # run, and its trail.
    approved_at = Helpers.mins_ago(12)
    approved_decided_at = Helpers.mins_ago(5)
    approved_finished_at = Helpers.mins_ago(4)
    approved_decision_reason = "validated config, active connections drained, deploy window open"

    approved_run =
      ctx
      |> insert_run(%{
        runner_id: edge.id,
        action_id: "caddy.reload_config",
        args: %{"file" => "/etc/caddy/Caddyfile"},
        reason: "Maya via Claude: reload Caddy after config validation",
        requested_by_id: user.id,
        source: "mcp",
        api_key_id: agent_key.id,
        status: "pending_approval",
        requires_approval: true,
        policy_decision: "require_approval",
        policy_reason: @require_approval
      })
      |> backdate(approved_at)

    {:ok, %ApprovalRequest{} = approved_req} =
      Approvals.create_request(approved_run, user.id, approved_run.reason)

    approved_req = backdate_request(approved_req, approved_at)
    backdate_dispatch_audit(approved_run, approved_at)

    # Manually mark approved (don't actually dispatch) + backdate the
    # decision so it doesn't pollute "pending" lists.
    approved_req =
      approved_req
      |> Ecto.Changeset.change(
        status: :approved,
        decided_by_id: jordan.id,
        decided_at: approved_decided_at,
        decision_reason: approved_decision_reason
      )
      |> Repo.update!()

    Audit.Events.approval_approved(
      jordan_subject,
      approved_req,
      approved_decision_reason,
      nil,
      nil
    )
    |> Ecto.Changeset.change(occurred_at: approved_decided_at)
    |> Repo.insert!()

    append_chunks(approved_run, @caddy_reload_stdout)

    approved_run =
      approved_run
      |> Ecto.Changeset.change(
        status: :success,
        sent_at: DateTime.add(approved_finished_at, -2, :second),
        started_at: DateTime.add(approved_finished_at, -2, :second),
        finished_at: approved_finished_at,
        exit_code: 0,
        duration_ms: 1820,
        emitted_stdout_bytes: Helpers.chunks_bytes(@caddy_reload_stdout, "stdout"),
        emitted_stderr_bytes: Helpers.chunks_bytes(@caddy_reload_stdout, "stderr"),
        output_complete: true
      )
      |> Repo.update!()

    approved_run
    |> Audit.run_event_changeset()
    |> Ecto.Changeset.change(occurred_at: approved_finished_at)
    |> Repo.insert!()

    # A denied one too.
    denied_at = Helpers.days_ago(3)
    denied_decision_reason = "Wait for the DBA-approved change window."

    denied_run =
      ctx
      |> insert_run(%{
        runner_id: database.id,
        action_id: "postgres.reload_conf",
        args: %{},
        reason: "Maya via Claude: reload Postgres config before change ticket is approved",
        requested_by_id: user.id,
        source: "mcp",
        api_key_id: agent_key.id,
        status: "pending_approval",
        requires_approval: true,
        policy_decision: "require_approval",
        policy_reason: @require_approval
      })
      |> backdate(denied_at)

    {:ok, denied_req} =
      Approvals.create_request(
        denied_run,
        user.id,
        denied_run.reason
      )

    denied_req = backdate_request(denied_req, denied_at)
    backdate_dispatch_audit(denied_run, denied_at)

    denied_req =
      denied_req
      |> Ecto.Changeset.change(
        status: :denied,
        decided_by_id: jordan.id,
        decided_at: denied_at,
        decision_reason: denied_decision_reason
      )
      |> Repo.update!()

    Audit.Events.approval_denied(jordan_subject, denied_req, denied_decision_reason)
    |> Ecto.Changeset.change(occurred_at: denied_at)
    |> Repo.insert!()

    denied_run =
      denied_run
      |> Ecto.Changeset.change(
        status: :cancelled,
        finished_at: denied_at,
        cancelled_at: denied_at,
        reason_text: "approval denied: " <> denied_decision_reason
      )
      |> Repo.update!()

    denied_run
    |> Audit.run_event_changeset()
    |> Ecto.Changeset.change(occurred_at: denied_at)
    |> Repo.insert!()

    Helpers.say("✓ Seeded 2 pending (1 from agent) + 1 approved + 1 denied approval requests")

    approved_req
  end

  # -- Standing grants ------------------------------------------------
  #
  # Two grants tied to the agent key — so the LLM can call these
  # specific actions without re-asking. Demonstrates the "ask once,
  # then run autonomously" workflow on the Grants page.
  defp seed_standing_grants(
         %{account: account, user: user, agent_key: agent_key} = ctx,
         approved_req
       ) do
    edge = runner_named(ctx, "edge-fra-01")
    database = runner_named(ctx, "pg-primary-iad")
    overrides = Fleet.pack_version_overrides()

    for {pack_id, action, runner_id, scope, duration} <- [
          {"caddy", "caddy.access_log_tail", edge.id, :any_args, :thirty_days},
          {"postgres", "postgres.replication_lag", database.id, :any_args, :thirty_days}
        ] do
      %{"version" => version, "hash" => hash} =
        Helpers.pack_descriptor(pack_id, overrides[pack_id])

      fake_run = %Runs.ActionRun{
        account_id: account.id,
        api_key_id: agent_key.id,
        runner_id: runner_id,
        action_id: action,
        pack_ref: "#{pack_id}@#{version}/#{hash}",
        args_sha256: :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower)
      }

      {:ok, _grant} =
        Approvals.create_grant(approved_req, fake_run, user.id, %{
          duration: duration,
          scope: scope
        })
    end

    Helpers.say("✓ Seeded 2 standing grants for the agent")
  end

  # -- A handful of plain audit events --------------------------------
  #
  # Most of the above already wrote audit rows (approval.*, runner.*,
  # run.*); add a couple of operator-action events so the audit page
  # shows variety.
  defp seed_sign_in_events(%{account: account, jordan: jordan, priya: priya}) do
    Audit.log(account.id, "user.signed_in",
      actor_kind: "user",
      actor_id: jordan.id,
      payload: %{ip: "203.0.113.42"}
    )

    Audit.log(account.id, "user.signed_in",
      actor_kind: "user",
      actor_id: priya.id,
      payload: %{ip: "198.51.100.17"}
    )
  end

  # -- Typed JSON run ---------------------------------------------------

  @doc """
  One real typed action result keeps the run-detail Raw/JSON presentation
  visible in every reseeded demo. Uses the descriptor's own schema rather than
  labeling merely JSON-looking stdout as typed output.
  """
  def seed_typed_json_run(%{
        account: account,
        user: user,
        owner_subject: owner_subject,
        policy: policy
      }) do
    typed_demo_reason = "review the sanitized Compose topology before a deployment"
    {:ok, typed_demo_runner} = Runners.fetch_runner_by_name("api-iad-02", owner_subject)

    {:ok, typed_demo_action} =
      Catalog.fetch_action_for_account(
        "docker.compose_config",
        typed_demo_runner.id,
        account.id
      )

    %{} = typed_demo_schema = typed_demo_action.output_schema

    typed_demo_output = %{
      "valid" => true,
      "file" => "/opt/northstar/docker-compose.yml",
      "services" => ["api", "worker"],
      "images" => [
        "ghcr.io/northstar/api:2026.08.20",
        "ghcr.io/northstar/worker:2026.08.20"
      ],
      "networks" => ["backend", "frontend"],
      "volumes" => ["postgres-data"],
      "profiles" => ["observability"],
      "truncated" => %{
        "services" => 0,
        "images" => 0,
        "networks" => 0,
        "volumes" => 0,
        "profiles" => 0
      }
    }

    :ok = OutputSchema.validate_instance(typed_demo_schema, typed_demo_output)

    typed_demo_run =
      ActionRun.Query.all()
      |> ActionRun.Query.by_account_id(account.id)
      |> ActionRun.Query.by_runner_id(typed_demo_runner.id)
      |> ActionRun.Query.by_action_id(typed_demo_action.action_id)
      |> Repo.all()
      |> Enum.find(&(&1.reason == typed_demo_reason))

    typed_demo_run =
      case typed_demo_run do
        nil ->
          {:ok, run} =
            Repo.transaction(fn ->
              {:ok, pack_ref} =
                Catalog.MCPProjection.pack_ref(
                  typed_demo_action.pack_id,
                  typed_demo_action.pack_version,
                  typed_demo_action.pack_hash
                )

              started_at = Helpers.mins_ago(18)
              finished_at = DateTime.add(started_at, 740, :millisecond)
              stdout = Jason.encode!(typed_demo_output) <> "\n"
              chunks = [{"stdout", stdout}]

              {:ok, run} =
                Runs.create_run(%{
                  account_id: account.id,
                  runner_id: typed_demo_runner.id,
                  action_id: typed_demo_action.action_id,
                  args: %{"file" => "/opt/northstar/docker-compose.yml"},
                  reason: typed_demo_reason,
                  source: "operator",
                  requested_by_id: user.id,
                  pack_ref: pack_ref,
                  expected_pack_hash: typed_demo_action.pack_hash,
                  structured_output_expected: true,
                  output_schema_snapshot: typed_demo_schema,
                  policy_id: policy && policy.id,
                  policy_decision: "allow",
                  policy_reason: "The account policy allows low-risk actions by default.",
                  status: "running"
                })

              run =
                run
                |> Ecto.Changeset.change(inserted_at: started_at, queued_at: started_at)
                |> Repo.update!()

              {:ok, _event} =
                Runs.append_event(run, %{
                  seq: 1,
                  kind: "progress",
                  stream: "stdout",
                  payload: %{"chunk" => stdout}
                })

              {:ok, %{run: run}} =
                Ecto.Multi.new()
                |> Ecto.Multi.update(
                  :run,
                  ActionRun.Changeset.transition(run, :success, %{
                    sent_at: started_at,
                    started_at: started_at,
                    finished_at: finished_at,
                    exit_code: 0,
                    duration_ms: 740,
                    emitted_stdout_bytes: Helpers.chunks_bytes(chunks, "stdout"),
                    emitted_stderr_bytes: 0,
                    output_complete: true,
                    structured_output: typed_demo_output,
                    event_id: "seed-" <> Ecto.UUID.generate()
                  })
                )
                |> Ecto.Multi.run(:audit, fn repo, %{run: completed} ->
                  completed
                  |> Audit.run_event_changeset()
                  |> Ecto.Changeset.change(occurred_at: completed.finished_at)
                  |> repo.insert()
                end)
                |> Repo.commit_multi()

              run
            end)

          run

        run ->
          run
      end

    Helpers.say("✓ Typed JSON run ready at /app/demo/runs/#{typed_demo_run.id}")
  end
end
