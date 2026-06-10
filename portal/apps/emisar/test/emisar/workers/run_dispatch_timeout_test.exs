defmodule Emisar.Workers.RunDispatchTimeoutTest do
  @moduledoc """
  Covers the mid-run zombie pass: a run stuck in `running` after its
  runner died must reach a terminal state, or every `wait_for_run`
  long-poll spins forever. The pending/sent pass is covered alongside
  the socket lifecycle in `EmisarWeb.RunnerSocketTest`.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Repo, Runs}
  alias Emisar.Workers.RunDispatchTimeout

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

  test "a running run whose runner has been offline past the grace goes terminal" do
    runner = runner_fixture(connected?: false)
    runner = backdate_disconnect!(runner, 10 * 60)
    run = running_run_for(runner)

    assert :ok = RunDispatchTimeout.perform(%Oban.Job{args: %{}})

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == "error"
    assert reloaded.error_message =~ "disconnected while this run was in flight"
  end

  test "a running run on a CONNECTED runner is left alone" do
    runner = runner_fixture(connected?: true)
    run = running_run_for(runner)

    assert :ok = RunDispatchTimeout.perform(%Oban.Job{args: %{}})

    assert Runs.peek_run_by_id(run.id).status == "running"
  end

  test "a recently-dropped runner gets reconnect grace before its runs are killed" do
    runner = runner_fixture(connected?: false)
    runner = backdate_disconnect!(runner, 5)
    run = running_run_for(runner)

    assert :ok = RunDispatchTimeout.perform(%Oban.Job{args: %{}})

    assert Runs.peek_run_by_id(run.id).status == "running"
  end

  test "a running run whose runner row was deleted goes terminal" do
    {account, _user, subject} = owner_with_subject()
    runner = runner_fixture(account_id: account.id, connected?: false)
    run = running_run_for(runner)

    {:ok, _} = Emisar.Runners.delete_runner(runner, subject)

    assert :ok = RunDispatchTimeout.perform(%Oban.Job{args: %{}})

    reloaded = Runs.peek_run_by_id(run.id)
    assert reloaded.status == "error"
    assert reloaded.error_message =~ "removed while this run was in flight"
  end

  defp owner_with_subject do
    user = user_fixture()
    account = account_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    {account, user, subject_for(user, account, role: :owner)}
  end
end
