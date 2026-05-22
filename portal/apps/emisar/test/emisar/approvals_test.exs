defmodule Emisar.ApprovalsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Audit, Runs}
  alias Emisar.Approvals.Request
  alias Emisar.Runs.ActionRun

  defp run_fixture(opts \\ []) do
    account =
      Keyword.get(opts, :account) || account_fixture()

    runner = Keyword.get(opts, :runner) || runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{}
      })

    {account, run}
  end

  describe "create_request/3" do
    test "creates an approval request in :pending status" do
      {_account, run} = run_fixture()
      operator = user_fixture()

      assert {:ok, %Request{status: "pending", run_id: run_id}} =
               Approvals.create_request(run, operator.id, "high-risk action")

      assert run_id == run.id
    end
  end

  describe "approve/3" do
    test "transitions the run to :sent + writes an audit event" do
      {account, run} = run_fixture()
      operator = user_fixture()
      {:ok, req} = Approvals.create_request(run, operator.id, "needs approve")

      assert {:ok, {%Request{status: "approved"}, %ActionRun{status: "sent"}}} =
               Approvals.approve(req, operator.id, "lgtm")

      assert Enum.any?(
               Audit.list_events_for_account(account.id),
               &(&1.event_type == "approval.approved")
             )
    end
  end

  describe "deny/3" do
    test "transitions the run to :cancelled + writes an audit event" do
      {account, run} = run_fixture()
      operator = user_fixture()
      {:ok, req} = Approvals.create_request(run, operator.id, "needs approve")

      assert {:ok, {%Request{status: "denied"}, %ActionRun{status: "cancelled"}}} =
               Approvals.deny(req, operator.id, "not now")

      assert Enum.any?(
               Audit.list_events_for_account(account.id),
               &(&1.event_type == "approval.denied")
             )
    end
  end

  describe "list_pending/1" do
    test "only returns pending requests" do
      {account, run1} = run_fixture()
      {_, run2} = run_fixture(account: account)

      {:ok, req_pending} = Approvals.create_request(run1, user_fixture().id, nil)
      {:ok, req_to_deny} = Approvals.create_request(run2, user_fixture().id, nil)
      {:ok, _} = Approvals.deny(req_to_deny, user_fixture().id, "nope")

      ids = Approvals.list_pending(account.id) |> Enum.map(& &1.id)
      assert ids == [req_pending.id]
    end
  end
end
