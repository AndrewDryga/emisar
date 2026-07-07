defmodule Emisar.Runs.Jobs.DispatchTimeoutTest do
  @moduledoc """
  Covers the mid-run zombie pass (a run stuck in `running` after its
  runner died must reach a terminal state, or every `wait_for_run`
  long-poll spins forever) and the pending/sent recovery pass: an online
  runner's stale dispatch is re-sent (idempotent), and one that stays
  unacknowledged past the deadline goes terminal. The offline pending/sent
  case is covered alongside the socket lifecycle in `EmisarWeb.RunnerSocketTest`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.{Repo, Runs}
  alias Emisar.Runs.Jobs.DispatchTimeout

  defp running_run_for(runner) do
    {:ok, run} =
      Runs.create_run(%{
        account_id: runner.account_id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "test",
        source: "operator"
      })

    {:ok, run} = Runs.mark_sent(run)
    {:ok, run} = Runs.mark_running(run)
    run
  end

  defp backdate_disconnect!(runner, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second)

    runner
    |> Ecto.Changeset.change(last_disconnected_at: at)
    |> Repo.update!()
  end

  # A run dispatched (`:sent`) but never acknowledged, queued `seconds_ago`.
  # Backdates `queued_at` (the sweep's staleness key) and `sent_at` (so a
  # re-dispatch's fresh `mark_sent` is observable as a forward jump).
  defp sent_run_for(runner, seconds_ago) do
    {:ok, run} =
      Runs.create_run(%{
        account_id: runner.account_id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        args: %{},
        reason: "test",
        source: "operator"
      })

    {:ok, run} = Runs.mark_sent(run)
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second)

    run
    |> Ecto.Changeset.change(queued_at: at, sent_at: at)
    |> Repo.update!()
  end

  test "an online runner's stale sent run is re-dispatched, not failed" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 5 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :sent
    # mark_sent re-stamped sent_at — proof the dispatch was re-sent, not no-op'd.
    assert DateTime.compare(reloaded.sent_at, run.sent_at) == :gt
  end

  test "an online runner that never acknowledges past the deadline goes terminal" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 20 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "never acknowledged"
  end

  test "a running run whose runner has been offline past the grace goes terminal" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    runner = backdate_disconnect!(runner, 10 * 60)
    run = running_run_for(runner)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "disconnected while this run was in flight"
  end

  test "a running run on a CONNECTED runner is left alone" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = running_run_for(runner)

    assert :ok = DispatchTimeout.execute([])

    assert Runs.peek_run_by_id(run.id).status == :running
  end

  test "a recently-dropped runner gets reconnect grace before its runs are killed" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    runner = backdate_disconnect!(runner, 5)
    run = running_run_for(runner)

    assert :ok = DispatchTimeout.execute([])

    assert Runs.peek_run_by_id(run.id).status == :running
  end

  # a running run on an offline runner whose
  # last_disconnected_at is nil is an inconsistent state (a run can't have
  # started without the runner connecting). offline_past_grace? treats nil as
  # "past grace" → expire, rather than leaving the run wedged forever.
  test "a running run on an offline runner with no recorded disconnect goes terminal" do
    # connected?: false never calls connect_runner, so last_connected_at AND
    # last_disconnected_at are both nil — the exact inconsistent state.
    runner = Fixtures.Runners.create_runner(connected?: false)
    assert is_nil(Repo.reload!(runner).last_disconnected_at)
    run = running_run_for(runner)

    assert :ok = DispatchTimeout.execute([])

    assert Runs.peek_run_by_id(run.id).status == :error
  end

  # each terminal branch stamps its OWN error_message so
  # the operator sees WHY a run died (offline-at-dispatch vs disabled vs wedged
  # vs runner-removed), not a generic "errored". Here: an offline runner whose
  # stale dispatch never reached it.
  test "an offline runner's stale dispatch is errored with an 'offline ... never reached it' message" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    run = sent_run_for(runner, 5 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "offline"
    assert reloaded.error_message =~ "never reached it"
  end

  # the disabled-runner branch names "disabled", distinct
  # from the offline copy above.
  test "a disabled runner's stale dispatch is errored with a 'disabled' message" do
    {account, _user, subject} = owner_with_subject()
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    {:ok, _} = Emisar.Runners.disable_runner(runner, subject)
    run = sent_run_for(runner, 5 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "disabled"
  end

  test "a running run whose runner row was deleted goes terminal" do
    {account, _user, subject} = owner_with_subject()
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    run = running_run_for(runner)

    {:ok, _} = Emisar.Runners.delete_runner(runner, subject)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "removed while this run was in flight"
  end

  defp owner_with_subject do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    {account, user, Fixtures.Subjects.subject_for(user, account, role: :owner)}
  end
end
