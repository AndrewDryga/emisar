defmodule Emisar.Runbooks.SchedulerTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{ApiKeys, Audit, Auth.Subject, Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Runbooks.{Definition, ExecutionItem, RunbookExecution, Scheduler}
  alias Emisar.Runbooks.Jobs.AdvanceExecutions

  @hash "sha256:" <> String.duplicate("b", 64)

  setup do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    _policy = Fixtures.Policies.create_policy(account_id: account.id)
    runner = trusted_runner(account, subject)
    Runners.subscribe_runner_transport(runner)

    %{account: account, subject: subject, runner: runner}
  end

  test "sequential stages barrier each step fan-out", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("change", "sequential", 4, [
            step("inspect", runner.group),
            step("apply", runner.group)
          ])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "scheduled maintenance", subject)
    assert result.total == 2
    assert [first] = runs(account.id, result.execution_id)
    assert first.runbook_step_id == "inspect"

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    assert [_, second] = runs(account.id, result.execution_id)
    assert second.runbook_step_id == "apply"

    assert {:ok, _second} =
             Fixtures.Runs.finish(second, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    assert Repo.reload!(execution(result.execution_id)).status == :succeeded
  end

  test "parallel stages enforce a sliding max_parallel cap", %{
    account: account,
    subject: subject,
    runner: first_runner
  } do
    second_runner = trusted_runner(account, subject, group: first_runner.group)
    Runners.subscribe_runner_transport(second_runner)

    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "parallel", 2, [
            step("uptime", first_runner.group),
            step("again", first_runner.group)
          ])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "inspect fleet", subject)
    assert length(runs(account.id, result.execution_id)) == 2

    [first | _] = runs(account.id, result.execution_id)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    current = runs(account.id, result.execution_id)
    assert length(current) == 3
    assert Enum.count(current, &(not Runs.ActionRun.terminal?(&1.status))) == 2
  end

  test "a failed item halts every later stage", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "verify barrier", subject)
    assert [first] = runs(account.id, result.execution_id)

    assert {:ok, _failed} =
             Fixtures.Runs.finish(first, %{
               "status" => "failed",
               "structured_output" => %{"ready" => false}
             })

    assert [_only_run] = runs(account.id, result.execution_id)
    halted = Repo.reload!(execution(result.execution_id))
    assert halted.status == :halted
    assert halted.terminal_code == "action_failed"
  end

  test "already-running peers settle after a halt and duplicate callbacks stay harmless", %{
    account: account,
    subject: subject,
    runner: first_runner
  } do
    second_runner = trusted_runner(account, subject, group: first_runner.group)
    Runners.subscribe_runner_transport(second_runner)

    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "parallel", 2, [step("check", first_runner.group)]),
          stage("change", "parallel", 2, [step("apply", first_runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "preserve peer outcomes", subject)
    assert [first, peer] = runs(account.id, result.execution_id)

    assert {:ok, failed} =
             Fixtures.Runs.finish(first, %{
               "status" => "failed",
               "structured_output" => %{"ready" => false}
             })

    assert execution(result.execution_id).status == :halted

    assert ExecutionItem.Query.active_workload_for_account(account.id)
           |> ExecutionItem.Query.select_count()
           |> Repo.one() == 1

    assert {:ok, succeeded_peer} =
             Fixtures.Runs.finish(peer, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    peer_item = ExecutionItem.Query.by_id(peer.runbook_execution_item_id) |> Repo.one!()
    assert peer_item.status == :succeeded
    assert length(runs(account.id, result.execution_id)) == 2
    assert execution(result.execution_id).status == :halted

    assert ExecutionItem.Query.active_workload_for_account(account.id)
           |> ExecutionItem.Query.select_count()
           |> Repo.one() == 0

    assert Runbooks.action_run_settled(failed) == :noop
    assert Runbooks.action_run_settled(succeeded_peer) == :noop
    assert length(runs(account.id, result.execution_id)) == 2

    pending =
      ExecutionItem.Query.by_execution_id(result.execution_id)
      |> Repo.all()
      |> Enum.filter(&(&1.stage_position == 1))

    assert Enum.all?(pending, &(&1.status == :pending))
  end

  test "deleting an execution item cascades its physical attempts", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([stage("inspect", "sequential", 1, [step("check", runner.group)])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "foreign key behavior", subject)
    assert [attempt] = runs(account.id, result.execution_id)
    execution_item = item(result.execution_id)

    assert Repo.delete!(execution_item).id == execution_item.id
    refute Repo.get(Runs.ActionRun, attempt.id)
  end

  test "waits persist an unmet observation and succeed on a later attempt", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    output = %{
      "id" => "ready",
      "source" => "structured_output",
      "sensitive" => false,
      "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
    }

    condition = %{"output" => "ready", "operator" => "equals", "value" => true}

    wait = %{"interval_seconds" => 5, "timeout_seconds" => 20, "max_attempts" => 3}

    observed_step =
      step("observe", runner.group)
      |> Map.merge(%{"outputs" => [output], "success" => [condition], "wait" => wait})

    runbook =
      published_runbook(
        subject,
        definition([stage("wait", "sequential", 1, [observed_step])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "wait for readiness", subject)
    assert [first] = runs(account.id, result.execution_id)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => false}
             })

    item = item(result.execution_id)
    assert item.status == :waiting
    assert item.outputs == %{"ready" => false}

    item
    |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert AdvanceExecutions.execute([]) == :ok
    assert [_, second] = runs(account.id, result.execution_id)
    assert second.attempt_number == 2

    assert {:ok, _second} =
             Fixtures.Runs.finish(second, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    assert Repo.reload!(item).status == :succeeded
    assert Repo.reload!(execution(result.execution_id)).status == :succeeded
  end

  test "waits stop at the attempt ceiling and never retry an action failure", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    observed_step = waiting_step("observe", runner.group, max_attempts: 2)

    first_runbook =
      published_runbook(
        subject,
        definition([stage("wait", "sequential", 1, [observed_step])])
      )

    assert {:ok, first_result} =
             Runbooks.dispatch_runbook(first_runbook, "bounded observations", subject)

    assert [first] = runs(account.id, first_result.execution_id)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => false}
             })

    first_result.execution_id
    |> item()
    |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert AdvanceExecutions.execute([]) == :ok
    assert [_, second] = runs(account.id, first_result.execution_id)

    assert {:ok, _second} =
             Fixtures.Runs.finish(second, %{
               "status" => "success",
               "structured_output" => %{"ready" => false}
             })

    timed_out = item(first_result.execution_id)
    assert timed_out.status == :failed
    assert timed_out.terminal_code == "wait_timed_out"
    assert length(runs(account.id, first_result.execution_id)) == 2

    failed_runbook =
      published_runbook(
        subject,
        definition([stage("wait", "sequential", 1, [observed_step])])
      )

    assert {:ok, failed_result} =
             Runbooks.dispatch_runbook(failed_runbook, "do not retry failures", subject)

    assert [failed_attempt] = runs(account.id, failed_result.execution_id)

    assert {:ok, _failed_attempt} =
             Fixtures.Runs.finish(failed_attempt, %{
               "status" => "failed",
               "structured_output" => %{"ready" => false}
             })

    failed_item = item(failed_result.execution_id)
    assert failed_item.status == :failed
    assert failed_item.terminal_code == "action_failed"
    assert length(runs(account.id, failed_result.execution_id)) == 1
  end

  test "an extraction error halts immediately even when a wait is configured", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    observed_step = waiting_step("observe", runner.group, pointer: "/missing")

    runbook =
      published_runbook(
        subject,
        definition([stage("wait", "sequential", 1, [observed_step])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "fail closed", subject)
    assert [attempt] = runs(account.id, result.execution_id)

    assert {:ok, _attempt} =
             Fixtures.Runs.finish(attempt, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    failed = item(result.execution_id)
    assert failed.status == :failed
    assert failed.terminal_code == "extraction_failed"
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "membership suspension halts before the next stage", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "membership recheck", subject)
    assert [first] = runs(account.id, result.execution_id)

    membership = Fixtures.Memberships.fetch_membership(account.id, subject.actor.id)
    _suspended = Fixtures.Memberships.suspend_membership(membership)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "role demotion halts before the next stage", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "role recheck", subject)
    assert [first] = runs(account.id, result.execution_id)

    subject.account.id
    |> Fixtures.Memberships.fetch_membership(subject.actor.id)
    |> Fixtures.Memberships.force_role("viewer")

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "API key revocation halts before the next stage", %{
    account: account,
    subject: owner,
    runner: runner
  } do
    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        created_by_id: owner.actor.id
      )

    subject = Subject.for_api_key(key, account)

    runbook =
      published_runbook(
        owner,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "credential recheck", subject)
    assert [first] = runs(account.id, result.execution_id)
    assert {:ok, _key} = ApiKeys.revoke_api_key(key, owner)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "runner-scope loss is reported as authorization loss before later dispatch", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "scope recheck", subject)
    assert [first] = runs(account.id, result.execution_id)

    membership = Fixtures.Memberships.fetch_membership(account.id, subject.actor.id)
    _membership = Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "authorization_lost"
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "pack trust movement after freeze halts without a row-less later attempt", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "sequential", 1, [step("check", runner.group)]),
          stage("change", "sequential", 1, [step("apply", runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "trust recheck", subject)
    assert [first] = runs(account.id, result.execution_id)
    assert [version] = Fixtures.Catalog.list_pack_versions(subject.account.id)
    assert {:ok, _revoked} = Catalog.revoke_pack_version_trust(version.id, subject)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "dispatch_failed"
    assert halted.terminal_message == "The frozen pack is no longer trusted."
    assert length(runs(account.id, result.execution_id)) == 1
  end

  test "the recovery sweep enforces the execution deadline without reopening it", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([stage("inspect", "sequential", 1, [step("check", runner.group)])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "deadline", subject)
    assert [attempt] = runs(account.id, result.execution_id)

    result.execution_id
    |> execution()
    |> Ecto.Changeset.change(
      inserted_at:
        DateTime.add(
          DateTime.utc_now(),
          -Definition.limit!(:max_execution_seconds) - 5,
          :second
        )
    )
    |> Repo.update!()

    assert AdvanceExecutions.execute([]) == :ok
    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "execution_timed_out"

    assert {:ok, settled} =
             Fixtures.Runs.finish(attempt, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    assert ExecutionItem.Query.by_id(settled.runbook_execution_item_id)
           |> Repo.one!()
           |> Map.fetch!(:status) == :succeeded

    assert execution(result.execution_id).status == :halted
  end

  test "the bounded recovery sweep rotates work instead of starving later executions", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([
          stage("wait", "sequential", 1, [waiting_step("observe", runner.group, [])])
        ])
      )

    execution_ids =
      for position <- 1..51 do
        assert {:ok, result} =
                 Runbooks.dispatch_runbook(runbook, "fair recovery #{position}", subject)

        assert [attempt] = runs(account.id, result.execution_id)

        assert {:ok, _attempt} =
                 Fixtures.Runs.finish(attempt, %{
                   "status" => "success",
                   "structured_output" => %{"ready" => false}
                 })

        result.execution_id
      end

    Enum.each(execution_ids, fn execution_id ->
      execution_id
      |> item()
      |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()
    end)

    target_id = List.last(execution_ids)

    assert AdvanceExecutions.execute([]) == :ok
    assert length(runs(account.id, target_id)) == 1

    assert AdvanceExecutions.execute([]) == :ok
    assert [_, target_retry] = runs(account.id, target_id)
    assert target_retry.attempt_number == 2
  end

  test "the recovery sweep reconciles a terminal callback lost after commit", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([stage("inspect", "sequential", 1, [step("check", runner.group)])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "recover committed result", subject)
    assert [attempt] = runs(account.id, result.execution_id)

    _finished =
      Fixtures.Runs.finish_without_runbook_callback(attempt, :success, %{"ready" => true})

    assert item(result.execution_id).status == :running
    assert execution(result.execution_id).status == :active
    assert Scheduler.recover_due() >= 1

    settled = item(result.execution_id)
    assert settled.status == :succeeded
    assert is_nil(settled.args_raw)
    assert is_nil(settled.outputs_raw)
    assert byte_size(settled.args_sha256) == 64
    assert byte_size(settled.outputs_sha256) == 64

    succeeded = execution(result.execution_id)
    assert succeeded.status == :succeeded
    assert is_nil(succeeded.inputs_raw)
    assert byte_size(succeeded.inputs_sha256) == 64
  end

  test "the recovery sweep settles a lost peer callback without reopening a halted execution", %{
    account: account,
    subject: subject,
    runner: first_runner
  } do
    second_runner = trusted_runner(account, subject, group: first_runner.group)
    Runners.subscribe_runner_transport(second_runner)

    runbook =
      published_runbook(
        subject,
        definition([
          stage("inspect", "parallel", 2, [step("check", first_runner.group)])
        ])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "recover halted peer", subject)
    assert [failed_attempt, peer_attempt] = runs(account.id, result.execution_id)

    assert {:ok, _failed} =
             Fixtures.Runs.finish(failed_attempt, %{
               "status" => "failed",
               "structured_output" => %{"ready" => false}
             })

    assert execution(result.execution_id).status == :halted

    _finished =
      Fixtures.Runs.finish_without_runbook_callback(peer_attempt, :success, %{"ready" => true})

    assert ExecutionItem.Query.by_id(peer_attempt.runbook_execution_item_id)
           |> Repo.one!()
           |> Map.fetch!(:status) == :running

    assert Scheduler.recover_due() >= 1

    assert ExecutionItem.Query.by_id(peer_attempt.runbook_execution_item_id)
           |> Repo.one!()
           |> Map.fetch!(:status) == :succeeded

    halted = execution(result.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "action_failed"
    assert is_nil(halted.inputs_raw)
  end

  test "the recovery sweep emits fixed-cardinality queue and saturation measurements" do
    handler_id = "runbook-recovery-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    assert :telemetry.attach(
             handler_id,
             [:emisar, :runbooks, :recovery],
             fn event, measurements, metadata, pid ->
               send(pid, {:telemetry, event, measurements, metadata})
             end,
             test_pid
           ) == :ok

    on_exit(fn -> :telemetry.detach(handler_id) end)
    _recovered = Scheduler.recover_due()

    assert_receive {:telemetry, [:emisar, :runbooks, :recovery], measurements, %{}}

    assert Map.keys(measurements) |> Enum.sort() ==
             [
               :active,
               :callback_batch,
               :execution_batch,
               :overdue,
               :recovery_lag_seconds,
               :saturated_batches,
               :scrub_batch,
               :waiting
             ]

    assert Enum.all?(measurements, fn {_key, value} -> is_integer(value) and value >= 0 end)
  end

  test "exact execution broadcasts and lifecycle audits remain idempotent", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([stage("inspect", "sequential", 1, [step("check", runner.group)])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "observable lifecycle", subject)
    :ok = Runbooks.subscribe_execution(account.id, result.execution_id)
    other_execution_id = Repo.generate_id()
    :ok = Runbooks.subscribe_execution(account.id, other_execution_id)
    assert [attempt] = runs(account.id, result.execution_id)

    assert {:ok, settled} =
             Fixtures.Runs.finish(attempt, %{
               "status" => "success",
               "structured_output" => %{"ready" => true}
             })

    assert_receive {:runbook_execution_updated, execution_id}
    assert execution_id == result.execution_id
    refute_receive {:runbook_execution_updated, ^other_execution_id}

    lifecycle_types = [
      "action_run.success",
      "runbook.dispatched",
      "runbook.stage_started",
      "runbook.item_succeeded",
      "runbook.stage_succeeded",
      "runbook.execution_succeeded"
    ]

    events =
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Repo.all()
      |> Enum.filter(&(&1.payload["runbook_execution_id"] == result.execution_id))

    assert Enum.frequencies(Enum.map(events, & &1.event_type)) ==
             Map.new(lifecycle_types, &{&1, 1})

    assert Runbooks.action_run_settled(settled) == :noop

    events_after_duplicate =
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Repo.all()
      |> Enum.filter(&(&1.payload["runbook_execution_id"] == result.execution_id))

    assert Enum.frequencies(Enum.map(events_after_duplicate, & &1.event_type)) ==
             Map.new(lifecycle_types, &{&1, 1})
  end

  test "cancelling a waiting execution prevents every later attempt", %{
    account: account,
    subject: subject,
    runner: runner
  } do
    output = %{
      "id" => "ready",
      "source" => "structured_output",
      "sensitive" => false,
      "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
    }

    condition = %{"output" => "ready", "operator" => "equals", "value" => true}
    wait = %{"interval_seconds" => 5, "timeout_seconds" => 20, "max_attempts" => 3}

    observed_step =
      step("observe", runner.group)
      |> Map.merge(%{"outputs" => [output], "success" => [condition], "wait" => wait})

    runbook =
      published_runbook(
        subject,
        definition([stage("wait", "sequential", 1, [observed_step])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel waiting", subject)
    assert [first] = runs(account.id, result.execution_id)

    assert {:ok, _first} =
             Fixtures.Runs.finish(first, %{
               "status" => "success",
               "structured_output" => %{"ready" => false}
             })

    assert item(result.execution_id).status == :waiting
    assert {:ok, cancelled} = Runbooks.cancel_execution(result.execution_id, subject)
    assert cancelled.status == :cancelled
    assert Repo.reload!(item(result.execution_id)).status == :cancelled

    assert AdvanceExecutions.execute([]) == :ok
    assert [_only_attempt] = runs(account.id, result.execution_id)
  end

  describe "after_active_runbook_attempts_cancelled/2" do
    test "cancelling an active execution requests cancellation of running attempts", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook(
          subject,
          definition([stage("change", "sequential", 1, [step("apply", runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel active", subject)
      assert [run] = runs(account.id, result.execution_id)

      assert {:ok, cancelled} = Runbooks.cancel_execution(result.execution_id, subject)
      assert cancelled.status == :cancelled
      assert Repo.reload!(item(result.execution_id)).status == :cancelled
      assert Repo.reload!(run).status == :cancelling
      assert is_nil(Repo.reload!(run).finished_at)
      assert is_nil(Repo.reload!(run).cancelled_at)
      request_id = run.request_id
      generation = runner.connection_generation

      assert_receive {:cloud_to_runner, ^generation,
                      %{"type" => "cancel", "request_id" => ^request_id}}
    end
  end

  describe "cancel_active_runbook_attempts_in_multi/5" do
    test "committed child intent survives missing notifications and a repeated parent cancel", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook(
          subject,
          definition([stage("change", "sequential", 1, [step("apply", runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel active", subject)
      assert [run] = runs(account.id, result.execution_id)
      request_id = run.request_id
      generation = runner.connection_generation
      assert_receive {:cloud_to_runner, ^generation, %{"type" => "run_action"}}

      assert {:ok, _changes} =
               Multi.new()
               |> Fixtures.Runbooks.cancel_execution_in_multi(execution(result.execution_id))
               |> Runs.cancel_active_runbook_attempts_in_multi(
                 account.id,
                 result.execution_id,
                 "runbook execution cancelled",
                 subject
               )
               |> Repo.commit_multi()

      cancelling = Repo.reload!(run)
      assert cancelling.status == :cancelling
      assert is_nil(cancelling.finished_at)
      assert is_nil(cancelling.cancelled_at)
      refute_received {:cloud_to_runner, _generation, %{"type" => "cancel"}}

      assert {:ok, %{status: :cancelled}} =
               Runbooks.cancel_execution(result.execution_id, subject)

      for _tick <- 1..2 do
        Scheduler.recover_due()

        assert_receive {:cloud_to_runner, ^generation,
                        %{"type" => "cancel", "request_id" => ^request_id}}

        refute_received {:cloud_to_runner, _generation, %{"type" => "run_action"}}
        assert Repo.reload!(run).status == :cancelling
      end

      cancel_events =
        Audit.Event.Query.all()
        |> Audit.Event.Query.by_event_type("run.cancel_requested")
        |> Repo.all()

      assert [event] = cancel_events
      assert event.payload["run_id"] == run.id
      payload = %{"status" => "success", "structured_output" => %{"ready" => true}}
      assert {:ok, %{status: :success}} = Fixtures.Runs.finish(run, payload)
      assert execution(result.execution_id).status == :cancelled
    end

    test "a failed cancellation transaction rolls back parent, child, and audit together", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      runbook =
        published_runbook(
          subject,
          definition([stage("change", "sequential", 1, [step("apply", runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel active", subject)
      assert [run] = runs(account.id, result.execution_id)

      multi =
        Multi.new()
        |> Fixtures.Runbooks.cancel_execution_in_multi(execution(result.execution_id))
        |> Runs.cancel_active_runbook_attempts_in_multi(
          account.id,
          result.execution_id,
          "runbook execution cancelled",
          subject
        )
        |> Multi.error(:rollback, :checkpoint_failed)

      assert Repo.commit_multi(multi) == {:error, :checkpoint_failed}
      assert execution(result.execution_id).status == :active
      assert item(result.execution_id).status == :running
      assert Repo.one(Runbooks.ExecutionStage).status == :active
      assert Repo.reload!(run).status == :sent

      refute Audit.Event.Query.all()
             |> Audit.Event.Query.by_event_type("run.cancel_requested")
             |> Repo.exists?()
    end
  end

  describe "retry_runbook_cancellations/1" do
    test "cancellation recovery pages past unavailable runners without changing terminal children",
         %{
           account: account,
           subject: subject,
           runner: runner
         } do
      second_runner = trusted_runner(account, subject, group: runner.group)
      Runners.subscribe_runner_transport(second_runner)

      runbook =
        published_runbook(
          subject,
          definition([stage("change", "parallel", 2, [step("apply", runner.group)])])
        )

      assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "cancel fleet", subject)
      assert [first, second] = Enum.sort_by(runs(account.id, result.execution_id), & &1.id)
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}
      assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}
      first_runner = Enum.find([runner, second_runner], &(&1.id == first.runner_id))
      Fixtures.Runners.expire_connection_lease(first_runner)

      assert Runners.current_connection_generation(account.id, first_runner.id) ==
               {:error, :not_connected}

      Fixtures.Runs.put_status(second, :running)

      assert {:ok, _changes} =
               Multi.new()
               |> Fixtures.Runbooks.cancel_execution_in_multi(execution(result.execution_id))
               |> Runs.cancel_active_runbook_attempts_in_multi(
                 account.id,
                 result.execution_id,
                 "runbook execution cancelled",
                 subject
               )
               |> Repo.commit_multi()

      assert Runs.retry_runbook_cancellations(1) == :ok
      request_id = second.request_id

      assert_receive {:cloud_to_runner, _generation,
                      %{"type" => "cancel", "request_id" => ^request_id}}

      first_request_id = first.request_id

      refute_received {:cloud_to_runner, _generation,
                       %{"type" => "cancel", "request_id" => ^first_request_id}}

      assert Repo.reload!(first).status == :cancelling
      assert Repo.reload!(second).status == :cancelling
      payload = %{"status" => "success", "structured_output" => %{"ready" => true}}
      assert {:ok, %{status: :success}} = Fixtures.Runs.finish(second, payload)

      :ok = Runners.Presence.untrack(self(), Runners.Presence.topic(account.id), first.runner_id)
      successor = Fixtures.Runners.connect_runner(first_runner)
      generation = successor.connection_generation
      assert generation > first_runner.connection_generation
      assert Runs.resume_runs_for_runner(first.runner_id) == :ok

      assert_receive {:cloud_to_runner, ^generation,
                      %{"type" => "run_action", "request_id" => ^first_request_id}}

      assert_receive {:cloud_to_runner, ^generation,
                      %{"type" => "cancel", "request_id" => ^first_request_id}}

      assert Runs.retry_runbook_cancellations(1) == :ok

      refute_received {:cloud_to_runner, _generation,
                       %{"type" => "cancel", "request_id" => ^request_id}}
    end
  end

  test "cancellation enforces role and account isolation", %{
    subject: subject,
    runner: runner
  } do
    runbook =
      published_runbook(
        subject,
        definition([stage("change", "sequential", 1, [step("apply", runner.group)])])
      )

    assert {:ok, result} = Runbooks.dispatch_runbook(runbook, "protected cancel", subject)

    viewer = Fixtures.Users.create_user()

    viewer_membership =
      Fixtures.Memberships.create_membership(
        account_id: subject.account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    viewer_subject = Fixtures.Subjects.membership_subject(viewer_membership)

    assert Runbooks.cancel_execution(result.execution_id, viewer_subject) ==
             {:error, :unauthorized}

    {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
    assert Runbooks.cancel_execution(result.execution_id, other_subject) == {:error, :not_found}
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

    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

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
               %{
                 "title" => title,
                 "slug" => title,
                 "draft_definition" => definition
               },
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

  defp waiting_step(id, group, opts) do
    pointer = Keyword.get(opts, :pointer, "/ready")
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    step(id, group)
    |> Map.merge(%{
      "outputs" => [
        %{
          "id" => "ready",
          "source" => "structured_output",
          "sensitive" => false,
          "extract" => %{"type" => "json_pointer", "expression" => pointer}
        }
      ],
      "success" => [%{"output" => "ready", "operator" => "equals", "value" => true}],
      "wait" => %{
        "interval_seconds" => 5,
        "timeout_seconds" => 20,
        "max_attempts" => max_attempts
      }
    })
  end

  defp runs(account_id, execution_id),
    do: Runs.list_runs_for_runbook_execution(account_id, execution_id)

  defp execution(id),
    do: RunbookExecution.Query.by_id(id) |> Repo.fetch!(RunbookExecution.Query)

  defp item(execution_id) do
    ExecutionItem.Query.by_execution_id(execution_id)
    |> Repo.one!()
  end
end
