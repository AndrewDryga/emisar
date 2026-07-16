defmodule Emisar.Runs.Jobs.ActionRunRetentionTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Fixtures, Repo, Runs}
  alias Emisar.Runs.Jobs.ActionRunRetention
  alias Emisar.Runs.RunEvent

  @beyond_window_days 30
  @within_window_days 1

  defp finished_run(account, runner, finished_ago_days) do
    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "retention test",
        source: "operator"
      })

    finished_at = DateTime.utc_now() |> DateTime.add(-finished_ago_days * 86_400, :second)

    {:ok, run} =
      run
      |> Ecto.Changeset.change(status: :success, finished_at: finished_at)
      |> Repo.update()

    run
  end

  defp add_event(run) do
    {:ok, event} =
      RunEvent.Changeset.create(%{
        run_id: run.id,
        account_id: run.account_id,
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "line"}
      })
      |> Repo.insert()

    event
  end

  defp retention_markers(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type("audit.retention_swept")
    |> Repo.all()
  end

  defp backdate_inserted_at(record, timestamp) do
    record
    |> Ecto.Changeset.change(inserted_at: timestamp)
    |> Repo.update!()
  end

  test "runs daily because run history has day-level retention precision" do
    assert %{
             id: ActionRunRetention,
             start: {_executor, :start_link, [{ActionRunRetention, interval, _config}]}
           } = ActionRunRetention.child_spec([])

    assert interval == :timer.hours(24)
  end

  test "prunes old action runs and cascades their child rows" do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    old_run = finished_run(account, runner, @beyond_window_days)
    event = add_event(old_run)
    request = Fixtures.Approvals.create_request(account_id: account.id, run_id: old_run.id)

    assert :ok = ActionRunRetention.execute([])
    assert :ok = ActionRunRetention.execute([])

    refute Repo.reload(old_run)
    refute Repo.reload(event)
    refute Repo.reload(request)
  end

  test "keeps finished action runs within the account retention window" do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    kept = finished_run(account, runner, @within_window_days)

    assert :ok = ActionRunRetention.execute([])

    assert Repo.reload(kept)
  end

  test "uses the account plan's wider retention window" do
    account = Fixtures.Accounts.create_account(plan: "team")
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    kept = finished_run(account, runner, 10)

    assert :ok = ActionRunRetention.execute([])

    assert Repo.reload(kept)
  end

  test "keeps unfinished action runs regardless of age" do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "retention test",
        source: "operator"
      })

    old = DateTime.utc_now() |> DateTime.add(-@beyond_window_days * 86_400, :second)
    backdate_inserted_at(run, old)

    assert :ok = ActionRunRetention.execute([])

    assert Repo.reload(run)
  end

  test "does not create housekeeping markers for an inactive account" do
    account = Fixtures.Accounts.create_account()
    old = DateTime.utc_now() |> DateTime.add(-@beyond_window_days * 86_400, :second)

    {:ok, _marker} =
      Audit.log(account.id, "audit.retention_swept",
        actor_kind: "system",
        target_kind: "audit_log",
        occurred_at: old,
        payload: %{count: 1}
      )

    Fixtures.Accounts.mark_account_as_deleted(account)

    assert :ok = ActionRunRetention.execute([])
    assert :ok = ActionRunRetention.execute([])

    assert length(retention_markers(account.id)) == 1
  end
end
