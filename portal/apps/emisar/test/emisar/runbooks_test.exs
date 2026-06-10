defmodule Emisar.RunbooksTest do
  @moduledoc """
  The runbook wave engine: `dispatch_runbook/4` expands steps × target
  runners into an execution, releases work in waves of five, and
  `dispatch_next_batch/1` (fired from `Runs.mark_finished/2`) advances
  the waves — halting behind any failed or denied run.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Runbooks, Runners, Runs}

  defp account_with_runner do
    {_user, account, subject} = owner_subject_fixture()
    _ = policy_fixture(account_id: account.id)
    runner = runner_fixture(account_id: account.id)
    _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
    {account, subject, runner}
  end

  defp published_runbook!(subject, title, steps) do
    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => title,
          "definition" => %{"steps" => steps}
        },
        subject
      )

    {:ok, runbook} = Runbooks.publish(runbook, subject)
    runbook
  end

  defp uptime_steps(count) do
    for n <- 1..count, do: %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => %{}}
  end

  defp finish!(run), do: {:ok, _} = Runs.mark_finished(run, %{"status" => "success"})

  defp execution_runs(account, execution_id),
    do: Runs.list_runs_for_runbook_execution(account.id, execution_id)

  defp step_ids(runs), do: runs |> Enum.map(& &1.runbook_step_id) |> Enum.sort()

  describe "dispatch_runbook/4" do
    test "dispatches a small runbook in one wave, stamped with the execution" do
      {_account, subject, runner} = account_with_runner()
      runbook = published_runbook!(subject, "deploy-check", uptime_steps(3))

      assert {:ok, %{execution_id: execution_id, total: 3, runs: runs, errors: []}} =
               Runbooks.dispatch_runbook(runbook, {:runner, runner.id}, "release 42", subject)

      assert step_ids(runs) == ["step1", "step2", "step3"]

      for run <- runs do
        assert run.runbook_id == runbook.id
        assert run.runbook_execution_id == execution_id
        assert run.runner_id == runner.id

        assert run.runbook_dispatch == %{
                 "target" => %{"runner_id" => runner.id},
                 "reason" => "release 42"
               }
      end

      # The visible reason is prefixed per step; the raw operator reason
      # rides in the dispatch descriptor for continuation re-prefixing.
      step1 = Enum.find(runs, &(&1.runbook_step_id == "step1"))
      assert step1.reason == "runbook: deploy-check • step 1/3 — release 42"
    end

    test "a group target fans every step out across the group's active runners" do
      {account, subject, runner} = account_with_runner()

      peer = runner_fixture(account_id: account.id, group: runner.group)
      _ = action_fixture(runner: peer, action_id: "linux.uptime", risk: "low")

      # Noise the resolver must skip: a disabled runner in the group, an
      # active runner in another group, and another account's runner in a
      # same-named group.
      disabled = runner_fixture(account_id: account.id, group: runner.group, connected?: false)
      {:ok, _} = Runners.disable_runner(disabled, subject)
      _ = runner_fixture(account_id: account.id, group: "elsewhere")
      _ = runner_fixture(group: runner.group)

      runbook = published_runbook!(subject, "fleet-sweep", uptime_steps(2))

      assert {:ok, %{total: 4, runs: runs, errors: []}} =
               Runbooks.dispatch_runbook(runbook, {:group, runner.group}, "audit", subject)

      assert length(runs) == 4

      dispatched_runner_ids = runs |> Enum.map(& &1.runner_id) |> Enum.uniq() |> Enum.sort()
      assert dispatched_runner_ids == Enum.sort([runner.id, peer.id])
    end

    test "a group with no active runners refuses dispatch" do
      {_account, subject, _runner} = account_with_runner()
      runbook = published_runbook!(subject, "ghost-town", uptime_steps(1))

      assert {:error, :no_runners_in_group} =
               Runbooks.dispatch_runbook(runbook, {:group, "ghost"}, "audit", subject)
    end

    test "a policy denial writes the denied row into the execution" do
      {_user, account, subject} = owner_subject_fixture()

      _ =
        policy_fixture(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "deny",
              "medium" => "deny",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      runbook = published_runbook!(subject, "denied-book", uptime_steps(1))

      assert {:ok, %{execution_id: execution_id, total: 1, runs: [], errors: []}} =
               Runbooks.dispatch_runbook(runbook, {:runner, runner.id}, "try", subject)

      assert [denied] = execution_runs(account, execution_id)
      assert denied.status == "denied"
      assert denied.runbook_step_id == "step1"
    end
  end

  describe "wave advancement" do
    test "releases the next wave only when the whole wave finishes" do
      {account, subject, runner} = account_with_runner()
      runbook = published_runbook!(subject, "seven-steps", uptime_steps(7))

      assert {:ok, %{execution_id: execution_id, total: 7, runs: wave1}} =
               Runbooks.dispatch_runbook(runbook, {:runner, runner.id}, "go", subject)

      assert step_ids(wave1) == ["step1", "step2", "step3", "step4", "step5"]

      # Finishing part of the wave doesn't release the next one.
      wave1 |> Enum.take(4) |> Enum.each(&finish!/1)
      assert length(execution_runs(account, execution_id)) == 5

      # The last finisher does.
      wave1 |> List.last() |> finish!()

      runs = execution_runs(account, execution_id)
      assert step_ids(runs) == ["step1", "step2", "step3", "step4", "step5", "step6", "step7"]
    end

    test "a failed run halts the waves behind it" do
      {account, subject, runner} = account_with_runner()
      runbook = published_runbook!(subject, "halting-book", uptime_steps(7))

      assert {:ok, %{execution_id: execution_id, runs: [first | rest]}} =
               Runbooks.dispatch_runbook(runbook, {:runner, runner.id}, "go", subject)

      {:ok, _} = Runs.mark_finished(first, %{"status" => "failed", "exit_code" => 1})
      Enum.each(rest, &finish!/1)

      # Steps 6-7 never dispatch; the in-flight wave finished naturally.
      assert length(execution_runs(account, execution_id)) == 5

      # Halting is engine behavior, not a dispatch failure — no audit noise.
      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 50])
      refute Enum.any?(events, &(&1.event_type == "runbook.step_dispatch_failed"))
    end

    test "the (execution, step, runner) unique index rejects a duplicate slot claim" do
      {_account, subject, runner} = account_with_runner()
      runbook = published_runbook!(subject, "race-book", uptime_steps(1))

      assert {:ok, %{execution_id: execution_id, runs: [run]}} =
               Runbooks.dispatch_runbook(runbook, {:runner, runner.id}, "go", subject)

      assert {:error, changeset} =
               Runs.create_run(%{
                 account_id: run.account_id,
                 runner_id: runner.id,
                 action_id: "linux.uptime",
                 reason: "racer",
                 source: "runbook",
                 runbook_id: runbook.id,
                 runbook_step_id: run.runbook_step_id,
                 runbook_execution_id: execution_id
               })

      assert {_msg, opts} = changeset.errors[:runbook_execution_id]
      assert opts[:constraint_name] == "action_runs_execution_step_runner_index"
    end
  end
end
