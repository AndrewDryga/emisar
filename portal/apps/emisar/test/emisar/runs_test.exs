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
  end

  describe "dispatch/2" do
    test "allow policy returns {:ok, :running, run} and delivers to runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      _ = policy_fixture(account_id: account.id)

      Emisar.PubSub.subscribe_runner(runner.id)

      assert {:ok, :running, %ActionRun{} = run} =
               Runs.dispatch(account.id, base_attrs(account.id, runner.id))

      assert run.account_id == account.id

      # Cloud-to-runner envelope was delivered.
      assert_receive {:cloud_to_runner, %{"type" => "run_action", "action_id" => "linux.uptime"}}
    end

    test "rejects dispatch when the action is not advertised by the runner" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = policy_fixture(account_id: account.id)

      assert {:error, :action_not_found} =
               Runs.dispatch(account.id, base_attrs(account.id, runner.id))
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
            "allow" => [%{"name" => "low", "max_risk" => "medium"}],
            "require_approval" => [%{"name" => "high-needs-approval", "risk" => "high"}],
            "deny" => []
          }
        )

      # Caller spoofs `risk: "low"` — should be ignored.
      attrs = base_attrs(account.id, runner.id, %{risk: "low"})
      assert {:ok, :pending_approval, _run} = Runs.dispatch(account.id, attrs)
    end

    test "require_approval policy stores the run as pending + creates a request" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "require_approval" => [%{"name" => "needs-approval", "action" => "*"}]
          }
        )

      requester = user_fixture()

      assert {:ok, :pending_approval, %ActionRun{status: "pending_approval"} = run} =
               Runs.dispatch(
                 account.id,
                 base_attrs(account.id, runner.id, %{requested_by_id: requester.id})
               )

      assert [_req] = Approvals.list_pending(account.id)
      assert Runs.get_run(account.id, run.id).status == "pending_approval"
    end

    test "deny policy returns an error and records the attempt for audit" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "deny" => [%{"name" => "blocked", "action" => "*"}]
          }
        )

      assert {:error, :denied_by_policy, reason} =
               Runs.dispatch(account.id, base_attrs(account.id, runner.id))

      assert is_binary(reason)
      # A denied run is recorded with status="denied" so operators can
      # see attempts in the audit log.
      assert [%{status: "denied", policy_decision: "deny"}] =
               Runs.list_runs_for_account(account.id)
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

      assert_receive {:run_event, %RunEvent{seq: 1}}
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

    test "an runner cannot finalize another runner's run in the same account" do
      account = account_fixture()
      agent_a = runner_fixture(account_id: account.id)
      agent_b = runner_fixture(account_id: account.id)
      {:ok, run} = Runs.create_run(base_attrs(account.id, agent_a.id))

      assert {:error, :unknown_request_id} =
               Runs.finalize_from_result(agent_b.id, %{
                 "request_id" => run.request_id,
                 "status" => "success"
               })
    end
  end

  describe "cancel/3" do
    test "cancelling a terminal run is a no-op" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      user = user_fixture()
      {:ok, run} = Runs.create_run(base_attrs(account.id, runner.id))

      {:ok, finished} =
        Runs.finalize_from_result(runner.id, %{
          "request_id" => run.request_id,
          "status" => "success"
        })

      assert {:ok, ^finished} = Runs.cancel(finished, user.id, "no need")
    end

    test "cancelling a running run transitions to :cancelled + broadcasts" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner)
      user = user_fixture()
      _ = policy_fixture(account_id: account.id)

      {:ok, :running, run} = Runs.dispatch(account.id, base_attrs(account.id, runner.id))

      Emisar.PubSub.subscribe_account_runs(account.id)

      assert {:ok, %ActionRun{status: "cancelled", cancelled_at: %DateTime{}}} =
               Runs.cancel(run, user.id, "user pressed stop")

      assert_receive {:run_updated, %ActionRun{status: "cancelled"}}
    end
  end
end
