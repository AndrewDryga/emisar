defmodule Emisar.RunsCrossAccountTest do
  @moduledoc """
  Regression tests for cross-account isolation. A run in account A must
  never be visible/mutable from account B; an runner in account A must
  never be targetable from account B.
  """

  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Runs
  alias Emisar.Runs.ActionRun

  describe "dispatch/2 cross-account guard" do
    test "rejects an runner_id that belongs to a different account" do
      account_a = account_fixture()
      account_b = account_fixture()
      agent_b = runner_fixture(account_id: account_b.id)
      _ = policy_fixture(account_id: account_a.id)
      user = user_fixture()

      attrs = %{
        runner_id: agent_b.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "cross-account guard test",
        source: "operator",
        requested_by_id: user.id
      }

      assert {:error, :runner_not_found} = Runs.dispatch(account_a.id, attrs)
    end

    test "rejects a missing runner_id" do
      account = account_fixture()
      _ = policy_fixture(account_id: account.id)
      user = user_fixture()

      assert {:error, :runner_required} =
               Runs.dispatch(account.id, %{
                 action_id: "linux.uptime",
                 source: "operator",
                 requested_by_id: user.id
               })
    end

    test "rejects a disabled runner (even within the same account)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = policy_fixture(account_id: account.id)
      user = user_fixture()

      {:ok, _disabled} = Emisar.Runners.disable_runner(runner)

      assert {:error, :runner_not_found} =
               Runs.dispatch(account.id, %{
                 runner_id: runner.id,
                 action_id: "linux.uptime",
                 reason: "disabled runner test",
                 source: "operator",
                 requested_by_id: user.id
               })
    end
  end

  describe "get_run_for_runner/2 — runner-scoped lookup" do
    test "returns the run when the runner matches" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      {:ok, %ActionRun{} = run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator"
        })

      assert %ActionRun{id: id} = Runs.get_run_for_runner(runner.id, run.request_id)
      assert id == run.id
    end

    test "returns nil for an runner that didn't own the run" do
      account = account_fixture()
      agent_a = runner_fixture(account_id: account.id)
      agent_b = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: agent_a.id,
          action_id: "linux.uptime",
          source: "operator"
        })

      assert is_nil(Runs.get_run_for_runner(agent_b.id, run.request_id))
    end
  end
end
