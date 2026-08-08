defmodule Emisar.Runbooks.Jobs.ExecutionRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Fixtures, Repo}
  alias Emisar.Runbooks.Jobs.ExecutionRetention

  @beyond_window_days 30
  @within_window_days 1

  defp days_ago(days), do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

  test "runs daily because execution history has day-level retention precision" do
    assert %{
             id: ExecutionRetention,
             start: {_executor, :start_link, [{ExecutionRetention, interval, _config}]}
           } = ExecutionRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes executions completed past the account retention window" do
    account = Fixtures.Accounts.create_account()

    old =
      Fixtures.Runbooks.create_execution(
        account_id: account.id,
        completed_at: days_ago(@beyond_window_days)
      )

    assert :ok = ExecutionRetention.execute([])

    refute Repo.reload(old)
  end

  test "keeps executions completed inside the window, and any still running" do
    account = Fixtures.Accounts.create_account()

    recent =
      Fixtures.Runbooks.create_execution(
        account_id: account.id,
        completed_at: days_ago(@within_window_days)
      )

    # An execution with no completion stamp is still live; age must not prune it.
    running = Fixtures.Runbooks.create_execution(account_id: account.id)

    assert :ok = ExecutionRetention.execute([])

    assert Repo.reload(recent)
    assert Repo.reload(running)
  end

  test "uses the account plan's wider retention window" do
    account = Fixtures.Accounts.create_account(plan: "team")

    kept =
      Fixtures.Runbooks.create_execution(account_id: account.id, completed_at: days_ago(10))

    assert :ok = ExecutionRetention.execute([])

    assert Repo.reload(kept)
  end

  test "sweeps each account against its own window" do
    free = Fixtures.Accounts.create_account()
    team = Fixtures.Accounts.create_account(plan: "team")
    completed_at = days_ago(10)

    swept = Fixtures.Runbooks.create_execution(account_id: free.id, completed_at: completed_at)
    kept = Fixtures.Runbooks.create_execution(account_id: team.id, completed_at: completed_at)

    assert :ok = ExecutionRetention.execute([])

    refute Repo.reload(swept)
    assert Repo.reload(kept)
  end
end
