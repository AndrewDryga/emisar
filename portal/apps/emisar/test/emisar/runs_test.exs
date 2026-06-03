defmodule Emisar.RunsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Runs}
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

      Emisar.PubSub.subscribe_runner(runner.id)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 Emisar.Auth.Subject.system(account)
               )

      assert run.account_id == account.id

      # Cloud-to-runner envelope was delivered.
      assert_receive {:cloud_to_runner, %{"type" => "run_action", "action_id" => "linux.uptime"}},
                     500
    end

    test "audits only the policy decision + terminal outcome, decision first" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), Emisar.Auth.Subject.system(account))

      {:ok, _} = Runs.mark_finished(run, %{"status" => "success", "duration_ms" => 6})

      {:ok, events, _} =
        Emisar.Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 50])

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

      {:ok, [pv], _} = Emisar.Catalog.list_pack_versions(subject)
      assert {:ok, _} = Emisar.Catalog.trust_pack_version(pv.id, subject)

      _ = policy_fixture(account_id: account.id)

      Emisar.PubSub.subscribe_runner(runner.id)

      assert {:ok, :running, _run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 Emisar.Auth.Subject.system(account)
               )

      assert_receive {:cloud_to_runner, payload}, 500
      assert payload["expected_pack_hash"] == "sha256:CLOUD_TRUSTED"
    end

    test "rejects dispatch when the action is not advertised by the runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = policy_fixture(account_id: account.id)

      assert {:error, :action_not_found} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 Emisar.Auth.Subject.system(account)
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

      assert {:ok, :pending_approval, _run} =
               Runs.dispatch_run(attrs, Emisar.Auth.Subject.system(account))
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

      assert {:ok, :pending_approval, %ActionRun{status: "pending_approval"} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id, %{requested_by_id: requester.id}),
                 Emisar.Auth.Subject.system(account)
               )

      system = Emisar.Auth.Subject.system(account)
      assert {:ok, [_req], _} = Approvals.list_pending_approval_requests(system)
      assert {:ok, %{status: "pending_approval"}} = Runs.fetch_run_by_id(run.id, system)
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

      assert {:error, :denied_by_policy, reason} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 Emisar.Auth.Subject.system(account)
               )

      assert is_binary(reason)
      # A denied run is recorded with status="denied" so operators can
      # see attempts in the audit log.
      system = Emisar.Auth.Subject.system(account)

      assert {:ok, [%{status: "denied", policy_decision: "deny"}], _meta} =
               Runs.list_recent_runs(system, limit: 50)
    end

    test "stamps policy_version on the dispatched run so audit can correlate vN edits" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      policy = policy_fixture(account_id: account.id)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch_run(
                 base_attrs(account.id, runner.id),
                 Emisar.Auth.Subject.system(account)
               )

      assert run.policy_id == policy.id
      assert run.policy_version == policy.vsn
    end
  end

  describe "append_event/2" do
    test "broadcasts + inserts" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      Emisar.PubSub.subscribe_run(run.id)

      assert {:ok, %RunEvent{seq: 1, kind: "progress"}} =
               Runs.append_event(run, %{seq: 1, kind: "progress", payload: %{"line" => "hi"}})

      assert_receive {:run_event, %RunEvent{seq: 1}}, 500
    end
  end

  describe "finalize_from_result/2" do
    test "success result transitions the run" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      assert {:ok, %ActionRun{status: "success"}} =
               Runs.finalize_from_result(runner.id, %{
                 "request_id" => run.request_id,
                 "status" => "success",
                 "exit_code" => 0,
                 "duration_ms" => 12
               })
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
        Runs.dispatch_run(base_attrs(account.id, runner.id), Emisar.Auth.Subject.system(account))

      Emisar.PubSub.subscribe_account_runs(account.id)

      assert {:ok, %ActionRun{status: "cancelled", cancelled_at: %DateTime{}}} =
               Runs.cancel_run(run, subject, "user pressed stop")

      # Payload contract: runner is preloaded so subscribers (e.g.
      # RunDetailLive's meta strip) can render `runner.name` without
      # tripping over `%Ecto.Association.NotLoaded{}`.
      assert_receive {:run_updated,
                      %ActionRun{status: "cancelled", runner: %Emisar.Runners.Runner{}}},
                     500
    end
  end

  describe "RunDispatchTimeout sweep" do
    test "list_stale_dispatches/1 returns only pending/sent runs older than the cutoff" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, fresh} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), Emisar.Auth.Subject.system(account))

      # Backdate one run so it's past the cutoff.
      stale_inserted_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      stale =
        fresh
        |> Ecto.Changeset.change(queued_at: stale_inserted_at, status: "sent")
        |> Repo.update!()

      cutoff = DateTime.utc_now() |> DateTime.add(-2 * 60, :second)
      assert [stale_row] = Runs.list_stale_dispatches(cutoff)
      assert stale_row.id == stale.id
    end

    test "mark_runner_unreachable/2 transitions to :error with the provided message" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), Emisar.Auth.Subject.system(account))

      assert {:ok, %ActionRun{status: "error", error_message: msg, finished_at: %DateTime{}}} =
               Runs.mark_runner_unreachable(run, "runner was disconnected")

      assert msg =~ "disconnected"
    end

    test "worker only touches stale runs whose runner is offline" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, run} =
        Runs.dispatch_run(base_attrs(account.id, runner.id), Emisar.Auth.Subject.system(account))

      # Backdate + flip to sent so it's a sweep candidate.
      stale_at = DateTime.utc_now() |> DateTime.add(-5 * 60, :second)

      run
      |> Ecto.Changeset.change(queued_at: stale_at, status: "sent")
      |> Repo.update!()

      # And mark the runner disconnected so the sweeper times it out.
      runner
      |> Ecto.Changeset.change(status: "disconnected")
      |> Repo.update!()

      assert :ok = Emisar.Workers.RunDispatchTimeout.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(ActionRun, run.id)
      assert reloaded.status == "error"
      assert reloaded.error_message =~ "disconnected"
    end
  end
end
