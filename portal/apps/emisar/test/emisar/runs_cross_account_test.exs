defmodule Emisar.RunsCrossAccountTest do
  @moduledoc """
  Regression tests for cross-account isolation. A run in account A must
  never be visible/mutable from account B; an runner in account A must
  never be targetable from account B.
  """

  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.Runs
  alias Emisar.Runs.ActionRun

  describe "dispatch_run/2 cross-account guard" do
    test "rejects a runner_id that belongs to a different account" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)
      _ = Fixtures.Policies.create_policy(account_id: account_a.id)
      user = Fixtures.Users.create_user()

      attrs = %{
        runner_id: runner_b.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "cross-account guard test",
        source: "operator",
        requested_by_id: user.id
      }

      subject_user = Fixtures.Users.create_user()

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account_a.id,
          user_id: subject_user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(subject_user, account_a, role: :owner)

      assert {:error, :runner_not_found} =
               Runs.dispatch_run(attrs, subject)
    end

    test "rejects a missing runner_id" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()
      subject_user = Fixtures.Users.create_user()

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: subject_user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(subject_user, account, role: :owner)

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
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Policies.create_policy(account_id: account.id)
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "returns the run when the runner matches", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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

    test "returns :not_found for a runner that didn't own the run", %{account: account} do
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)

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
