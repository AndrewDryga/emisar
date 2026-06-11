defmodule Emisar.Workers.ApprovalExpiryTest do
  @moduledoc """
  The 5-minute sweep that auto-rejects approval requests past their
  `expires_at` and cancels the gated run, so an LLM can't hold a
  high-risk action open waiting for an operator who never decides.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Approvals, Repo, Runs}
  alias Emisar.Approvals.Request
  alias Emisar.Workers.ApprovalExpiry

  defp overdue_request do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        reason: "expiry sweep test"
      })

    {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")

    yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
    {:ok, request} = request |> Ecto.Changeset.change(expires_at: yesterday) |> Repo.update()
    {request, run}
  end

  test "perform/1 expires the overdue request and cancels its run" do
    {request, run} = overdue_request()

    assert :ok = ApprovalExpiry.perform(%Oban.Job{args: %{}})

    assert %Request{status: :expired} = Repo.reload!(request)
    assert Repo.reload!(run).status == :cancelled
  end

  test "perform/1 leaves a still-fresh pending request alone" do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        args: %{},
        reason: "still fresh"
      })

    {:ok, request} = Approvals.create_request(run, user_fixture().id, "x")

    assert :ok = ApprovalExpiry.perform(%Oban.Job{args: %{}})

    assert %Request{status: :pending} = Repo.reload!(request)
  end
end
