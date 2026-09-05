defmodule Emisar.Runners.Jobs.InactiveRunnerRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures, Repo}
  alias Emisar.Runners.Jobs.InactiveRunnerRetention

  @beyond_window_hours 7
  @window_hours 6

  defp offline_runner(account, hours_ago, attrs \\ []) do
    runner =
      Fixtures.Runners.create_runner([account_id: account.id, connected?: false] ++ attrs)

    at = DateTime.add(DateTime.utc_now(), -hours_ago * 3_600, :second)
    Fixtures.Runners.mark_disconnected_at(runner, at)
  end

  defp retention_markers(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type("runner.retention_swept")
    |> Repo.all()
  end

  test "runs hourly because the retention promise has hour-level precision" do
    assert %{
             id: InactiveRunnerRetention,
             start: {_executor, :start_link, [{InactiveRunnerRetention, interval, _config}]}
           } = InactiveRunnerRetention.child_spec([])

    assert interval == :timer.hours(1)
  end

  test "prunes runners offline past a subscribed account's window (idempotently)" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_runner_inactive_retention_hours(account, @window_hours)

    runner = offline_runner(account, @beyond_window_hours)

    assert InactiveRunnerRetention.execute([]) == :ok
    assert InactiveRunnerRetention.execute([]) == :ok

    # Soft-delete: the row survives (audit/run history intact), but it's gone
    # from the not_deleted scope and stamped deleted_at.
    assert %DateTime{} = Repo.reload!(runner).deleted_at
    assert length(retention_markers(account.id)) == 1
  end

  test "sweeps every runner group account-wide — the system tick applies no operator scope" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_runner_inactive_retention_hours(account, @window_hours)

    db = offline_runner(account, @beyond_window_hours, group: "db")
    app = offline_runner(account, @beyond_window_hours, group: "app")

    assert InactiveRunnerRetention.execute([]) == :ok

    # No subject → scope_to_subject_membership is never composed, so runners in
    # any group are removed. One rolled-up marker covers the whole sweep.
    assert %DateTime{} = Repo.reload!(db).deleted_at
    assert %DateTime{} = Repo.reload!(app).deleted_at
    assert length(retention_markers(account.id)) == 1
  end

  test "keeps runners offline within the window" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_runner_inactive_retention_hours(account, @window_hours)

    runner = offline_runner(account, 3)

    assert InactiveRunnerRetention.execute([]) == :ok

    assert is_nil(Repo.reload!(runner).deleted_at)
  end

  test "skips accounts without the retention setting" do
    account = Fixtures.Accounts.create_account()
    runner = offline_runner(account, @beyond_window_hours)

    assert InactiveRunnerRetention.execute([]) == :ok

    assert is_nil(Repo.reload!(runner).deleted_at)
    assert retention_markers(account.id) == []
  end

  test "skips an account whose stored window is unusable" do
    account = Fixtures.Accounts.create_account()
    Fixtures.Accounts.force_runner_inactive_retention_hours(account, 0)
    runner = offline_runner(account, @beyond_window_hours)

    assert InactiveRunnerRetention.execute([]) == :ok

    assert is_nil(Repo.reload!(runner).deleted_at)
    assert retention_markers(account.id) == []
  end

  test "leaves no housekeeping marker for an account with nothing to remove" do
    account = Fixtures.Accounts.create_account()

    Fixtures.Accounts.set_runner_inactive_retention_hours(account, @window_hours)

    assert InactiveRunnerRetention.execute([]) == :ok
    assert InactiveRunnerRetention.execute([]) == :ok

    assert retention_markers(account.id) == []
  end

  test "pages accounts and runner candidates independently with one receipt per changed batch" do
    accounts = for _ <- 1..2, do: Fixtures.Accounts.create_account()

    for account <- accounts do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, @window_hours)
      for _ <- 1..3, do: offline_runner(account, @beyond_window_hours)
    end

    assert InactiveRunnerRetention.execute(limit: 1, batch_size: 2) == :ok
    assert InactiveRunnerRetention.execute(limit: 1, batch_size: 2) == :ok

    for account <- accounts do
      counts = account.id |> retention_markers() |> Enum.map(& &1.payload["count"]) |> Enum.sort()
      assert counts == [1, 2]
    end
  end
end
