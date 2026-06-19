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

    test "rejects oversized args (a hostile MCP client can't write a multi-MB row)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      huge = %{"blob" => String.duplicate("x", 300_000)}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runs.create_run(base_attrs(account.id, runner.id, %{args: huge}))

      assert Keyword.has_key?(changeset.errors, :args)
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

  describe "dispatch_run/2 signature enforcement" do
    test "an enforcing runner refuses an unsigned (portal-originated) dispatch" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, enforce_signatures: true)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :runner_requires_attestation} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "a signed dispatch (carrying :attestation) passes the gate and runs" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, enforce_signatures: true)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      # The portal only checks that an attestation is PRESENT and relays it; the
      # runner verifies the signature (Phase 3). So any non-nil attestation gets
      # past the portal gate.
      attrs = base_attrs(account.id, runner.id, %{attestation: %{"sig" => "x", "key_id" => "k"}})

      assert {:ok, :running, %ActionRun{}} = Runs.dispatch_run(attrs, subject)
    end

    test "a signed dispatch persists the attestation and relays it on the wire" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, enforce_signatures: true)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      attestation = %{
        "key_id" => "k1",
        "sig" => "deadbeef",
        "nonce" => "n1",
        "issued_at" => "2026-06-17T12:00:00Z"
      }

      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = base_attrs(account.id, runner.id, %{attestation: attestation})
      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)

      # Stored on the run row, and relayed verbatim — the portal only carries it.
      assert run.attestation == attestation
      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["attestation"] == attestation
    end

    test "rich args survive the DB + wire round-trip unchanged (so the signature still verifies)" do
      # The MCP signs over the canonical args; the runner re-canonicalizes the
      # args the portal relayed. If the portal's jsonb/Jason round-trip mangled
      # a value (int↔float, key order, nesting), the signature would fail. Prove
      # the relay is lossless for mixed scalar / array / nested types.
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      rich_args = %{
        "container" => "web",
        "force" => true,
        "signal" => 15,
        "names" => ["a", "b"],
        "opts" => %{"z" => 1, "a" => 2}
      }

      Emisar.Runners.subscribe_runner_transport(runner)

      attrs = base_attrs(account.id, runner.id, %{args: rich_args})
      assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)

      # Persisted args come back byte-equal after the jsonb round-trip…
      assert Repo.reload!(run).args == rich_args
      # …and the wire envelope carries them verbatim.
      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["args"] == rich_args
    end

    test "a portal-originated run carries no attestation on the wire" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      Emisar.Runners.subscribe_runner_transport(runner)

      assert {:ok, :running, _run} = Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
      assert_receive {:cloud_to_runner, payload}, 500
      refute Map.has_key?(payload, "attestation")
    end

    test "a non-enforcing runner dispatches normally (no regression)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, :running, %ActionRun{}} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)
    end

    test "the refusal records a dispatch_blocked_requires_attestation audit row" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, enforce_signatures: true)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:error, :runner_requires_attestation} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      blocked = Enum.find(events, &(&1.event_type == "dispatch_blocked_requires_attestation"))

      assert blocked
      assert blocked.subject_kind == "runner"
      assert blocked.subject_id == runner.id
      assert blocked.payload["action_id"] == "linux.uptime"
    end
  end

  describe "list_recent_runs/2 runner + action filters" do
    test "narrows by runner_id and action_id (composable)" do
      account = account_fixture()
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_a.id, %{action_id: "linux.uptime"}))

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_a.id, %{action_id: "linux.disk_usage"}))

      {:ok, _} =
        Runs.create_run(base_attrs(account.id, runner_b.id, %{action_id: "linux.uptime"}))

      {:ok, by_runner, _} = Runs.list_recent_runs(subject, runner_id: runner_a.id)
      assert length(by_runner) == 2
      assert Enum.all?(by_runner, &(&1.runner_id == runner_a.id))

      {:ok, by_action, _} = Runs.list_recent_runs(subject, action_id: "linux.uptime")
      assert length(by_action) == 2
      assert Enum.all?(by_action, &(&1.action_id == "linux.uptime"))

      {:ok, both, _} =
        Runs.list_recent_runs(subject, runner_id: runner_a.id, action_id: "linux.uptime")

      assert length(both) == 1
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

    test "a re-sent (run_id, seq) is classified :duplicate_event, not a changeset" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %RunEvent{seq: 1}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})

      # The runner re-sends the same chunk (its retry) — a benign duplicate the
      # socket drops quietly, distinct from a malformed event it must log.
      assert {:error, :duplicate_event} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "a"}})
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

    test "a refusal's human `error` sentence is surfaced as error_message, not the terse code" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      # A signature/pack refusal carries both: a terse `reason` code and a human
      # `error` sentence. The operator must see the sentence.
      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "signature_invalid",
          "reason" => "stale",
          "error" => "refused: issued_at is outside the freshness window"
        })

      assert finished.error_message == "refused: issued_at is outside the freshness window"
      # …and the run lands in the distinct `:refused` terminal state, not `:failed`.
      assert finished.status == :refused
    end

    test "signature_invalid + pack_hash_mismatch both map to :refused, audited as action_run.refused" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      for wire <- ["signature_invalid", "pack_hash_mismatch"] do
        {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

        {:ok, finished} =
          Runs.finalize_from_result(runner.id, %{"request_id" => run.request_id, "status" => wire})

        assert finished.status == :refused
        assert Emisar.Runs.ActionRun.terminal?(:refused)
      end

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      refused = Enum.filter(events, &(&1.event_type == "action_run.refused"))
      assert length(refused) == 2
    end

    test "an ordinary failure with no `error` falls back to the reason code" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "failed",
          "reason" => "exit status 1"
        })

      assert finished.error_message == "exit status 1"
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

    test "fetch_run_stats classifies every outcome, not just failed/error/timed_out", %{
      account: account,
      runner: runner,
      subject: subject
    } do
      # refused + validation_failed are genuine failures (were excluded before);
      # denied + cancelled are their own buckets; running is in-flight.
      for status <- ~w[success refused validation_failed denied cancelled running] do
        {:ok, _} = Runs.create_run(base_attrs(account.id, runner.id, %{status: status}))
      end

      assert {:ok, stats} = Runs.fetch_run_stats(subject)
      assert stats.total == 6
      assert stats.success == 1
      assert stats.failed == 2
      assert stats.denied == 1
      assert stats.cancelled == 1
      assert stats.in_progress == 1
      # 1 success out of 3 results (success + failed); denied/cancelled/running
      # are excluded from the denominator.
      assert stats.success_rate == 33
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

    test "cancelling a :denied run is a no-op — it never reached a runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)

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
            "overrides" => []
          }
        )

      assert {:error, :denied_by_policy, _reason} =
               Runs.dispatch_run(base_attrs(account.id, runner.id), subject)

      assert {:ok, [%ActionRun{status: :denied} = denied], _} =
               Runs.list_recent_runs(subject, limit: 50)

      Emisar.Runs.subscribe_account_runs(account.id)

      # :denied is terminal → cancel returns it unchanged, tells no runner, and
      # broadcasts nothing (before the fix it transitioned denied→cancelled).
      assert {:ok, %ActionRun{status: :denied}} = Runs.cancel_run(denied, subject, "stop")
      refute_receive {:run_updated, _}, 200
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

  describe "dispatch_to_runner non-dispatchable guard (BLOCKER-3)" do
    test "refuses to publish a run that's no longer dispatchable (closes the publish-before-mark_sent hole)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))
      # The run reaches a terminal state (e.g. cancelled) before delivery.
      {:ok, _} = run |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()

      # The envelope is published BEFORE mark_sent, so the status guard must
      # block it HERE — nothing should reach the runner.
      assert {:error, :not_dispatchable} = Runs.dispatch_to_runner(run)
      refute_receive {:cloud_to_runner, _}, 100
    end

    test "still delivers a dispatchable (:pending) run" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, %{"type" => "run_action"}}, 500
      assert Runs.peek_run_by_id(run.id).status == :sent
    end
  end

  describe "pack-trust dispatch gate (BLOCKER-2)" do
    # Observe a custom (no-baseline) pack + its action; the version lands
    # :pending and the action is advertised. Returns {runner, pack_version}.
    defp observe_pending_pack(account, subject) do
      runner = runner_fixture(account_id: account.id)

      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "args" => []
            }
          ]
        })

      {:ok, [pack_version], _} = Emisar.Catalog.list_pack_versions(subject)
      {runner, pack_version}
    end

    test "a rejected pack refuses dispatch (fail closed)" do
      {_user, account, subject} = owner_subject_fixture()
      _ = policy_fixture(account_id: account.id)
      {runner, pack_version} = observe_pending_pack(account, subject)

      assert {:ok, rejected} = Emisar.Catalog.reject_pack_version(pack_version.id, subject)
      assert rejected.trust_state == :rejected

      assert {:error, :pack_untrusted} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )
    end

    test "a deleted pin row refuses dispatch — the old reject-then-delete fail-open is closed" do
      {_user, account, subject} = owner_subject_fixture()
      _ = policy_fixture(account_id: account.id)
      {runner, pack_version} = observe_pending_pack(account, subject)

      # The OLD behavior: the pin row is gone, but the action still references
      # (pack_id, version). A missing row must fail CLOSED, not open.
      {:ok, _} = Repo.delete(pack_version)

      assert {:error, :pack_untrusted} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )
    end

    test "a pack drifting to pending after authorization is refused at send, not shipped hash-less" do
      {_user, account, subject} = owner_subject_fixture()
      _ = policy_fixture(account_id: account.id)
      {runner, pack_version} = observe_pending_pack(account, subject)

      # Operator trusts the pack → a run dispatches normally and goes :sent.
      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, :running, run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )

      assert Runs.peek_run_by_id(run.id).status == :sent

      # The pack drifts to a new hash (a tampered re-advertisement) → :pending.
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:TAMPERED"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "args" => []
            }
          ]
        })

      # Redelivery must NOT ship a hash-less envelope — it refuses the run.
      assert {:error, :pack_untrusted} = Runs.dispatch_to_runner(run)
      assert Runs.peek_run_by_id(run.id).status == :refused
    end

    test "a run ships the hash snapshotted at authorization, not a re-read after re-trust (MAJOR-5)" do
      {_user, account, subject} = owner_subject_fixture()
      _ = policy_fixture(account_id: account.id)
      {runner, pack_version} = observe_pending_pack(account, subject)
      Emisar.Runners.subscribe_runner_transport(runner)

      {:ok, _} = Emisar.Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, :running, run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{action_id: "custom.do"}),
                 subject
               )

      # The trusted hash is snapshotted onto the run + shipped in the envelope.
      assert Runs.peek_run_by_id(run.id).expected_pack_hash == "sha256:NOPE"
      assert_receive {:cloud_to_runner, %{"expected_pack_hash" => "sha256:NOPE"}}, 500

      # The pack drifts to a NEW hash AND is re-trusted (trusted hash now TAMPERED).
      {:ok, _} =
        Emisar.Catalog.observe_state(runner, %{
          "hostname" => "h",
          "version" => "0.1",
          "labels" => %{},
          "packs" => %{"custom" => %{"version" => "1.0", "hash" => "sha256:TAMPERED"}},
          "actions" => [
            %{
              "id" => "custom.do",
              "pack_id" => "custom",
              "title" => "Do",
              "kind" => "exec",
              "risk" => "low",
              "args" => []
            }
          ]
        })

      {:ok, [drifted], _} = Emisar.Catalog.list_pack_versions(subject)
      {:ok, _} = Emisar.Catalog.trust_pack_version(drifted.id, subject)

      # Redelivery ships the ORIGINAL snapshot (NOPE), never the new trusted hash.
      assert :ok = Runs.dispatch_to_runner(run)
      assert_receive {:cloud_to_runner, %{"expected_pack_hash" => "sha256:NOPE"}}, 500
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

  describe "list_recent_runs/2 :scope" do
    setup do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {_raw, key} = api_key_fixture(account_id: account.id)

      # One run the key dispatched (source: mcp, carries the api_key_id) and
      # one operator run with no api_key_id, so :own and :account differ.
      {:ok, mine} =
        Runs.create_run(base_attrs(account.id, runner.id, %{source: "mcp", api_key_id: key.id}))

      {:ok, operator_run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, account: account, key: key, mine: mine, operator_run: operator_run}
    end

    test "scope: :own returns only this API key's runs", %{
      account: account,
      key: key,
      mine: mine
    } do
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, runs, _meta} = Runs.list_recent_runs(subject, scope: :own, limit: 50)
      assert Enum.map(runs, & &1.id) == [mine.id]
    end

    test "scope: :account returns every agent's runs in the account", %{
      account: account,
      key: key,
      mine: mine,
      operator_run: operator_run
    } do
      subject = Emisar.Auth.Subject.for_api_key(key, account)

      assert {:ok, runs, _meta} = Runs.list_recent_runs(subject, scope: :account, limit: 50)
      assert MapSet.new(runs, & &1.id) == MapSet.new([mine.id, operator_run.id])
    end

    test "a second account's key sees none of the first account's runs (cross-account)", %{
      key: key
    } do
      other_account = account_fixture()
      {_raw, other_key} = api_key_fixture(account_id: other_account.id)
      subject = Emisar.Auth.Subject.for_api_key(other_key, other_account)

      # Even scope: :account is bounded by for_subject to the caller's account,
      # and this account has no runs — the first account's key.id leaks nothing.
      assert {:ok, [], _meta} = Runs.list_recent_runs(subject, scope: :account, limit: 50)
      assert {:ok, [], _meta} = Runs.list_recent_runs(subject, scope: :own, limit: 50)
      refute other_key.id == key.id
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
