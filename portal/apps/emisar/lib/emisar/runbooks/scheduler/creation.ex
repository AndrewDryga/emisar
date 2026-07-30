defmodule Emisar.Runbooks.Scheduler.Creation do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Policies, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Runbook, RunbookExecution, Scheduler}

  @max_active_execution_items_per_account 1_024

  def create_execution(
        %Runbook{} = runbook,
        compiled,
        reason,
        %Subject{} = subject,
        opts \\ []
      ) do
    execution_id = Keyword.get(opts, :execution_id, Repo.generate_id())

    multi =
      compose_creation(
        Multi.new(),
        runbook,
        compiled,
        reason,
        subject,
        execution_id,
        opts
      )

    case Repo.commit_multi(multi,
           after_commit: &Approvals.after_runbook_execution_request_committed/1
         ) do
      {:ok, changes} ->
        execution = Map.fetch!(changes, {:runbook_execution, execution_id})
        if execution.status == :active, do: Scheduler.advance_execution(execution_id)
        Scheduler.fetch_result(execution_id, runbook.account_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def compose_creation(
        %Multi{} = multi,
        %Runbook{} = runbook,
        compiled,
        reason,
        %Subject{} = subject,
        execution_id,
        opts \\ []
      ) do
    stages = build_stage_rows(runbook, compiled, execution_id)
    stage_ids = Map.new(stages, &{&1.position, &1.id})
    items = build_item_rows(runbook, compiled, execution_id, stage_ids)

    approval =
      compiled.items
      |> approval_posture()
      |> with_runbook_metadata(runbook)

    execution_attrs = %{
      id: execution_id,
      account_id: runbook.account_id,
      runbook_id: runbook.id,
      initiating_membership_id: subject.membership_id,
      requested_by_id: Subject.user_id(subject),
      api_key_id: Subject.api_key_id(subject),
      operation_id: Keyword.get(opts, :operation_id),
      mcp_operation_record_id: Keyword.get(opts, :mcp_operation_record_id),
      reason: reason,
      frozen_plan: compiled.plan,
      inputs_raw: compiled.inputs_raw,
      inputs_sha256: compiled.inputs_sha256,
      sensitive_input_names: compiled.sensitive_input_names,
      status: if(approval, do: :pending_approval, else: :active)
    }

    multi
    |> Multi.run({:runbook_capacity, execution_id}, fn repo, _changes ->
      reserve_account_capacity(repo, runbook.account_id, length(items))
    end)
    |> Multi.run({:runbook_policy_snapshot, execution_id}, fn _repo, _changes ->
      validate_policy_snapshot(compiled.items, runbook.account_id)
    end)
    |> Multi.insert(
      {:runbook_execution, execution_id},
      RunbookExecution.Changeset.create(execution_attrs)
    )
    |> insert_stages(stages)
    |> insert_items(items)
    |> Approvals.create_runbook_execution_request_in_multi(
      {:runbook_execution, execution_id},
      approval
    )
    |> Multi.insert({:runbook_execution_audit, execution_id}, fn changes ->
      execution = Map.fetch!(changes, {:runbook_execution, execution_id})

      Audit.Events.runbook_dispatched(
        subject,
        runbook,
        execution,
        length(items),
        length(stages)
      )
    end)
  end

  defp reserve_account_capacity(repo, account_id, item_count) do
    with {:ok, _account} <- Accounts.fetch_and_lock_account(account_id, repo: repo) do
      active_items =
        ExecutionItem.Query.active_workload_for_account(account_id)
        |> ExecutionItem.Query.select_count()
        |> repo.one()

      if active_items + item_count <= @max_active_execution_items_per_account,
        do: {:ok, active_items + item_count},
        else: {:error, :runbook_capacity_exceeded}
    end
  end

  defp build_stage_rows(runbook, compiled, execution_id) do
    Enum.map(compiled.plan["stages"], fn stage ->
      %{
        id: Repo.generate_id(),
        account_id: runbook.account_id,
        runbook_execution_id: execution_id,
        stage_id: stage["id"],
        position: stage["position"],
        title: stage["title"],
        mode: stage["mode"],
        max_parallel: stage["max_parallel"],
        status: :pending
      }
    end)
  end

  defp build_item_rows(runbook, compiled, execution_id, stage_ids) do
    Enum.map(compiled.items, fn item ->
      %{
        id: Repo.generate_id(),
        account_id: runbook.account_id,
        runbook_execution_id: execution_id,
        runbook_execution_stage_id: Map.fetch!(stage_ids, item.stage_position),
        stage_position: item.stage_position,
        step_id: item.step_id,
        step_position: item.step_position,
        runner_id: item.runner_id,
        runner_ref: item.runner_ref,
        action_id: item.action_id,
        pack_ref: item.pack_ref,
        pack_hash: item.pack_hash,
        risk: item.risk,
        policy_id: item.policy_id,
        policy_version: item.policy_version,
        policy_decision: to_string(item.policy_decision),
        policy_reason: item.policy_reason,
        matched_rules: item.matched_rules,
        action_contract: item.action_contract,
        binding_plan: item.binding_plan,
        output_plan: item.outputs,
        success_plan: item.success,
        args_raw: item.args_raw,
        args_sha256: item.args_sha256,
        sensitive_arg_names: item.sensitive_arg_names,
        wait: item.wait
      }
    end)
  end

  defp insert_stages(multi, stages) do
    Enum.reduce(stages, multi, fn stage, multi ->
      Multi.insert(
        multi,
        {:runbook_stage, stage.id},
        ExecutionStage.Changeset.create(stage)
      )
    end)
  end

  defp insert_items(multi, items) do
    Enum.reduce(items, multi, fn item, multi ->
      Multi.insert(
        multi,
        {:runbook_item, item.id},
        ExecutionItem.Changeset.create(item)
      )
    end)
  end

  defp approval_posture(items) do
    approvals =
      items
      |> Enum.filter(&(&1.policy_decision == :require_approval))
      |> Enum.map(& &1.approval)

    case approvals do
      [] ->
        nil

      approvals ->
        %{
          min_approvals: approvals |> Enum.map(& &1.min_approvals) |> Enum.max(),
          allow_self_approval: Enum.all?(approvals, & &1.allow_self_approval)
        }
    end
  end

  defp with_runbook_metadata(nil, _runbook), do: nil

  defp with_runbook_metadata(approval, runbook) do
    Map.put(approval, :runbook, %{
      "id" => runbook.id,
      "title" => runbook.title,
      "version" => runbook.version
    })
  end

  defp validate_policy_snapshot(items, account_id) do
    current = Policies.snapshot_runbook_decisions(account_id, items)

    if Enum.zip(items, current) |> Enum.all?(&same_policy_snapshot?/1),
      do: {:ok, :current},
      else: {:error, :runbook_policy_changed}
  end

  defp same_policy_snapshot?({item, snapshot}) do
    policy = snapshot.policy

    not is_nil(policy) and
      item.policy_id == policy.id and
      item.policy_version == policy.vsn and
      item.policy_decision == snapshot.decision and
      item.policy_reason == snapshot.reason and
      item.matched_rules == snapshot.matched_rules and
      item.approval == snapshot.approval
  end
end
