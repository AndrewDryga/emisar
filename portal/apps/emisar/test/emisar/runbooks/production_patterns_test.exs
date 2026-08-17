defmodule Emisar.Runbooks.ProductionPatternsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Approvals, Audit, Catalog, Crypto, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Runbooks.{Definition, ExecutionItem, RunbookExecution}
  alias Emisar.Runbooks.Jobs.AdvanceExecutions

  @fixture_dir Path.expand("../../fixtures/runbooks", __DIR__)
  @pack_hash "sha256:" <> String.duplicate("d", 64)

  setup do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()

    policy_rules = %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => "require_approval",
        "critical" => "require_approval"
      },
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
    }

    _policy = Fixtures.Policies.create_policy(account_id: account.id, rules: policy_rules)

    %{account: account, approver: approver_subject(account), subject: subject}
  end

  test "a controlled Patroni failover preserves evidence through approval and a bounded wait", %{
    account: account,
    approver: approver,
    subject: subject
  } do
    definition = fixture!("patroni-controlled-failover")

    runners =
      install_pattern!(
        account,
        subject,
        [{"patroni-control", 1}, {"patroni-data", 2}],
        "postgres-operations",
        "2.4.7",
        patroni_actions()
      )

    assert {:ok, ^definition} = Definition.validate(definition)
    runbook = published_runbook(subject, definition)

    assert {:ok, result} =
             Runbooks.dispatch_runbook(
               runbook,
               "Move the leader during CHG-100",
               subject,
               input_values: %{"cluster" => "payments", "candidate" => "db-b"}
             )

    assert result.total == 7
    assert execution(result.execution_id).status == :pending_approval
    assert attempts(account.id, result.execution_id) == []
    approve_execution!(approver)
    assert length(attempts(account.id, result.execution_id)) == 3

    leader = attempt_by_action(account.id, result.execution_id, "patroni.current_leader")
    finish_text!(leader, "leader=db-a\n")

    account.id
    |> attempts(result.execution_id)
    |> Enum.filter(&(&1.action_id == "postgres.replication_status"))
    |> Enum.each(&finish_structured!(&1, %{"max_lag_bytes" => 32_768}))

    failover = attempt_by_action(account.id, result.execution_id, "patroni.failover")

    assert Jason.decode!(failover.args_raw) == %{
             "candidate" => "db-b",
             "cluster" => "payments",
             "expected_leader" => "db-a"
           }

    finish_structured!(failover, %{"accepted" => true, "operation_id" => "failover-42"})

    first_health = attempt_by_action(account.id, result.execution_id, "patroni.cluster_health")
    finish_structured!(first_health, %{"healthy" => false})

    waiting = item_for_attempt(first_health)
    assert waiting.status == :waiting
    assert waiting.outputs == %{"healthy" => false}

    make_due!(waiting)
    assert :ok = AdvanceExecutions.execute([])

    second_health =
      account.id
      |> attempts(result.execution_id)
      |> Enum.filter(&(&1.action_id == "patroni.cluster_health"))
      |> Enum.max_by(& &1.attempt_number)

    assert second_health.attempt_number == 2
    assert Jason.decode!(second_health.args_raw)["operation_id"] == "failover-42"
    finish_structured!(second_health, %{"healthy" => true})

    final_replication =
      account.id
      |> attempts(result.execution_id)
      |> Enum.filter(&(&1.runbook_step_id == "final_replication"))

    assert length(final_replication) == 2
    Enum.each(final_replication, &finish_structured!(&1, %{"max_lag_bytes" => 16_384}))

    assert_terminal_success!(
      result.execution_id,
      subject,
      "cluster_health",
      "postgres-operations@2.4.7/#{@pack_hash}",
      %{"healthy" => true}
    )

    assert Map.keys(runners) |> Enum.sort() == ["patroni-control", "patroni-data"]

    item_event =
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Repo.all()
      |> Enum.find(
        &(&1.event_type == "runbook.item_succeeded" and
            &1.payload["step_id"] == "cluster_health")
      )

    assert item_event.payload["pack_hash"] == @pack_hash
    assert Enum.any?(item_event.payload["success_evidence"], &(&1["kind"] == "condition"))
  end

  test "serialized fleet maintenance gates mutation, limits concurrency, and stops on failure", %{
    account: account,
    approver: approver,
    subject: subject
  } do
    definition = fixture!("serialized-fleet-maintenance")

    _runners =
      install_pattern!(
        account,
        subject,
        [{"workers", 3}],
        "fleet-maintenance",
        "1.7.4",
        fleet_actions()
      )

    assert {:ok, ^definition} = Definition.validate(definition)
    runbook = published_runbook(subject, definition)

    assert {:ok, successful} =
             Runbooks.dispatch_runbook(
               runbook,
               "Roll workers during CHG-200",
               subject,
               input_values: %{"change_ticket" => "CHG-200"}
             )

    assert execution(successful.execution_id).status == :pending_approval
    assert attempts(account.id, successful.execution_id) == []
    approve_execution!(approver)

    successful_inspection =
      account.id
      |> attempts(successful.execution_id)
      |> Enum.filter(&(&1.action_id == "fleet.health_report"))

    assert length(successful_inspection) == 3
    Enum.each(successful_inspection, &finish_text!(&1, "READY worker\n"))

    Enum.reduce(1..3, MapSet.new(), fn expected_count, seen ->
      current =
        account.id
        |> attempts(successful.execution_id)
        |> Enum.filter(
          &(&1.action_id == "fleet.maintain_host" and not MapSet.member?(seen, &1.id))
        )

      assert [run] = current
      assert count_active_attempts(account.id, successful.execution_id) == 1
      assert Jason.decode!(run.args_raw) == %{"change_ticket" => "CHG-200"}
      finish_structured!(run, %{"ready" => true})

      all_maintenance =
        account.id
        |> attempts(successful.execution_id)
        |> Enum.count(&(&1.action_id == "fleet.maintain_host"))

      assert all_maintenance >= expected_count
      MapSet.put(seen, run.id)
    end)

    verification =
      account.id
      |> attempts(successful.execution_id)
      |> Enum.filter(&(&1.action_id == "fleet.readiness"))

    assert length(verification) == 3
    assert count_active_attempts(account.id, successful.execution_id) == 3
    Enum.each(verification, &finish_structured!(&1, %{"ready" => true}))

    assert_terminal_success!(
      successful.execution_id,
      subject,
      "fleet_ready",
      "fleet-maintenance@1.7.4/#{@pack_hash}",
      %{"ready" => true}
    )

    assert {:ok, failed} =
             Runbooks.dispatch_runbook(
               runbook,
               "Prove fail-stop during CHG-201",
               subject,
               input_values: %{"change_ticket" => "CHG-201"}
             )

    assert execution(failed.execution_id).status == :pending_approval
    assert attempts(account.id, failed.execution_id) == []
    approve_execution!(approver)

    account.id
    |> attempts(failed.execution_id)
    |> Enum.each(&finish_text!(&1, "READY worker\n"))

    first_host = attempt_by_action(account.id, failed.execution_id, "fleet.maintain_host")
    finish_structured!(first_host, %{"ready" => false})

    halted = execution(failed.execution_id)
    assert halted.status == :halted
    assert halted.terminal_code == "condition_unmet"

    failed_attempts = attempts(account.id, failed.execution_id)
    assert Enum.count(failed_attempts, &(&1.action_id == "fleet.maintain_host")) == 1
    refute Enum.any?(failed_attempts, &(&1.action_id == "fleet.readiness"))
  end

  test "incident remediation binds diagnosed output and reaches a readable verified result", %{
    account: account,
    approver: approver,
    subject: subject
  } do
    definition = fixture!("incident-restart-and-verify")

    _runners =
      install_pattern!(
        account,
        subject,
        [{"aws-control", 1}],
        "aws-incident",
        "3.2.1",
        incident_actions()
      )

    assert {:ok, ^definition} = Definition.validate(definition)
    runbook = published_runbook(subject, definition)

    assert {:ok, result} =
             Runbooks.dispatch_runbook(
               runbook,
               "Restore service for INC-300",
               subject,
               input_values: %{"incident_id" => "INC-300"}
             )

    assert execution(result.execution_id).status == :pending_approval
    assert attempts(account.id, result.execution_id) == []
    approve_execution!(approver)

    diagnose = attempt_by_action(account.id, result.execution_id, "aws.incident_resource")

    finish_structured!(diagnose, %{
      "resource_id" => "i-012345",
      "state" => "impaired"
    })

    restart = attempt_by_action(account.id, result.execution_id, "aws.restart_resource")

    assert Jason.decode!(restart.args_raw) == %{
             "incident_id" => "INC-300",
             "resource_id" => "i-012345"
           }

    finish_structured!(restart, %{"request_id" => "req-abc123"})

    first_health = attempt_by_action(account.id, result.execution_id, "aws.resource_health")

    assert Jason.decode!(first_health.args_raw) == %{
             "request_id" => "req-abc123",
             "resource_id" => "i-012345"
           }

    finish_structured!(first_health, %{"healthy" => false, "status" => "starting"})
    make_due!(item_for_attempt(first_health))
    assert :ok = AdvanceExecutions.execute([])

    second_health =
      account.id
      |> attempts(result.execution_id)
      |> Enum.filter(&(&1.action_id == "aws.resource_health"))
      |> Enum.max_by(& &1.attempt_number)

    finish_structured!(second_health, %{"healthy" => true, "status" => "running"})

    assert_terminal_success!(
      result.execution_id,
      subject,
      "resource_health",
      "aws-incident@3.2.1/#{@pack_hash}",
      %{"healthy" => true, "status" => "running"}
    )
  end

  defp fixture!(name) do
    @fixture_dir
    |> Path.join("#{name}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp install_pattern!(account, subject, groups, pack_id, version, actions) do
    runners =
      Enum.reduce(groups, %{}, fn {group, count}, acc ->
        group_runners =
          Enum.map(1..count, fn _index ->
            runner = Fixtures.Runners.create_runner(account_id: account.id, group: group)

            assert {:ok, observed} =
                     Catalog.observe_state(runner, %{
                       "hostname" => runner.hostname,
                       "version" => runner.runner_version,
                       "labels" => runner.labels,
                       "enforce_signatures" => false,
                       "packs" => %{
                         pack_id => %{"version" => version, "hash" => @pack_hash}
                       },
                       "actions" => actions
                     })

            observed
          end)

        Map.put(acc, group, group_runners)
      end)

    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

    versions
    |> Enum.filter(&(&1.pack_id == pack_id and &1.version == version))
    |> Enum.each(fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    runners
    |> Map.values()
    |> List.flatten()
    |> Enum.each(&Runners.subscribe_runner_transport/1)

    runners
  end

  defp patroni_actions do
    [
      action("patroni.current_leader", "low", [arg("cluster")], nil),
      action(
        "postgres.replication_status",
        "low",
        [arg("cluster")],
        object_schema(%{"max_lag_bytes" => %{"type" => "integer"}})
      ),
      action(
        "patroni.failover",
        "high",
        [arg("cluster"), arg("candidate"), arg("expected_leader")],
        object_schema(%{
          "accepted" => %{"type" => "boolean"},
          "operation_id" => %{"type" => "string"}
        })
      ),
      action(
        "patroni.cluster_health",
        "low",
        [arg("cluster"), arg("operation_id")],
        object_schema(%{"healthy" => %{"type" => "boolean"}})
      )
    ]
  end

  defp fleet_actions do
    [
      action("fleet.health_report", "low", [], nil),
      action(
        "fleet.maintain_host",
        "high",
        [arg("change_ticket")],
        object_schema(%{"ready" => %{"type" => "boolean"}})
      ),
      action(
        "fleet.readiness",
        "low",
        [],
        object_schema(%{"ready" => %{"type" => "boolean"}})
      )
    ]
  end

  defp incident_actions do
    [
      action(
        "aws.incident_resource",
        "low",
        [arg("incident_id")],
        object_schema(%{
          "resource_id" => %{"type" => "string"},
          "state" => %{"type" => "string"}
        })
      ),
      action(
        "aws.restart_resource",
        "high",
        [arg("incident_id"), arg("resource_id")],
        object_schema(%{"request_id" => %{"type" => "string"}})
      ),
      action(
        "aws.resource_health",
        "low",
        [arg("resource_id"), arg("request_id")],
        object_schema(%{
          "healthy" => %{"type" => "boolean"},
          "status" => %{"type" => "string"}
        })
      )
    ]
  end

  defp action(id, risk, args, output_schema) do
    %{
      "id" => id,
      "pack_id" => id |> String.split(".") |> hd() |> action_pack_id(),
      "title" => id,
      "kind" => "exec",
      "risk" => risk,
      "summary" => "Fixture action for #{id}",
      "description" => "Fixture action for #{id}",
      "side_effects" => [],
      "args" => args,
      "examples" => [],
      "search_terms" => [],
      "output_schema" => output_schema
    }
  end

  defp action_pack_id("patroni"), do: "postgres-operations"
  defp action_pack_id("postgres"), do: "postgres-operations"
  defp action_pack_id("fleet"), do: "fleet-maintenance"
  defp action_pack_id("aws"), do: "aws-incident"

  defp arg(name) do
    %{"name" => name, "type" => "string", "required" => true, "sensitive" => false}
  end

  defp object_schema(properties) do
    %{
      "type" => "object",
      "required" => Map.keys(properties),
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  defp published_runbook(subject, definition) do
    title = "pattern-#{System.unique_integer([:positive])}"

    assert {:ok, runbook} =
             Runbooks.create_runbook(
               %{"title" => title, "slug" => title, "draft_definition" => definition},
               subject
             )

    Fixtures.Runbooks.publish_runbook(runbook)
  end

  defp approver_subject(account) do
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "admin"
      )

    Fixtures.Subjects.membership_subject(membership)
  end

  defp approve_execution!(approver) do
    assert {:ok, [request], _metadata} =
             Approvals.list_pending_approval_requests(approver)

    assert {:ok, {_approved, :runbook_execution}} =
             Approvals.approve_request(request, approver, "change window confirmed")
  end

  defp finish_text!(run, text) do
    assert {:ok, _event} =
             Runs.append_event(run, %{
               seq: 1,
               kind: "progress",
               stream: "stdout",
               payload: %{"chunk" => text}
             })

    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "success",
               "progress_chunks" => 1,
               "emitted_stdout_bytes" => byte_size(text),
               "emitted_stderr_bytes" => 0
             })
  end

  defp finish_structured!(run, output) do
    assert {:ok, _finished} =
             Fixtures.Runs.finish(run, %{
               "status" => "success",
               "structured_output" => output
             })
  end

  defp make_due!(item) do
    item
    |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()
  end

  defp assert_terminal_success!(execution_id, subject, step_id, pack_ref, expected_outputs) do
    assert {:ok, result} = Runbooks.fetch_execution_result(execution_id, subject)
    assert result.execution.status == :succeeded
    assert Enum.all?(result.execution.stages, &(&1.status == :succeeded))

    item = Enum.find(result.execution.items, &(&1.step_id == step_id))
    assert item.status == :succeeded
    assert item.pack_ref == pack_ref
    assert item.pack_hash == @pack_hash
    assert is_nil(item.outputs_raw)
    assert item.outputs_sha256 == Crypto.hash_hex(Jason.encode!(expected_outputs))
    assert Enum.any?(item.success_evidence, &(&1["kind"] == "condition"))
  end

  defp attempts(account_id, execution_id),
    do: Runs.list_runs_for_runbook_execution(account_id, execution_id)

  defp attempt_by_action(account_id, execution_id, action_id) do
    account_id
    |> attempts(execution_id)
    |> Enum.find(&(&1.action_id == action_id))
    |> case do
      nil -> flunk("expected action attempt #{action_id}")
      run -> run
    end
  end

  defp count_active_attempts(account_id, execution_id) do
    account_id
    |> attempts(execution_id)
    |> Enum.count(&(not Runs.ActionRun.terminal?(&1.status)))
  end

  defp item_for_attempt(attempt) do
    ExecutionItem.Query.by_id(attempt.runbook_execution_item_id)
    |> Repo.fetch!(ExecutionItem.Query)
  end

  defp execution(id),
    do: RunbookExecution.Query.by_id(id) |> Repo.fetch!(RunbookExecution.Query)
end
