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
  alias Emisar.{Repo, Runners, Runs}
  alias Emisar.Runners.Presence
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

    run =
      run
      |> Fixtures.Runs.put_status(:running)
      |> Ecto.Changeset.change(runner_connection_generation: runner.connection_generation)
      |> Repo.update!()

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
  # re-dispatch's fresh sent timestamp is observable as a forward jump).
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

    run = Fixtures.Runs.put_status(run, :sent)
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second)

    run
    |> Ecto.Changeset.change(
      queued_at: at,
      sent_at: at,
      runner_connection_generation: runner.connection_generation
    )
    |> Repo.update!()
  end

  test "an online runner's stale sent run is re-dispatched, not failed" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 5 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :sent
    # The dispatch path re-stamped sent_at — proof it was re-sent, not no-op'd.
    assert DateTime.compare(reloaded.sent_at, run.sent_at) == :gt
  end

  test "an online runner that never acknowledges past the deadline goes terminal" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 20 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "never produced a durable result"
    assert reloaded.error_message =~ "outcome is unknown"
    assert reloaded.error_message =~ "did not execute it again"
  end

  test "an acknowledged quiet action is not mistaken for an unaccepted dispatch" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 20 * 60)

    assert {:ok, started} =
             Runs.mark_started_from_connection(
               runner.account_id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               run.request_id
             )

    assert started.status == :running
    assert %DateTime{} = started.started_at
    assert :ok = DispatchTimeout.execute([])
    assert Runs.peek_run_by_id(run.id).status == :running
  end

  test "a stale dispatch waits for a successor connection to replay its result" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 5 * 60)

    assert {:ok, _} =
             Runners.mark_disconnected(
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               "reconnect"
             )

    :ok = Presence.untrack(self(), Presence.topic(runner.account_id), runner.id)
    assert {:ok, successor} = Runners.connect_runner(runner)
    assert successor.connection_generation > runner.connection_generation

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :sent
    refute_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 100
  end

  test "a successor result that never arrives still resolves as outcome unknown" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = sent_run_for(runner, 20 * 60)

    assert {:ok, _} =
             Runners.mark_disconnected(
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               "reconnect"
             )

    :ok = Presence.untrack(self(), Presence.topic(runner.account_id), runner.id)
    assert {:ok, _successor} = Runners.connect_runner(runner)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "never produced a durable result"
    assert reloaded.error_message =~ "outcome is unknown"
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

  test "a cancelling run without a runner result resolves as outcome unknown" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    runner = backdate_disconnect!(runner, 10 * 60)

    run =
      runner
      |> running_run_for()
      |> Ecto.Changeset.change(status: :cancelling, reason_text: "operator requested stop")
      |> Repo.update!()

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "result never arrived"
  end

  test "a running run on a CONNECTED runner is left alone" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = running_run_for(runner)

    assert :ok = DispatchTimeout.execute([])

    assert Runs.peek_run_by_id(run.id).status == :running
  end

  test "a running run is left active after its runner reconnects" do
    runner = Fixtures.Runners.create_runner(connected?: true)
    run = running_run_for(runner)

    assert {:ok, _} =
             Runners.mark_disconnected(
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id,
               "reconnect"
             )

    :ok = Presence.untrack(self(), Presence.topic(runner.account_id), runner.id)
    assert {:ok, successor} = Runners.connect_runner(runner)
    assert successor.connection_generation > runner.connection_generation

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

  # A sent dispatch may already have produced side effects. If its runner
  # disconnects, the operator must see that the outcome is unknown and that
  # Emisar deliberately refused to execute it again.
  test "a disconnected runner's stale sent dispatch reports an unknown outcome" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    run = sent_run_for(runner, 5 * 60)

    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "disconnected after accepting this dispatch"
    assert reloaded.error_message =~ "outcome is unknown"
    assert reloaded.error_message =~ "did not execute it again"
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

  test "a sent run whose runner was deleted reports an unknown outcome" do
    {account, _user, subject} = owner_with_subject()
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    run = sent_run_for(runner, 5 * 60)

    {:ok, _} = Emisar.Runners.delete_runner(runner, subject)
    assert :ok = DispatchTimeout.execute([])

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == :error
    assert reloaded.error_message =~ "removed after accepting this dispatch"
    assert reloaded.error_message =~ "outcome is unknown"
    assert reloaded.error_message =~ "did not execute it again"
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
