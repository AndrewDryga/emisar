defmodule Emisar.RunbooksCancellationTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Approvals, Audit, Fixtures, Repo, Runbooks, Runs}
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, RunbookExecution}

  describe "cancel_execution/2" do
    setup do
      {user, account, owner} = Fixtures.Subjects.owner_subject()
      request = Fixtures.Approvals.create_execution_request(account, user)

      items =
        ExecutionItem.Query.by_execution_id(request.runbook_execution_id)
        |> ExecutionItem.Query.ordered()
        |> Repo.all()

      %{account: account, owner: owner, request: request, items: items}
    end

    test "a mixed-runner set refuses all cancellation and preserves its pending approval", %{
      account: account,
      request: request,
      items: [first, second]
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      {:ok, access} =
        RunnerAccess.new(:restricted, [], [first.runner_id], :restricted, ["postgres"])

      membership = Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)
      before = cancellation_state()

      assert {:ok, _visible} =
               Runbooks.fetch_execution_by_id(request.runbook_execution_id, subject)

      assert Runbooks.cancel_execution(request.runbook_execution_id, subject) ==
               {:error, :unauthorized}

      assert cancellation_state() == before
      assert Repo.reload!(second).status == :pending
    end

    test "full current runner and pack coverage cancels the held execution and request", %{
      account: account,
      request: request,
      items: items
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      runner_ids = Enum.map(items, & &1.runner_id)
      {:ok, access} = RunnerAccess.new(:restricted, [], runner_ids, :restricted, ["postgres"])
      membership = Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert {:ok, execution} = Runbooks.cancel_execution(request.runbook_execution_id, subject)
      assert execution.status == :cancelled
      assert Repo.reload!(request).status == :cancelled
      assert Enum.all?(Repo.all(ExecutionItem), &(&1.status == :cancelled))
      assert Enum.all?(Repo.all(ExecutionStage), &(&1.status == :cancelled))
      refute Repo.one(Runs.ActionRun)
    end

    test "all runners do not bypass a restricted pack grant", %{
      account: account,
      request: request
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      {:ok, access} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      membership = Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)
      before = cancellation_state()

      assert Runbooks.cancel_execution(request.runbook_execution_id, subject) ==
               {:error, :unauthorized}

      assert cancellation_state() == before
    end

    test "a stale demoted or suspended actor cannot cancel a held execution", %{
      account: account,
      request: request
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      before = cancellation_state()
      Fixtures.Memberships.force_role(membership, "viewer")

      assert Runbooks.cancel_execution(request.runbook_execution_id, subject) ==
               {:error, :unauthorized}

      Fixtures.Memberships.suspend_membership(membership)

      assert Runbooks.cancel_execution(request.runbook_execution_id, subject) ==
               {:error, :unauthorized}

      assert cancellation_state() == before
    end

    test "one deleted logical target fails closed instead of cancelling the remaining subset", %{
      request: request,
      owner: owner,
      items: [_first, second]
    } do
      runner = Emisar.Runners.peek_runner_by_id(second.runner_id)
      Fixtures.Runners.mark_deleted(runner)
      before = cancellation_state()

      assert Runbooks.cancel_execution(request.runbook_execution_id, owner) ==
               {:error, :unauthorized}

      assert cancellation_state() == before
    end
  end

  defp cancellation_state do
    Enum.map(
      [
        RunbookExecution,
        ExecutionStage,
        ExecutionItem,
        Runs.ActionRun,
        Approvals.Request,
        Approvals.Grant,
        Audit.Event
      ],
      fn schema -> schema |> Repo.all() |> Enum.sort_by(& &1.id) end
    )
  end
end
