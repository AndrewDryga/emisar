defmodule Emisar.Runbooks.SchedulerConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Approvals, Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Accounts.Account
  alias Emisar.Runbooks.{ExecutionItem, RunbookExecution, Scheduler}
  alias Emisar.Users.User

  @hash "sha256:" <> String.duplicate("d", 64)

  @tag timeout: 120_000
  test "two concurrent maximum-size launches admit only the account capacity that remains" do
    unboxed_account(fn account, subject, first_runner ->
      runners =
        [first_runner] ++
          for _position <- 2..16 do
            trusted_runner(account, subject, group: first_runner.group)
          end

      Enum.each(runners, &Runners.subscribe_runner_transport/1)

      steps = for position <- 1..16, do: step("inspect-#{position}", first_runner.group)

      runbook =
        published_runbook(
          subject,
          definition([stage("inspect", "parallel", 16, steps)])
        )

      for position <- 1..3 do
        assert {:ok, result} =
                 Runbooks.dispatch_runbook(runbook, "capacity baseline #{position}", subject)

        assert result.total == 256
      end

      results =
        concurrently([
          fn -> Runbooks.dispatch_runbook(runbook, "capacity contender one", subject) end,
          fn -> Runbooks.dispatch_runbook(runbook, "capacity contender two", subject) end
        ])

      assert Enum.count(results, &match?({:ok, %{total: 256}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :runbook_capacity_exceeded})) == 1

      active_items =
        ExecutionItem.Query.active_workload_for_account(account.id)
        |> ExecutionItem.Query.select_count()
        |> Repo.one()

      assert active_items == 1_024

      active_executions =
        RunbookExecution.Query.active()
        |> where([runbook_executions: execution], execution.account_id == ^account.id)
        |> RunbookExecution.Query.select_count()
        |> Repo.one()

      assert active_executions == 4
    end)
  end

  @tag timeout: 60_000
  test "repeated concurrent due-wait advances create one next attempt" do
    unboxed_account(fn account, subject, runner ->
      Runners.subscribe_runner_transport(runner)

      runbook =
        published_runbook(
          subject,
          definition([stage("observe", "sequential", 5, [waiting_step(runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "wait contention", subject)
      assert [first_attempt] = runs(account.id, result.execution_id)

      assert {:ok, _finished} =
               Fixtures.Runs.finish(first_attempt, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => false}
               })

      item =
        ExecutionItem.Query.by_execution_id(result.execution_id)
        |> Repo.one!()
        |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
        |> Repo.update!()

      # The unboxed parent owns one connection. Keep every contender independent
      # without asking the readiness barrier to admit more workers than the pool.
      contender_count = min(12, Keyword.fetch!(Repo.config(), :pool_size) - 1)
      assert contender_count >= 2

      results =
        for _wave <- 1..10,
            outcome <-
              1..contender_count
              |> Enum.map(fn _position ->
                fn -> Scheduler.advance_execution(result.execution_id) end
              end)
              |> concurrently(),
            do: outcome

      assert Enum.all?(results, &(&1 in [:ok, :noop]))
      assert length(results) == 10 * contender_count
      assert Enum.map(runs(account.id, result.execution_id), & &1.attempt_number) == [1, 2]

      reloaded = Repo.reload!(item)
      assert reloaded.status == :running
      assert reloaded.attempt_count == 2
    end)
  end

  @tag timeout: 60_000
  test "cancellation racing the execution approval cannot resurrect the runbook" do
    unboxed_account(fn account, subject, runner ->
      Runners.subscribe_runner_transport(runner)

      _policy =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          created_by_id: subject.actor.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "require_approval",
              "medium" => "require_approval",
              "high" => "require_approval",
              "critical" => "require_approval"
            },
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      runbook =
        published_runbook(
          subject,
          definition([stage("change", "sequential", 5, [step("apply", runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "approval contention", subject)
      assert runs(account.id, result.execution_id) == []
      assert execution(result.execution_id).status == :pending_approval

      assert {:ok, [request], _metadata} =
               Approvals.list_pending_approval_requests(subject)

      assert request.runbook_execution_id == result.execution_id
      assert is_nil(request.run_id)

      [cancel_result, approve_result] =
        concurrently([
          fn -> Runbooks.cancel_execution(result.execution_id, subject) end,
          fn -> Approvals.approve_request(request, subject, "race approval") end
        ])

      assert match?({:ok, %{status: :cancelled}}, cancel_result)

      assert match?({:ok, _}, approve_result) or
               approve_result in [
                 {:error, :already_decided},
                 {:error, :run_cancelled},
                 {:error, :runbook_execution_not_approvable}
               ]

      assert Scheduler.advance_execution(result.execution_id) in [:ok, :noop]
      assert Scheduler.recover_due() >= 0

      cancelled = execution(result.execution_id)
      assert cancelled.status == :cancelled
      assert runs(account.id, result.execution_id) == []

      assert ExecutionItem.Query.by_execution_id(result.execution_id)
             |> Repo.one!()
             |> Map.fetch!(:status) == :cancelled

      assert {:ok, [], _metadata} = Approvals.list_pending_approval_requests(subject)
    end)
  end

  defp unboxed_account(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      user =
        Fixtures.Users.create_user(%{
          email: "scheduler-concurrency-#{suffix}@example.test"
        })

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Scheduler concurrency #{suffix}", slug: "scheduler-concurrency-#{suffix}"},
          user
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      _policy =
        Fixtures.Policies.create_policy(account_id: account.id, created_by_id: user.id)

      runner = trusted_runner(account, subject)

      try do
        fun.(account, subject, runner)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end

  defp concurrently(functions) do
    parent = self()

    tasks = Enum.map(functions, &concurrent_task(&1, parent))
    Enum.each(tasks, &assert_task_ready/1)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 60_000))
  end

  defp concurrent_task(fun, parent) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})

      try do
        receive do
          :go -> fun.()
        end
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  defp assert_task_ready(task) do
    # Sandbox checkout is setup, not the behavior this test measures. Under the
    # full CI suite a worker can legitimately wait longer than ExUnit's 100 ms
    # default for a connection; keep the barrier bounded without timing the pool.
    assert_receive {:ready, pid} when pid == task.pid, 5_000
  end

  defp trusted_runner(account, subject, opts \\ []) do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: Keyword.get(opts, :group, "database")
      )

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.2", "hash" => @hash}},
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "low",
                   "summary" => "Reports uptime",
                   "description" => "Reports uptime",
                   "side_effects" => [],
                   "args" => [],
                   "examples" => [],
                   "search_terms" => [],
                   "output_schema" => %{
                     "type" => "object",
                     "required" => ["ready"],
                     "properties" => %{"ready" => %{"type" => "boolean"}},
                     "additionalProperties" => false
                   }
                 }
               ]
             })

    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    runner
  end

  defp published_runbook(subject, definition) do
    title = "runbook-#{System.unique_integer([:positive])}"

    assert {:ok, runbook} =
             Runbooks.create_runbook(
               %{"title" => title, "slug" => title, "draft_definition" => definition},
               subject
             )

    Fixtures.Runbooks.publish_runbook(runbook)
  end

  defp definition(stages) do
    %{
      "schema_version" => 1,
      "context_markdown" => "Operate carefully.",
      "inputs" => [],
      "stages" => stages
    }
  end

  defp stage(id, mode, max_parallel, steps) do
    Map.merge(
      %{
        "id" => id,
        "title" => String.capitalize(id),
        "mode" => mode,
        "steps" => steps
      },
      if(mode == "parallel", do: %{"max_parallel" => max_parallel}, else: %{})
    )
  end

  defp step(id, group) do
    %{
      "id" => id,
      "pack" => %{"id" => "linux-core"},
      "action" => "linux.uptime",
      "targets" => %{"selection" => "all", "refs" => ["group:" <> group]},
      "args" => %{},
      "outputs" => [],
      "success" => [],
      "wait" => nil
    }
  end

  defp waiting_step(group) do
    step("observe", group)
    |> Map.merge(%{
      "outputs" => [
        %{
          "id" => "ready",
          "source" => "structured_output",
          "sensitive" => false,
          "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
        }
      ],
      "success" => [%{"output" => "ready", "operator" => "equals", "value" => true}],
      "wait" => %{"interval_seconds" => 5, "timeout_seconds" => 20, "max_attempts" => 3}
    })
  end

  defp runs(account_id, execution_id),
    do: Runs.list_runs_for_runbook_execution(account_id, execution_id)

  defp execution(id),
    do: RunbookExecution.Query.by_id(id) |> Repo.fetch!(RunbookExecution.Query)
end
