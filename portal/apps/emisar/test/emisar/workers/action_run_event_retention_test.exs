defmodule Emisar.Workers.ActionRunEventRetentionTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Runs
  alias Emisar.Runs.RunEvent
  alias Emisar.Workers.ActionRunEventRetention

  # The free plan retains 7 days; pick boundaries comfortably on either side.
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

  defp add_event(run, seq) do
    {:ok, event} =
      RunEvent.Changeset.create(%{
        run_id: run.id,
        account_id: run.account_id,
        seq: seq,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "line #{seq}"}
      })
      |> Repo.insert()

    event
  end

  defp event_ids(account_id) do
    RunEvent.Query.all()
    |> RunEvent.Query.by_account_id(account_id)
    |> Repo.all()
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  test "prunes events of runs finished outside the retention window" do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)
    old_run = finished_run(account, runner, @beyond_window_days)
    add_event(old_run, 1)
    add_event(old_run, 2)

    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{}})

    assert event_ids(account.id) == MapSet.new()
  end

  test "keeps events of recently-finished runs" do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)
    recent_run = finished_run(account, runner, @within_window_days)
    kept = add_event(recent_run, 1)

    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{}})

    assert event_ids(account.id) == MapSet.new([kept.id])
  end

  test "keeps events of runs that never finished, regardless of age" do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)

    {:ok, unfinished} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "retention test",
        source: "operator"
      })

    # Backdate insertion so only the null `finished_at` keeps it alive.
    old = DateTime.utc_now() |> DateTime.add(-@beyond_window_days * 86_400, :second)
    unfinished |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
    kept = add_event(unfinished, 1)

    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{}})

    assert event_ids(account.id) == MapSet.new([kept.id])
  end

  # an account whose subscription carries an unknown /
  # renamed plan name resolves to the free window rather than crashing, so the
  # run-event prune (which keys on the SAME plan lookup as audit retention)
  # degrades gracefully on a legacy plan string.
  test "falls back to the free window when the plan is unresolvable" do
    account = account_fixture()
    subscription_fixture(account, "legacy-unlisted-plan")
    runner = runner_fixture(account_id: account.id)
    old_run = finished_run(account, runner, @beyond_window_days)
    add_event(old_run, 1)

    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{}})

    # 30 days > the free fallback's 7-day window → pruned.
    assert event_ids(account.id) == MapSet.new()
  end

  # the sweep pages accounts via `Account.Query.all`, not
  # `not_deleted()`, on purpose: a soft-deleted (closed) account's run events
  # still occupy space and age past the plan window all the same. A regression to
  # `not_deleted()` would leave a closed tenant's chunks growing forever.
  test "prunes a tombstoned account's events for runs finished past the window" do
    account = account_fixture()
    runner = runner_fixture(account_id: account.id)
    old_run = finished_run(account, runner, @beyond_window_days)
    add_event(old_run, 1)

    # Soft-delete the account (a direct row write — the fixture way to set the
    # tombstone state; no Subject path deletes an account in this test).
    account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{}})

    assert event_ids(account.id) == MapSet.new()
  end

  test "does not prune another account's events" do
    account_a = account_fixture()
    runner_a = runner_fixture(account_id: account_a.id)
    old_a = finished_run(account_a, runner_a, @beyond_window_days)
    add_event(old_a, 1)

    account_b = account_fixture()
    runner_b = runner_fixture(account_id: account_b.id)
    old_b = finished_run(account_b, runner_b, @beyond_window_days)
    kept_b = add_event(old_b, 1)

    # The worker sweeps every account, so to prove the per-account scoping
    # itself we run the account-scoped delete pipeline for A and confirm
    # B's equally-old events are untouched.
    {n, _} =
      RunEvent.Query.all()
      |> RunEvent.Query.by_account_id(account_a.id)
      |> RunEvent.Query.by_run_finished_before(DateTime.utc_now())
      |> Repo.delete_all()

    assert n == 1
    assert event_ids(account_a.id) == MapSet.new()
    assert event_ids(account_b.id) == MapSet.new([kept_b.id])
  end

  test "pages accounts via a continuation cursor and prunes them all" do
    accounts = for _ <- 1..3, do: account_fixture()

    for account <- accounts do
      runner = runner_fixture(account_id: account.id)
      old_run = finished_run(account, runner, @beyond_window_days)
      add_event(old_run, 1)
    end

    # `limit: 1` forces one account per page, so the run only completes by
    # following its own continuation cursor account-to-account (inline test mode
    # runs each enqueued follow-up synchronously). All three must be pruned.
    assert :ok = ActionRunEventRetention.perform(%Oban.Job{args: %{"limit" => 1}})

    for account <- accounts, do: assert(event_ids(account.id) == MapSet.new())
  end
end
