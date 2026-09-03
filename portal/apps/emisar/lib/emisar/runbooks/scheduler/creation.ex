defmodule Emisar.Runbooks.Scheduler.Creation do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Policies, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{Authorizer, Definition, ExecutionItem, ExecutionStage, Runbook}
  alias Emisar.Runbooks.{RunbookExecution, Scheduler}

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

    kind = Keyword.get(opts, :kind, :published)
    runbook_version = dispatched_version(runbook, kind)

    approval =
      compiled.items
      |> approval_posture()
      |> with_runbook_metadata(runbook, compiled, runbook_version, kind)

    execution_attrs = %{
      id: execution_id,
      account_id: runbook.account_id,
      runbook_id: runbook.id,
      runbook_version: runbook_version,
      initiating_membership_id: subject.membership_id,
      requested_by_id: Subject.user_id(subject),
      api_key_id: Subject.api_key_id(subject),
      operation_id: Keyword.get(opts, :operation_id),
      mcp_operation_record_id: Keyword.get(opts, :mcp_operation_record_id),
      reason: reason,
      kind: kind,
      frozen_plan: compiled.plan,
      inputs_raw: compiled.inputs_raw,
      inputs_sha256: compiled.inputs_sha256,
      # What ran, not what the runbook row says now — publishing moves that row.
      definition: compiled.definition,
      definition_sha256: Definition.digest(compiled.definition),
      status: if(approval, do: :pending_approval, else: :active)
    }

    multi
    |> Multi.run({:runbook_capacity, execution_id}, fn repo, _changes ->
      reserve_account_capacity(repo, runbook.account_id, length(items))
    end)
    |> Multi.run({:runbook_current, execution_id}, fn repo, _changes ->
      # A mounted page holds a pre-transaction struct. Lock the current row
      # after the account lock so deletion serializes with execution creation;
      # published versions are immutable, so the compiled definition stays valid.
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Runbook.Query.by_account_id(runbook.account_id)
      |> Runbook.Query.lock_for_update()
      |> Authorizer.for_subject(subject)
      |> repo.fetch(Runbook.Query)
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
        target_selection: item.target_selection,
        target_group: item.target_group,
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

  # The definition schema allows 16 stages and 256 items, so a wide fan-out wrote
  # 272 statements inside the account lock this transaction already holds. Two
  # statements instead — one bad row still aborts the whole dispatch, which is
  # what a runbook wants.
  defp insert_stages(multi, stages) do
    Multi.run(multi, :runbook_stages, fn repo, _changes ->
      insert_validated_rows(repo, ExecutionStage, stages, &ExecutionStage.Changeset.create/1)
    end)
  end

  defp insert_items(multi, items) do
    Multi.run(multi, :runbook_items, fn repo, _changes ->
      insert_validated_rows(repo, ExecutionItem, items, &ExecutionItem.Changeset.create/1)
    end)
  end

  # `insert_all` skips changesets, so every row is validated first and the first
  # invalid one is returned as the step's error — the same `{:error, changeset}`
  # a per-row insert produced. Timestamps are supplied because `insert_all` does
  # not autogenerate them; every other column the changeset leaves out carries a
  # database default.
  defp insert_validated_rows(repo, schema, rows, build_changeset) do
    now = DateTime.utc_now()

    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, entries} ->
      changeset = build_changeset.(row)

      if changeset.valid? do
        entry = Map.merge(changeset.changes, %{inserted_at: now, updated_at: now})
        {:cont, {:ok, [entry | entries]}}
      else
        {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, entries} ->
        {count, nil} = repo.insert_all(schema, Enum.reverse(entries))
        {:ok, count}

      {:error, changeset} ->
        {:error, changeset}
    end
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

  # A draft test has no release number to name; its digest is the identity.
  defp dispatched_version(%Runbook{} = runbook, :published), do: runbook.live_version
  defp dispatched_version(%Runbook{}, :draft_test), do: nil

  defp with_runbook_metadata(nil, _runbook, _compiled, _version, _kind), do: nil

  defp with_runbook_metadata(approval, runbook, compiled, version, kind) do
    approval
    |> Map.put(:execution_kind, Atom.to_string(kind))
    |> Map.put(:runbook, %{
      "id" => runbook.id,
      "title" => runbook.title,
      "version" => version,
      "definition_sha256" => Definition.digest(compiled.definition)
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
