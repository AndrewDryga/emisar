defmodule Emisar.Runners.Jobs.InactiveRunnerRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures, Repo}
  alias Emisar.Runners.Jobs.InactiveRunnerRetention

  @beyond_window_days 40
  @window_days 30

  defp offline_runner(account, days_ago) do
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    Fixtures.Runners.mark_disconnected_at(runner, at)
  end

  defp retention_markers(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type("runner.retention_swept")
    |> Repo.all()
  end

  test "runs daily because the retention promise has day-level precision" do
    assert %{
             id: InactiveRunnerRetention,
             start: {_executor, :start_link, [{InactiveRunnerRetention, interval, _config}]}
           } = InactiveRunnerRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes runners offline past a subscribed account's window (idempotently)" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_account_settings(account, %{
      runner_inactive_retention_days: @window_days
    })

    runner = offline_runner(account, @beyond_window_days)

    assert :ok = InactiveRunnerRetention.execute([])
    assert :ok = InactiveRunnerRetention.execute([])

    # Soft-delete: the row survives (audit/run history intact), but it's gone
    # from the not_deleted scope and stamped deleted_at.
    assert %DateTime{} = Repo.reload!(runner).deleted_at
    assert length(retention_markers(account.id)) == 1
  end

  test "keeps runners offline within the window" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_account_settings(account, %{
      runner_inactive_retention_days: @window_days
    })

    runner = offline_runner(account, 10)

    assert :ok = InactiveRunnerRetention.execute([])

    assert is_nil(Repo.reload!(runner).deleted_at)
  end

  test "skips accounts without the retention setting" do
    account = Fixtures.Accounts.create_account()
    runner = offline_runner(account, @beyond_window_days)

    assert :ok = InactiveRunnerRetention.execute([])

    assert is_nil(Repo.reload!(runner).deleted_at)
    assert retention_markers(account.id) == []
  end

  test "leaves no housekeeping marker for an account with nothing to remove" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_account_settings(account, %{
      runner_inactive_retention_days: @window_days
    })

    assert :ok = InactiveRunnerRetention.execute([])
    assert :ok = InactiveRunnerRetention.execute([])

    assert retention_markers(account.id) == []
  end
end
