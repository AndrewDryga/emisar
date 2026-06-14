defmodule Emisar.RunsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Repo, Runs}
  alias Emisar.Runs.{ActionRun, RunEvent}

  defp base_attrs(account_id, runner_id, attrs \\ %{}) do
    Map.merge(
      %{
        runner_id: runner_id,
        action_id: "linux.uptime",
        args: %{},
        reason: "test",
        source: "operator",
        account_id: account_id
      },
      attrs
    )
  end

  defp deny_all_rules do
    %{
      "schema_version" => 2,
      "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
      "overrides" => []
    }
  end

  describe "create_run/1" do
    test "auto-assigns request_id + queued_at" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      assert {:ok, %ActionRun{} = run} = Runs.create_run(base_attrs(account.id, runner.id))
      assert String.starts_with?(run.request_id, "req_")
      assert %DateTime{} = run.queued_at
    end

    test "second insert with same (api_key_id, idempotency_key) returns {:replay, original}" do
      # Closes the TOCTOU race in dispatch_run: the pre-flight peek is a
      # best-effort optimization; the unique index `(api_key_id,
      # idempotency_key)` is the actual correctness guarantee. When two
      # racing callers both miss the peek and try to insert, one wins
      # the index and the other gets back the winner's row instead of a
      # confusing constraint changeset.
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {_raw, key} = api_key_fixture(account_id: account.id)

      attrs =
        base_attrs(account.id, runner.id, %{
          source: "mcp",
          api_key_id: key.id,
          idempotency_key: "idem-#{System.unique_integer([:positive])}"
        })

      assert {:ok, %ActionRun{} = original} = Runs.create_run(attrs)
      assert {:replay, %ActionRun{id: replayed_id}} = Runs.create_run(attrs)

      assert replayed_id == original.id
    end

    test "a different idempotency_key on the same api_key inserts a second row" do
      # Sanity-check the unique index isn't overreaching: same key, new
      # idempotency_key → new row, not a replay.
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {_raw, key} = api_key_fixture(account_id: account.id)

      attrs1 =
        base_attrs(account.id, runner.id, %{
          source: "mcp",
          api_key_id: key.id,
          idempotency_key: "idem-a"
        })

      attrs2 = %{attrs1 | source: "mcp"} |> Map.put(:idempotency_key, "idem-b")

      assert {:ok, %ActionRun{id: a_id}} = Runs.create_run(attrs1)
      assert {:ok, %ActionRun{id: b_id}} = Runs.create_run(attrs2)

      refute a_id == b_id
    end

    test "two calls with nil idempotency_key never replay (null != null in unique index)" do
      # Without an Idempotency-Key the unique constraint is partial
      # (`where idempotency_key IS NOT NULL`), so two non-MCP calls don't
      # accidentally collide. Run_id is the only uniqueness gate, and
      # `Runs.generate_request_id/0` produces UUIDs so collisions are
      # essentially impossible.
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      attrs = base_attrs(account.id, runner.id)

      assert {:ok, %ActionRun{id: a_id}} = Runs.create_run(attrs)
      assert {:ok, %ActionRun{id: b_id}} = Runs.create_run(attrs)

      refute a_id == b_id
    end
  end

  describe "dispatch_run/2" do
    test "allow policy returns {:ok, :running, run} and delivers to runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert run.account_id == account.id

      # Cloud-to-runner envelope was delivered.
      assert_receive {:cloud_to_runner, %{"type" => "run_action", "action_id" => "linux.uptime"}},
                     500
    end

    test "a viewer (view-only) is refused — dispatch executes infra, so it gates on :dispatch" do
      # A viewer holds only `view_runs_permission`; dispatching is the
      # most dangerous write in the system (it runs real infra), so the
      # permission gate must reject before any runner/policy lookup.
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "audits only the policy decision + terminal outcome, decision first" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      types = events |> Enum.filter(&(&1.subject_id == run.id)) |> Enum.map(& &1.event_type)

      # The decision and the outcome — and none of the intermediate
      # lifecycle noise (pending/sent/running).
      assert Enum.sort(types) == ["action_run.success", "policy.evaluated"]
      refute "action_run.pending" in types
      refute "action_run.sent" in types
      refute "action_run.running" in types

      # Policy is recorded no later than the run it gated.
      evaluated = Enum.find(events, &(&1.event_type == "policy.evaluated"))
      success = Enum.find(events, &(&1.event_type == "action_run.success"))
      assert DateTime.compare(evaluated.occurred_at, success.occurred_at) in [:lt, :eq]
    end

    test "wire envelope carries trusted pack hash when one is on file" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      # Drive the catalog through `observe_state` so pack_version is
      # populated on the action AND a PackVersion row exists. Custom
      # packs land pending — operator approves before dispatch can
      # carry the trusted hash on the wire.
      :ok =
        case Emisar.Catalog.observe_state(runner, %{
               "hostname" => "h",
               "version" => "0.1",
               "labels" => %{},
               "packs" => %{
                 "linux-core" => %{"version" => "1.2.3", "hash" => "sha256:CLOUD_TRUSTED"}
               },
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "low",
                   "description" => "t",
                   "args" => []
                 }
               ]
             }) do
          {:ok, _} -> :ok
        end

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      assert {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      _ = policy_fixture(account_id: account.id)

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, _run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["expected_pack_hash"] == "sha256:CLOUD_TRUSTED"
    end

    test "rejects dispatch when the action is not advertised by the runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :action_not_found} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )
    end

    test "rejects dispatch to a soft-deleted runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      # Soft-delete the runner (sets deleted_at). The dispatch gate runs
      # before the action-advertised check, so a deleted runner is refused
      # as :runner_not_found rather than slipping through to execution.
      {:ok, _} = runner |> Emisar.Runners.Runner.Changeset.delete() |> Emisar.Repo.update()
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :runner_not_found} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )
    end

    test "policy sees the catalog's risk, not what the caller passes" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      # Catalog says high risk.
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")

      # Policy: require approval for high.
      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      # Caller spoofs `risk: "low"` — should be ignored.
      attrs = base_attrs(account.id, runner.id, %{risk: "low"})
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, :pending_approval, _run} =
               Runs.dispatch_run(attrs, subject)
    end

    test "require_approval policy stores the run as pending + creates a request" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "allow",
              "critical" => "allow"
            },
            "overrides" => [
              %{"name" => "needs-approval", "action" => "*", "decision" => "require_approval"}
            ]
          }
        )

      requester = user_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, :pending_approval, %ActionRun{status: :pending_approval} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{requested_by_id: requester.id}),
                 subject
               )

      assert {:ok, [_req], _} = Approvals.list_pending_approval_requests(subject)
      assert {:ok, %{status: :pending_approval}} = Runs.fetch_run_by_id(run.id, subject)
    end

    test "policy with no matching allow rule denies and records the attempt for audit" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)

      # Policy only allows cassandra.* actions; the dispatched
      # `linux.uptime` doesn't match, so it falls through to the
      # tier defaults — which are all `deny` here.
      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => [
              %{"name" => "cassandra-only", "action" => "cassandra.*", "decision" => "allow"}
            ]
          }
        )

      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :denied_by_policy, reason} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert is_binary(reason)
      # A denied run is recorded with status="denied" so operators can
      # see attempts in the audit log.
      assert {:ok, [%{status: :denied, policy_decision: "deny"}], _meta} =
               Runs.list_recent_runs(subject, limit: 50)
    end

    test "stamps policy_version on the dispatched run so audit can correlate vN edits" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      policy = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 subject
               )

      assert run.policy_id == policy.id
      assert run.policy_version == policy.vsn
    end
  end

  describe "dispatch_run/2 resolves per-runner / per-group policy overrides" do
    test "a runner-scoped override governs that runner, replacing the account allow" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, group: "db")
      _ = action_fixture(runner: runner)
      owner = subject_for(user_fixture(), account, role: :owner)

      # Account policy allows everything; this runner's override denies it.
      _ = policy_fixture(account_id: account.id)
      {:ok, _} = Emisar.Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, owner)

      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), owner)

      assert {:ok, [%{status: :denied, policy_decision: "deny"}], _meta} =
               Runs.list_recent_runs(owner, limit: 50)
    end

    test "a group-scoped override governs its group; other groups keep the account default" do
      account = account_fixture()
      db_runner = runner_fixture(account_id: account.id, group: "db")
      web_runner = runner_fixture(account_id: account.id, group: "web")
      _ = action_fixture(runner: db_runner)
      _ = action_fixture(runner: web_runner)
      owner = subject_for(user_fixture(), account, role: :owner)

      _ = policy_fixture(account_id: account.id)
      {:ok, _} = Emisar.Policies.save_scoped_rules(deny_all_rules(), :group, "db", owner)

      # The db-group runner is denied by the group override…
      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, db_runner.id), owner)

      # …while a web-group runner falls through to the allowing account default.
      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, web_runner.id), owner)
    end
  end

  describe "mark_finished/2 runbook continuation" do
    test "a next-wave step that fails to dispatch writes a runbook.step_dispatch_failed audit row" do
      # Regression: a continuation that can't dispatch (denied / out-of-scope /
      # unknown action) used to stop the runbook with NO audit event and NO
      # signal — operators couldn't see WHY it halted. The failure must leave
      # a trace. Six steps: the first wave of five is advertised + allowed,
      # step 6 names an action no runner advertises, so its wave-2 dispatch
      # returns {:error, :action_not_found}.
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)

      target = %{"runner_id" => [runner.id]}

      good_steps =
        for n <- 1..5 do
          %{
            "id" => "step#{n}",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => target
          }
        end

      steps =
        good_steps ++
          [
            %{
              "id" => "step6",
              "action_id" => "linux.missing",
              "args" => %{},
              "runner_selector" => target
            }
          ]

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "six-step",
            "name" => "six-step",
            "slug" => "six-step",
            "definition" => %{"steps" => steps}
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, %{execution_id: execution_id, runs: wave1, errors: []}} =
        Emisar.Runbooks.dispatch_runbook(runbook, "ship it", subject)

      assert length(wave1) == 5

      # The wave finishes successfully → fires the (doomed) step 6 dispatch.
      Enum.each(wave1, fn run ->
        {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 5})
      end)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      failed = Enum.find(events, &(&1.event_type == "runbook.step_dispatch_failed"))

      assert failed, "expected a runbook.step_dispatch_failed audit row"
      assert failed.subject_kind == "runbook"
      assert failed.subject_id == runbook.id
      assert failed.payload["runbook_id"] == runbook.id
      assert failed.payload["runbook_execution_id"] == execution_id
      assert failed.payload["runbook_step_id"] == "step6"
      assert failed.payload["runner_id"] == runner.id
      assert failed.payload["reason"] =~ "action_not_found"
    end

    test "a successful continuation writes no failure audit row" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "two-step-ok",
            "name" => "two-step-ok",
            "slug" => "two-step-ok",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "step1",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [runner.id]}
                },
                %{
                  "id" => "step2",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [runner.id]}
                }
              ]
            }
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, %{runs: runs, errors: []}} =
        Emisar.Runbooks.dispatch_runbook(runbook, "ship it", subject)

      Enum.each(runs, fn run ->
        {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 5})
      end)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject, page: [limit: 50])

      refute Enum.any?(events, &(&1.event_type == "runbook.step_dispatch_failed"))
    end
  end

  describe "append_event/2" do
    test "broadcasts + inserts" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Emisar.Runs.subscribe_run(run.account_id, run.id)

      assert {:ok, %RunEvent{seq: 1, kind: :progress}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "hi"}})

      assert_receive {:run_event, %RunEvent{seq: 1}}, 500
    end
  end

  describe "finalize_from_result/2" do
    test "success result transitions the run" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :success}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "success",
                 "exit_code" => 0,
                 "duration_ms" => 12
               })
    end

    test "persists executed_command and carries it into the audit event" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: :success, executed_command: "uptime -p"}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "success",
                 "exit_code" => 0,
                 "executed_command" => "uptime -p"
               })

      # The terminal run audit event records what actually ran.
      event =
        Emisar.Audit.Event
        |> Repo.all()
        |> Enum.find(&(&1.subject_id == run.id and &1.event_type == "action_run.success"))

      assert event.payload["executed_command"] == "uptime -p"
    end

    test "unknown request_id returns {:error, :unknown_request_id}" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => "req_does_not_exist",
                 "status" => "success"
               })
    end

    test "a runner cannot finalize another runner's run in the same account" do
      account = account_fixture()
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner_a.id))

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_result(runner_b.id, %{
                 "request_id" => run.request_id,
                 "status" => "success"
               })
    end
  end

  describe "dashboard + per-runner reads" do
    setup do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      {:ok, account: account, runner: runner, subject: subject_for(user, account, role: :owner)}
    end

    test "fetch_run_stats rolls up totals by status", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      for status <- ~w[success success failed pending] do
        {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: status}))
      end

      assert {:ok, stats} = Runs.fetch_run_stats(subject)
      assert stats.total == 4
      assert stats.success == 2
      assert stats.failed == 1
      assert stats.success_rate == 67
    end

    test "list_recent_runs_for_runner scopes to the runner and the subject's account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      other_runner = runner_fixture(account_id: account.id)
      {:ok, mine} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _theirs} = Runs.create_run(base_attrs(account.id, other_runner.id))

      assert {:ok, [only], _} = Runs.list_recent_runs_for_runner(runner.id, subject)
      assert only.id == mine.id

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:ok, [], _} = Runs.list_recent_runs_for_runner(runner.id, subject_b)
    end

    test "list_events_for_run returns seq-ordered events and refuses cross-account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _} = Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})
      {:ok, _} = Runs.append_event(run, %{seq: 2, kind: "progress", payload: %{"line" => "b"}})

      assert {:ok, [%RunEvent{seq: 1}, %RunEvent{seq: 2}], _} =
               Runs.list_events_for_run(run.id, subject)

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:error, :not_found} = Runs.list_events_for_run(run.id, subject_b)
    end

    test "list_recent_events_for_run returns the chronological tail and refuses cross-account", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      for seq <- 1..5 do
        {:ok, _} =
          Runs.append_event(run, %{
            seq: seq,
            kind: "progress",
            payload: %{"chunk" => "line#{seq}"}
          })
      end

      # A non-output event must not crowd out an output line in the preview.
      {:ok, _} = Runs.append_event(run, %{seq: 6, kind: "transition", payload: %{}})

      # Last 3 progress chunks, oldest→newest (the DESC+limit page reversed).
      assert {:ok, [%RunEvent{seq: 3}, %RunEvent{seq: 4}, %RunEvent{seq: 5}]} =
               Runs.list_recent_events_for_run(run.id, 3, subject)

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:error, :not_found} = Runs.list_recent_events_for_run(run.id, 3, subject_b)
    end
  end

  describe "transition terminal protection" do
    test "a late result holding a stale struct can't overwrite a terminal status" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(run)

      # An operator cancel lands while the runner's result is in flight…
      {:ok, cancelled} = Runs.mark_cancelled(sent, "operator cancelled")
      assert cancelled.status == :cancelled

      # …and the late result arrives still holding the PRE-cancel struct.
      # The locked re-read must keep the run final instead of letting the
      # stale writer flip cancelled → success.
      assert {:ok, _} = Runs.mark_finished(sent, %{"status" => "success"})
      assert Runs.peek_run_by_id(run.id).status == :cancelled
    end
  end

  describe "cancel_run/3" do
    test "cancelling a terminal run is a no-op" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert {:ok, ^finished} = Runs.cancel_run(finished, subject, "no need")
    end

    test "cancelling a running run transitions to :cancelled + broadcasts" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      Emisar.Runs.subscribe_account_runs(account.id)

      assert {:ok, %ActionRun{status: :cancelled, cancelled_at: %DateTime{}}} =
               Runs.cancel_run(run, subject, "user pressed stop")

      # Payload contract: runner is preloaded so subscribers (e.g.
      # RunDetailLive's meta strip) can render `runner.name` without
      # tripping over `%Ecto.Association.NotLoaded{}`.
      assert_receive {:run_updated,
                      %ActionRun{status: :cancelled, runner: %Emisar.Runners.Runner{}}},
                     500
    end

    test "a viewer (no cancel permission) is refused with :unauthorized" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:error, :unauthorized} = Runs.cancel_run(run, subject, "no rights")
    end

    test "an owner of account B cannot cancel account A's run (cross-account → :not_found)" do
      account_a = account_fixture()
      runner_a = runner_fixture(account_id: account_a.id)
      {:ok, run_a} = Runs.create_run(base_attrs(account_a.id, runner_a.id))

      account_b = account_fixture()
      owner_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: owner_b.id, role: "owner")
      subject_b = subject_for(owner_b, account_b, role: :owner)

      assert {:error, :not_found} = Runs.cancel_run(run_a, subject_b, "wrong account")
    end
  end

  describe "RunDispatchTimeout sweep" do
    test "list_stale_dispatches/1 returns only pending/sent runs older than the cutoff" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, :running, fresh} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Backdate one run so it's past the cutoff.
      stale_inserted_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      stale =
        fresh
        |> Ecto.Changeset.change(queued_at: stale_inserted_at, status: :sent)
        |> Repo.update!()

      cutoff = DateTime.utc_now() |> DateTime.add(-2 * 60, :second)
      assert [stale_row] = Runs.list_stale_dispatches(cutoff)
      assert stale_row.id == stale.id
    end

    test "mark_errored/2 transitions to :error with the provided message" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      assert {:ok, %ActionRun{status: :error, error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_errored(run, "runner was disconnected")

      assert msg =~ "disconnected"
    end

    test "worker times out a stale run whose runner is offline" do
      account = account_fixture()
      # connected?: false → never tracked in presence → offline.
      runner = runner_fixture(account_id: account.id, connected?: false)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      # Backdate + flip to sent so it's a sweep candidate.
      stale_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      run
      |> Ecto.Changeset.change(queued_at: stale_at, status: :sent)
      |> Repo.update!()

      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == :error
      assert reloaded.error_message =~ "offline"
    end

    test "worker leaves a stale run alone while its runner is online" do
      account = account_fixture()
      # connected?: true → tracked in presence from this process → online.
      runner = runner_fixture(account_id: account.id, connected?: true)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      stale_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      run
      |> Ecto.Changeset.change(queued_at: stale_at, status: :sent)
      |> Repo.update!()

      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      assert Repo.get!(ActionRun, run.id).status == :sent
    end
  end

  describe "run reads" do
    test "list_runs pages the subject's account only (cross-account isolation)" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [listed], _meta} = Runs.list_runs(subject)
      assert listed.id == run.id

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:ok, [], _meta} = Runs.list_runs(subject_b)
    end

    test "fetch_run_by_id scopes to the subject's account and survives a bad id" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, fetched} = Runs.fetch_run_by_id(run.id, subject)
      assert fetched.id == run.id

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:error, :not_found} = Runs.fetch_run_by_id(run.id, subject_b)
      assert {:error, :not_found} = Runs.fetch_run_by_id("not-a-uuid", subject)
    end

    test "fetch_run_by_request_id_for_runner never crosses runners" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      other_runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, found} = Runs.fetch_run_by_request_id_for_runner(run.request_id, runner.id)
      assert found.id == run.id

      # Another runner in the SAME account must not see it — the runner
      # socket may only touch runs dispatched to that runner.
      assert {:error, :not_found} =
               Runs.fetch_run_by_request_id_for_runner(run.request_id, other_runner.id)
    end

    test "list_running_runs returns only in-flight rows" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.mark_sent(running)
      {:ok, running} = Runs.mark_running(running)

      ids = Runs.list_running_runs() |> Enum.map(& &1.id)
      assert running.id in ids
      refute pending.id in ids
      assert running.status == :running
      assert %DateTime{} = running.started_at
    end
  end

  describe "recheck_run_pack_trust/1 (approval-time pack-trust re-gate)" do
    test "refuses a run whose action pack drifted to :pending" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      # A custom pack lands :pending (untrusted) — the same state a tampered
      # re-advertisement produces during an approval window.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"linux-core" => %{"version" => "1.2.3", "hash" => "sha256:DRIFT"}},
          "actions" => [
            %{
              "id" => "linux.uptime",
              "pack_id" => "linux-core",
              "title" => "Uptime",
              "kind" => "exec",
              "risk" => "high",
              "args" => []
            }
          ]
        })

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          args: %{}
        })

      assert {:error, :pack_untrusted} = Runs.recheck_run_pack_trust(run.id)
    end

    test "passes when the runner no longer advertises the action (nothing to dispatch to)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "ghost.action",
          source: "operator",
          args: %{}
        })

      assert :ok = Runs.recheck_run_pack_trust(run.id)
    end
  end

  describe "dispatch_run input validation" do
    test "rejects a missing action_id with :action_required" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      attrs = %{runner_id: runner.id, reason: "x", source: "operator", args: %{}}
      assert {:error, :action_required} = Runs.dispatch_run(attrs, subject)
    end

    test "rejects a missing reason with :reason_required" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      attrs = %{runner_id: runner.id, action_id: "linux.uptime", source: "operator", args: %{}}
      assert {:error, :reason_required} = Runs.dispatch_run(attrs, subject)
    end
  end

  describe "list_recent_runs/2 with preloads" do
    test "applies the :runner and :api_key preloads" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, _run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, [run], _meta} =
               Runs.list_recent_runs(subject, preload: [:runner, :api_key], limit: 8)

      assert run.runner.id == runner.id
    end
  end

  describe "runner-event ingestion error paths" do
    test "append_event/2 with an unknown run id returns :unknown_run" do
      assert {:error, :unknown_run} =
               Runs.append_event(Repo.generate_id(), %{seq: 1, kind: "progress", payload: %{}})
    end

    test "finalize_from_result with no request_id returns :missing_request_id" do
      assert {:error, :missing_request_id} = Runs.finalize_from_result("runner-123", %{})
    end
  end

  describe "Authorizer.for_subject runner-scoping" do
    test "a runner subject's run reads are scoped to that runner, not account-wide" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      peer = runner_fixture(account_id: account.id)
      {:ok, mine} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, _theirs} = Runs.create_run(base_attrs(account.id, peer.id))

      runner_subject = Emisar.Auth.Subject.for_runner(runner, account)

      ids =
        ActionRun.Query.all()
        |> Runs.Authorizer.for_subject(runner_subject)
        |> Repo.all()
        |> Enum.map(& &1.id)

      # A runner socket sees only its own runs, even within the account.
      assert ids == [mine.id]
    end

    test "an account-less / actor-less subject leaves the query unscoped (fallback)" do
      query = ActionRun.Query.all()
      assert Runs.Authorizer.for_subject(query, %Emisar.Auth.Subject{}) == query
    end
  end

  describe "redispatch_inflight_for_runner/1" do
    test "re-dispatches the runner's in-flight :pending and :sent runs" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      {:ok, sent} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, sent} = Runs.mark_sent(sent)
      # Backdate sent_at so a re-dispatch's fresh mark_sent jumps it forward.
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      sent = sent |> Ecto.Changeset.change(sent_at: past) |> Repo.update!()

      {:ok, pending} = Runs.create_run(base_attrs(account.id, runner.id))
      assert pending.status == :pending

      assert :ok = Runs.redispatch_inflight_for_runner(runner.id)

      resent = Runs.peek_run_by_id(sent.id)
      assert resent.status == :sent
      assert DateTime.compare(resent.sent_at, sent.sent_at) == :gt
      assert Runs.peek_run_by_id(pending.id).status == :sent
    end

    test "leaves :running, terminal, and other-runner runs untouched (no double-exec)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      other = runner_fixture(account_id: account.id)

      {:ok, running} = Runs.create_run(base_attrs(account.id, runner.id))
      {:ok, running} = Runs.mark_sent(running)
      {:ok, running} = Runs.mark_running(running)

      {:ok, other_sent} = Runs.create_run(base_attrs(account.id, other.id))
      {:ok, other_sent} = Runs.mark_sent(other_sent)

      assert :ok = Runs.redispatch_inflight_for_runner(runner.id)

      # A :running run is excluded by the [:pending, :sent] filter — never re-sent.
      reloaded_running = Runs.peek_run_by_id(running.id)
      assert reloaded_running.status == :running
      assert DateTime.compare(reloaded_running.sent_at, running.sent_at) == :eq

      # Another runner's in-flight run is out of scope — untouched.
      reloaded_other = Runs.peek_run_by_id(other_sent.id)
      assert DateTime.compare(reloaded_other.sent_at, other_sent.sent_at) == :eq
    end
  end
end
