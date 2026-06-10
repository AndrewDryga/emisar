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

  describe "dispatch_run/2 cross-account guard" do
    test "rejects a runner_id that belongs to a different account" do
      account_a = account_fixture()
      account_b = account_fixture()
      runner_b = runner_fixture(account_id: account_b.id)
      _ = policy_fixture(account_id: account_a.id)
      user = user_fixture()

      attrs = %{
        runner_id: runner_b.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "cross-account guard test",
        source: "operator",
        requested_by_id: user.id
      }

      subject = subject_for(user_fixture(), account_a, role: :owner)

      assert {:error, :runner_not_found} =
               Runs.dispatch_run(attrs, subject)
    end

    test "rejects a missing runner_id" do
      account = account_fixture()
      _ = policy_fixture(account_id: account.id)
      user = user_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:error, :runner_required} =
               Runs.dispatch_run(
                 %{
                   action_id: "linux.uptime",
                   source: "operator",
                   requested_by_id: user.id
                 },
                 subject
               )
    end

    test "rejects a disabled runner (even within the same account)" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = policy_fixture(account_id: account.id)
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)

      {:ok, _disabled} = Emisar.Runners.disable_runner(runner, subject)

      assert {:error, :runner_not_found} =
               Runs.dispatch_run(
                 %{
                   runner_id: runner.id,
                   action_id: "linux.uptime",
                   reason: "disabled runner test",
                   source: "operator",
                   requested_by_id: user.id
                 },
                 subject
               )
    end
  end

  describe "fetch_run_by_request_id_for_runner/2 — runner-scoped lookup" do
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

      assert {:ok, %ActionRun{id: id}} =
               Runs.fetch_run_by_request_id_for_runner(run.request_id, runner.id)

      assert id == run.id
    end

    test "returns :not_found for a runner that didn't own the run" do
      account = account_fixture()
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner_a.id,
          action_id: "linux.uptime",
          source: "operator"
        })

      assert {:error, :not_found} =
               Runs.fetch_run_by_request_id_for_runner(run.request_id, runner_b.id)
    end
  end
end
