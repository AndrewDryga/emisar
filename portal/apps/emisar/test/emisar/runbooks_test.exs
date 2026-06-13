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

  defp draft_runbook!(subject, title) do
    {:ok, runbook} =
      Runbooks.create_runbook(
        %{
          "title" => title,
          "name" => title,
          "slug" => title,
          "definition" => %{"steps" => uptime_steps(1)}
        },
        subject
      )

    runbook
  end

  defp uptime_steps(count) do
    for n <- 1..count, do: %{"id" => "step#{n}", "action_id" => "linux.uptime", "args" => %{}}
  end

  defp draft_with_steps(subject, steps) do
    title = "rb-#{System.unique_integer([:positive])}"

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

    runbook
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
      assert denied.status == :denied
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

  describe "reads (list + fetch)" do
    test "list_runbooks returns the caller's own runbooks" do
      {_user, _account, subject} = owner_subject_fixture()
      alpha = draft_runbook!(subject, "alpha-book")
      beta = draft_runbook!(subject, "beta-book")

      assert {:ok, runbooks, _meta} = Runbooks.list_runbooks(subject)
      ids = Enum.map(runbooks, & &1.id)
      assert alpha.id in ids
      assert beta.id in ids
    end

    test "list_runbooks never returns another account's runbooks" do
      {_user, _account_a, subject_a} = owner_subject_fixture()
      _ = draft_runbook!(subject_a, "mine-book")

      {_user, _account_b, subject_b} = owner_subject_fixture()
      _ = draft_runbook!(subject_b, "theirs-book")

      {:ok, runbooks, _meta} = Runbooks.list_runbooks(subject_a)
      titles = Enum.map(runbooks, & &1.title)
      assert "mine-book" in titles
      refute "theirs-book" in titles
    end

    test "fetch_runbook_by_id returns the caller's own runbook" do
      {_user, _account, subject} = owner_subject_fixture()
      runbook = draft_runbook!(subject, "fetchme-book")

      assert {:ok, fetched} = Runbooks.fetch_runbook_by_id(runbook.id, subject)
      assert fetched.id == runbook.id
    end

    test "fetch_runbook_by_id can't reach across accounts" do
      {_user, _account_a, subject_a} = owner_subject_fixture()
      {_user, _account_b, subject_b} = owner_subject_fixture()
      theirs = draft_runbook!(subject_b, "secret-book")

      assert {:error, :not_found} = Runbooks.fetch_runbook_by_id(theirs.id, subject_a)
    end

    test "fetch_runbook_by_id with a non-uuid id is a clean :not_found" do
      {_user, _account, subject} = owner_subject_fixture()
      assert {:error, :not_found} = Runbooks.fetch_runbook_by_id("not-a-uuid", subject)
    end
  end

  describe "save_new_version/3" do
    test "bumps the version, persists the new attrs, and leaves the old row intact" do
      {_user, _account, subject} = owner_subject_fixture()
      v1 = draft_runbook!(subject, "ver-book")

      assert {:ok, v2} = Runbooks.save_new_version(v1, %{"title" => "ver-book take two"}, subject)

      assert v2.version == v1.version + 1
      assert v2.title == "ver-book take two"
      assert v2.id != v1.id
      # The prior version is its own row and stays fetchable.
      assert {:ok, _} = Runbooks.fetch_runbook_by_id(v1.id, subject)
    end

    test "a viewer (no manage permission) is refused" do
      {_user, account, subject} = owner_subject_fixture()
      v1 = draft_runbook!(subject, "guard-book")
      viewer = subject_for(user_fixture(), account, role: :viewer)

      assert {:error, :unauthorized} =
               Runbooks.save_new_version(v1, %{"title" => "nope"}, viewer)
    end

    test "an owner of another account can't version this runbook" do
      {_user, _account_a, subject_a} = owner_subject_fixture()
      v1 = draft_runbook!(subject_a, "owned-book")

      {_user, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :not_found} =
               Runbooks.save_new_version(v1, %{"title" => "hijack"}, subject_b)
    end
  end

  describe "create_runbook slug validation" do
    test "rejects a slug that doesn't match the URL-safe format" do
      {_user, _account, subject} = owner_subject_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runbooks.create_runbook(
                 %{
                   "title" => "Bad Slug Book",
                   "name" => "bad-slug",
                   "slug" => "Not A Valid Slug!",
                   "definition" => %{"steps" => uptime_steps(1)}
                 },
                 subject
               )

      assert %{slug: ["has invalid format"]} = errors_on(changeset)
    end
  end

  describe "publish step validation" do
    test "a draft saves with an incomplete (blank-action) step — WIP is allowed" do
      {_user, _account, subject} = owner_subject_fixture()
      draft = draft_with_steps(subject, [%{"id" => "s1", "action_id" => "", "args" => %{}}])
      assert draft.status == :draft
    end

    test "publishing a blank-action step is rejected" do
      {_user, _account, subject} = owner_subject_fixture()
      draft = draft_with_steps(subject, [%{"id" => "s1", "action_id" => "", "args" => %{}}])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)
      assert "every step needs an action before publishing" in errors_on(changeset).definition
    end

    test "publishing an empty runbook is rejected" do
      {_user, _account, subject} = owner_subject_fixture()
      draft = draft_with_steps(subject, [])

      assert {:error, %Ecto.Changeset{} = changeset} = Runbooks.publish(draft, subject)
      assert "add at least one step before publishing" in errors_on(changeset).definition
    end

    test "publishing valid steps succeeds" do
      {_user, _account, subject} = owner_subject_fixture()

      draft =
        draft_with_steps(subject, [%{"id" => "s1", "action_id" => "linux.uptime", "args" => %{}}])

      assert {:ok, runbook} = Runbooks.publish(draft, subject)
      assert runbook.status == :published
    end
  end
end
