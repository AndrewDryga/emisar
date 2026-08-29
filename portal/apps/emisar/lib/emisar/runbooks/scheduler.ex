defmodule Emisar.Runbooks.Scheduler do
  @moduledoc """
  Durable stage barriers and bounded physical-attempt scheduling.

  Every advance locks execution, stage, then items. Logical item state and a
  new ActionRun attempt commit together; delivery happens only after commit.
  """

  alias Ecto.Multi
  alias Emisar.{Accounts, ActionContract, ApiKeys, Audit, Crypto, Repo, Runs}
  alias Emisar.Runbooks.{Definition, ExecutionItem, ExecutionStage}
  alias Emisar.Runbooks.RunbookExecution
  alias Emisar.Runbooks.Scheduler.{Cancellation, Creation, Recovery, Settlement}

  @doc "Persist a compiled plan and advance its first stage."
  def create_execution(runbook, compiled, reason, subject),
    do: Creation.create_execution(runbook, compiled, reason, subject)

  def create_execution(runbook, compiled, reason, subject, opts),
    do: Creation.create_execution(runbook, compiled, reason, subject, opts)

  @doc """
  Compose the immutable execution, stages, items, and dispatch audit into an
  existing transaction. `execution_id` is caller-owned so MCP reservation and
  resource identity can be atomic.
  """
  def compose_creation(multi, runbook, compiled, reason, subject, execution_id),
    do: Creation.compose_creation(multi, runbook, compiled, reason, subject, execution_id)

  def compose_creation(multi, runbook, compiled, reason, subject, execution_id, opts),
    do: Creation.compose_creation(multi, runbook, compiled, reason, subject, execution_id, opts)

  @doc "Fast-path terminal callback. Duplicate and stale calls are harmless."
  def action_run_settled(run), do: Settlement.action_run_settled(run)

  @doc "Approval callback: advance the execution only after the request commits."
  def approval_settled(execution_id) when is_binary(execution_id),
    do: advance_execution(execution_id)

  @doc "Fail-fast membership and exact-contract recheck before an execution vote."
  def recheck_execution_approval(execution_id) when is_binary(execution_id) do
    execution = RunbookExecution.Query.by_id(execution_id) |> Repo.peek()

    with %RunbookExecution{status: :pending_approval} = execution <- execution,
         :ok <- current_execution_membership(execution),
         items <- items_for_execution(execution.id),
         :ok <- recheck_execution_items(items, execution) do
      :ok
    else
      nil -> {:error, :runbook_execution_not_approvable}
      %RunbookExecution{} -> {:error, :runbook_execution_not_approvable}
      {:error, _reason} = error -> error
    end
  end

  @doc "Activate one still-pending execution inside the approval transaction."
  def activate_pending_approval(repo, execution_id) when is_binary(execution_id) do
    case lock_pending_approval(repo, execution_id) do
      {:ok, execution} ->
        execution
        |> RunbookExecution.Changeset.activate()
        |> repo.update()

      {:error, :runbook_execution_not_approvable} = error ->
        error
    end
  end

  @doc "Lock one still-pending execution without changing it."
  def lock_pending_approval(repo, execution_id) when is_binary(execution_id) do
    execution =
      RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.lock_for_update()
      |> repo.one()

    case execution do
      %RunbookExecution{status: :pending_approval} -> {:ok, execution}
      _ -> {:error, :runbook_execution_not_approvable}
    end
  end

  @doc "Inside an approval transaction, confirm a physical attempt's parent is still active."
  def ensure_attempt_approvable(
        repo,
        %Runs.ActionRun{
          source: :runbook,
          runbook_execution_id: execution_id,
          runbook_execution_item_id: item_id,
          attempt_number: attempt_number
        }
      )
      when is_binary(execution_id) and is_binary(item_id) and is_integer(attempt_number) do
    execution =
      RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.lock_for_update()
      |> repo.one()

    item =
      ExecutionItem.Query.by_id(item_id)
      |> ExecutionItem.Query.lock_for_update()
      |> repo.one()

    case {execution, item} do
      {%RunbookExecution{status: :active},
       %ExecutionItem{
         status: :running,
         runbook_execution_id: ^execution_id,
         attempt_count: ^attempt_number
       }} ->
        :ok

      _inactive ->
        {:error, :runbook_attempt_not_approvable}
    end
  end

  def ensure_attempt_approvable(_repo, %Runs.ActionRun{}), do: :ok

  defp items_for_execution(execution_id) do
    ExecutionItem.Query.by_execution_id(execution_id)
    |> ExecutionItem.Query.ordered()
    |> Repo.all()
  end

  @doc "Advance one execution from durable state. Safe to overlap and repeat."
  def advance_execution(execution_id) when is_binary(execution_id) do
    multi =
      Multi.new()
      |> maybe_lock_execution_account(execution_id)
      |> Multi.run(:execution, &lock_execution(&1, &2, execution_id))
      |> Multi.run(:membership, &lock_membership/2)
      |> Multi.run(:authorization, &lock_current_authorization/2)
      |> Multi.run(:stage, &lock_current_stage/2)
      |> Multi.run(:items, &lock_stage_items/2)
      |> Multi.run(:execution_items, &load_execution_items/2)
      |> Multi.run(:scheduler_action, &choose_action/2)
      |> Multi.merge(&compose_action/1)

    case Repo.commit_multi(multi,
           after_commit: fn changes ->
             Runs.after_composed_dispatches_committed(changes)
             after_advance_committed(changes)
           end
         ) do
      {:ok, changes} ->
        continue_after_action(changes)

      {:error, reason} ->
        halt_after_dispatch_error(execution_id, reason)
    end
  end

  @doc "Bounded authoritative recovery sweep for active executions and due waits."
  def recover_due, do: Recovery.recover_due()

  @doc "Fleet-wide bounded scheduler gauges; never grouped by account."
  def recovery_stats, do: Recovery.recovery_stats()

  @doc "Drop terminal raw input/argument/output bytes once no physical peer remains active."
  def scrub_terminal_execution(execution_id), do: Recovery.scrub_terminal_execution(execution_id)

  @doc "Cancel one visible execution and request cancellation of every active attempt."
  def cancel_execution(execution, runbook, subject),
    do: Cancellation.cancel_execution(execution, runbook, subject)

  @doc "Compose a terminal halt for an execution still parked at its approval gate."
  def halt_pending_approval_in_multi(multi, execution_id, code, message)
      when is_binary(execution_id) and is_binary(code) and is_binary(message) do
    key = {:pending_approval_execution, execution_id}

    multi
    |> Multi.run(key, fn repo, _changes ->
      execution =
        RunbookExecution.Query.by_id(execution_id)
        |> RunbookExecution.Query.lock_for_update()
        |> repo.one()

      stages =
        ExecutionStage.Query.by_execution_id(execution_id)
        |> ExecutionStage.Query.ordered()
        |> ExecutionStage.Query.lock_for_update()
        |> repo.all()

      items =
        ExecutionItem.Query.by_execution_id(execution_id)
        |> ExecutionItem.Query.ordered()
        |> ExecutionItem.Query.lock_for_update()
        |> repo.all()

      case execution do
        %RunbookExecution{status: :pending_approval} ->
          {:ok, %{execution: execution, stages: stages, items: items}}

        _ ->
          {:error, :runbook_execution_not_approvable}
      end
    end)
    |> Multi.merge(fn %{^key => locked} ->
      compose_pending_approval_halt(locked, code, message)
    end)
  end

  defp current_execution_membership(execution) do
    case Accounts.peek_active_membership(
           execution.account_id,
           execution.initiating_membership_id
         ) do
      %Accounts.Membership{} -> :ok
      nil -> {:error, :authorization_lost}
    end
  end

  defp recheck_execution_items(items, execution) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case recheck_execution_item(item, execution) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp recheck_execution_item(item, execution) do
    attrs = %{
      runner_id: item.runner_id,
      action_id: item.action_id,
      pack_ref: item.pack_ref,
      requested_by_membership_id: execution.initiating_membership_id,
      runbook_pack_hash: item.pack_hash,
      runbook_action_contract: item.action_contract
    }

    Runs.recheck_runbook_attempt(attrs, execution.account_id)
  end

  defp compose_pending_approval_halt(locked, code, message) do
    now = DateTime.utc_now()
    execution = locked.execution

    multi =
      Multi.new()
      |> Multi.update(
        {:approval_execution_halted, execution.id},
        RunbookExecution.Changeset.halt(execution, code, message, now)
      )
      |> Multi.insert({:approval_execution_halted_audit, execution.id}, fn changes ->
        halted = Map.fetch!(changes, {:approval_execution_halted, execution.id})
        Audit.Events.runbook_execution_halted(halted)
      end)

    multi =
      Enum.reduce(locked.stages, multi, fn stage, multi ->
        key = {:approval_stage_halted, stage.id}

        multi
        |> Multi.update(key, ExecutionStage.Changeset.halt(stage, code, message, now))
        |> Multi.insert(
          {:approval_stage_halted_audit, stage.id},
          &Audit.Events.runbook_stage_halted(execution, Map.fetch!(&1, key))
        )
      end)

    Enum.reduce(locked.items, multi, fn item, multi ->
      key = {:approval_item_failed, item.id}

      multi
      |> Multi.update(
        key,
        ExecutionItem.Changeset.fail(item, code, message, %{}, nil, nil, [], now)
      )
      |> Multi.insert(
        {:approval_item_failed_audit, item.id},
        &Audit.Events.runbook_item_failed(execution, Map.fetch!(&1, key))
      )
    end)
  end

  @doc """
  Internal — shared with the scheduler's satellites (Recovery, Settlement),
  which used to carry byte-identical copies. Locks the execution's account row
  first so every scheduler transaction takes its locks in the same order.
  """
  def maybe_lock_execution_account(multi, execution_id) do
    execution = RunbookExecution.Query.by_id(execution_id) |> Repo.peek()

    case execution do
      %RunbookExecution{account_id: account_id} ->
        Multi.run(multi, :active_account, fn repo, _changes ->
          Accounts.fetch_and_lock_account(account_id, repo: repo)
        end)

      nil ->
        multi
    end
  end

  @doc """
  Internal — the ADVANCING lock, shared with Settlement, which used to carry a
  byte-identical copy. Locks the execution and stamps `last_advanced_at` on an
  active row, because both callers lock an execution that is about to make
  progress and that stamp is what orders `recover_due`'s starvation queue.
  Recovery's scrub path keeps its own non-advancing variant deliberately — see
  the comment there before unifying anything further.
  """
  def lock_execution(repo, _changes, execution_id) do
    execution =
      RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.lock_for_update()
      |> repo.one()

    case execution do
      %RunbookExecution{status: :active} = execution ->
        execution
        |> RunbookExecution.Changeset.mark_advanced(DateTime.utc_now())
        |> repo.update()

      execution ->
        {:ok, execution}
    end
  end

  defp lock_membership(_repo, %{execution: nil}), do: {:ok, nil}

  defp lock_membership(_repo, %{execution: %{status: status}}) when status != :active,
    do: {:ok, nil}

  defp lock_membership(repo, %{execution: execution}) do
    case Accounts.fetch_and_lock_active_membership(
           repo,
           execution.account_id,
           execution.initiating_membership_id
         ) do
      {:ok, membership} -> {:ok, membership}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp lock_current_authorization(_repo, %{execution: nil}), do: {:ok, :lost}

  defp lock_current_authorization(
         _repo,
         %{execution: %{status: status}}
       )
       when status != :active,
       do: {:ok, :not_applicable}

  defp lock_current_authorization(_repo, %{membership: nil}), do: {:ok, :lost}

  defp lock_current_authorization(
         repo,
         %{execution: execution, membership: membership}
       ) do
    membership_authorized? = Runs.role_can_dispatch_run?(membership.role)

    key_authorized? =
      is_nil(execution.api_key_id) or
        ApiKeys.api_key_usable_in_account?(repo, execution.api_key_id, execution.account_id)

    if membership_authorized? and key_authorized?,
      do: {:ok, :current},
      else: {:ok, :lost}
  end

  defp lock_current_stage(_repo, %{execution: nil}), do: {:ok, nil}

  defp lock_current_stage(repo, %{execution: execution}) do
    stages =
      ExecutionStage.Query.by_execution_id(execution.id)
      |> ExecutionStage.Query.ordered()
      |> ExecutionStage.Query.lock_for_update()
      |> repo.all()

    {:ok, Enum.find(stages, &(&1.status != :succeeded))}
  end

  defp lock_stage_items(_repo, %{stage: nil}), do: {:ok, []}

  defp lock_stage_items(repo, %{stage: stage}) do
    items =
      ExecutionItem.Query.by_stage_id(stage.id)
      |> ExecutionItem.Query.ordered()
      |> ExecutionItem.Query.lock_for_update()
      |> repo.all()

    {:ok, items}
  end

  defp load_execution_items(_repo, %{execution: nil}), do: {:ok, []}

  defp load_execution_items(repo, %{execution: execution}) do
    items =
      ExecutionItem.Query.by_execution_id(execution.id)
      |> ExecutionItem.Query.ordered()
      |> repo.all()

    {:ok, items}
  end

  defp choose_action(_repo, %{execution: nil}), do: {:ok, :noop}

  defp choose_action(_repo, %{execution: %{status: status}}) when status != :active,
    do: {:ok, :noop}

  defp choose_action(
         _repo,
         %{execution: execution, authorization: :lost, stage: stage}
       ) do
    {:ok,
     {:halt, execution, stage, "authorization_lost",
      "Initiating authority is no longer allowed to dispatch."}}
  end

  defp choose_action(_repo, %{execution: execution, stage: nil}),
    do: {:ok, {:succeed_execution, execution}}

  defp choose_action(_repo, %{
         execution: execution,
         stage: stage,
         items: items,
         execution_items: execution_items
       }) do
    cond do
      execution_expired?(execution) ->
        {:ok, {:halt, execution, stage, "execution_timed_out", "Execution exceeded 24 hours."}}

      stage.status == :halted ->
        {:ok,
         {:halt, execution, stage, stage.terminal_code || "dispatch_failed",
          stage.terminal_message || "Stage halted."}}

      Enum.any?(items, &(&1.status in [:failed, :cancelled])) ->
        failed = Enum.find(items, &(&1.status in [:failed, :cancelled]))

        {:ok,
         {:halt, execution, stage, failed.terminal_code || "action_failed",
          failed.terminal_message || "A stage item did not succeed."}}

      Enum.all?(items, &(&1.status == :succeeded)) ->
        {:ok, {:succeed_stage, stage}}

      true ->
        choose_dispatch(execution, stage, items, execution_items)
    end
  end

  defp choose_dispatch(execution, stage, items, execution_items) do
    slots = max(stage.max_parallel - Enum.count(items, &(&1.status == :running)), 0)
    eligible = eligible_items(stage, items, DateTime.utc_now()) |> Enum.take(slots)

    if slots == 0 or eligible == [] do
      {:ok, :noop}
    else
      case prepare_attempts(execution, execution_items, eligible) do
        {:ok, attempts} ->
          {:ok, {:dispatch, execution, stage, attempts}}

        {:error, item, code, message} ->
          {:ok, {:fail_item, execution, stage, item, code, message}}
      end
    end
  end

  defp eligible_items(%ExecutionStage{mode: :parallel}, items, now) do
    Enum.filter(items, &eligible_item?(&1, now))
  end

  defp eligible_items(%ExecutionStage{mode: :sequential}, items, now) do
    current_position =
      items
      |> Enum.reject(&(&1.status == :succeeded))
      |> Enum.map(& &1.step_position)
      |> Enum.min(fn -> nil end)

    Enum.filter(items, &(&1.step_position == current_position and eligible_item?(&1, now)))
  end

  defp eligible_item?(%ExecutionItem{status: :pending}, _now), do: true

  defp eligible_item?(%ExecutionItem{status: :waiting, next_attempt_at: next}, now)
       when not is_nil(next),
       do: DateTime.compare(next, now) != :gt

  defp eligible_item?(_item, _now), do: false

  defp prepare_attempts(execution, all_items, eligible) do
    with {:ok, inputs} <- Jason.decode(execution.inputs_raw),
         true <- is_map(inputs) do
      Enum.reduce_while(eligible, {:ok, []}, fn item, {:ok, attempts} ->
        case materialize_args(item, all_items, inputs) do
          {:ok, raw, digest} ->
            {:cont, {:ok, [%{item: item, args_raw: raw, args_sha256: digest} | attempts]}}

          {:error, code, message} ->
            {:halt, {:error, item, code, message}}
        end
      end)
      |> case do
        {:ok, attempts} -> {:ok, Enum.reverse(attempts)}
        {:error, _item, _code, _message} = error -> error
      end
    else
      _invalid_inputs ->
        {:error, hd(eligible), "invalid_binding", "Frozen execution inputs are invalid."}
    end
  end

  defp materialize_args(%ExecutionItem{args_raw: raw, args_sha256: digest}, _items, _inputs)
       when is_binary(raw) and is_binary(digest),
       do: {:ok, raw, digest}

  defp materialize_args(item, all_items, inputs) do
    with {:ok, args} <- resolve_bindings(item, all_items, inputs),
         :ok <-
           ActionContract.validate(args, %{"args_schema" => item.action_contract["args_schema"]}),
         {:ok, raw} <- Jason.encode(args),
         true <- byte_size(raw) <= Definition.limit!(:max_action_args_bytes) do
      {:ok, raw, Crypto.hash_hex(raw)}
    else
      _invalid -> {:error, "invalid_binding", "A deferred action binding is invalid."}
    end
  end

  defp resolve_bindings(item, all_items, inputs) do
    Enum.reduce_while(item.binding_plan, {:ok, %{}}, fn {name, binding}, {:ok, args} ->
      case binding_value(binding, item, all_items, inputs) do
        {:ok, value} -> {:cont, {:ok, Map.put(args, name, value)}}
        :missing -> {:cont, {:ok, args}}
        :error -> {:halt, {:error, :binding_unavailable}}
      end
    end)
  end

  defp binding_value(%{"source" => "literal", "value" => value}, _item, _items, _inputs),
    do: {:ok, value}

  defp binding_value(%{"source" => "input", "ref" => ref}, _item, _items, inputs) do
    case Map.fetch(inputs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> :missing
    end
  end

  defp binding_value(%{"source" => "output", "ref" => ref}, item, items, _inputs) do
    [step_id, output_id] = String.split(ref, ".", parts: 2)

    producers =
      items
      |> Enum.filter(&(&1.step_id == step_id and &1.stage_position < item.stage_position))
      |> correlate_producers(item.runner_id)

    with [producer] <- producers,
         raw when is_binary(raw) <- producer.outputs_raw,
         {:ok, outputs} <- Jason.decode(raw),
         {:ok, value} <- Map.fetch(outputs, output_id) do
      {:ok, value}
    else
      _unavailable -> :error
    end
  end

  defp correlate_producers([producer], _runner_id), do: [producer]

  defp correlate_producers(producers, runner_id),
    do: Enum.filter(producers, &(&1.runner_id == runner_id))

  defp compose_action(%{scheduler_action: :noop}), do: Multi.new()

  defp compose_action(%{scheduler_action: {:succeed_execution, execution}}) do
    Multi.new()
    |> Multi.update(
      :execution_succeeded,
      RunbookExecution.Changeset.succeed(execution, DateTime.utc_now())
    )
    |> Multi.insert(:execution_succeeded_audit, fn %{execution_succeeded: succeeded} ->
      Audit.Events.runbook_execution_succeeded(succeeded)
    end)
  end

  defp compose_action(%{
         execution: execution,
         scheduler_action: {:succeed_stage, stage}
       }) do
    Multi.new()
    |> Multi.update(
      :stage_succeeded,
      ExecutionStage.Changeset.succeed(stage, DateTime.utc_now())
    )
    |> Multi.insert(:stage_succeeded_audit, fn %{stage_succeeded: succeeded} ->
      Audit.Events.runbook_stage_succeeded(execution, succeeded)
    end)
  end

  defp compose_action(%{
         execution: execution,
         scheduler_action: {:halt, execution, stage, code, message}
       }) do
    Multi.new()
    |> maybe_halt_stage(stage, code, message)
    |> maybe_audit_halted_stage(execution, stage)
    |> Multi.update(
      :execution_halted,
      RunbookExecution.Changeset.halt(execution, code, message, DateTime.utc_now())
    )
    |> Multi.insert(:execution_halted_audit, fn %{execution_halted: halted} ->
      Audit.Events.runbook_execution_halted(halted)
    end)
    |> Runs.cancel_undispatched_runbook_attempts_in_multi(
      execution.id,
      "runbook execution halted"
    )
  end

  defp compose_action(%{
         scheduler_action: {:fail_item, execution, stage, item, code, message}
       }) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.update(
      :item_failed,
      ExecutionItem.Changeset.fail(item, code, message, %{}, nil, nil, [], now)
    )
    |> Multi.insert(:item_failed_audit, fn %{item_failed: failed} ->
      Audit.Events.runbook_item_failed(execution, failed)
    end)
    |> Multi.update(:stage_halted, ExecutionStage.Changeset.halt(stage, code, message, now))
    |> Multi.insert(:stage_halted_audit, fn %{stage_halted: halted} ->
      Audit.Events.runbook_stage_halted(execution, halted)
    end)
    |> Multi.update(
      :execution_halted,
      RunbookExecution.Changeset.halt(execution, code, message, now)
    )
    |> Multi.insert(:execution_halted_audit, fn %{execution_halted: halted} ->
      Audit.Events.runbook_execution_halted(halted)
    end)
    |> Runs.cancel_undispatched_runbook_attempts_in_multi(
      execution.id,
      "runbook execution halted"
    )
  end

  defp compose_action(%{
         scheduler_action: {:dispatch, execution, stage, attempts}
       }) do
    now = DateTime.utc_now()

    multi =
      Multi.update(
        Multi.new(),
        :stage_active,
        ExecutionStage.Changeset.activate(stage, now)
      )
      |> maybe_audit_stage_started(execution, stage)

    multi =
      Enum.reduce(attempts, multi, fn attempt, multi ->
        attempt_number = attempt.item.attempt_count + 1

        Multi.update(
          multi,
          {:runbook_item_started, attempt.item.id},
          ExecutionItem.Changeset.start_attempt(
            attempt.item,
            attempt_number,
            attempt.args_raw,
            attempt.args_sha256,
            now
          )
        )
      end)

    attrs = Enum.map(attempts, &attempt_attrs(execution, stage, &1))

    case Runs.compose_runbook_attempts_in_multi(
           multi,
           attrs,
           execution.account_id,
           execution.initiating_membership_id,
           {:runbook_stage, stage.id},
           use_grants?: false,
           runbook_execution_id: execution.id
         ) do
      {:ok, composed} -> composed
      {:error, reason} -> Multi.error(Multi.new(), :runbook_dispatch, reason)
    end
  end

  defp maybe_halt_stage(multi, nil, _code, _message), do: multi
  defp maybe_halt_stage(multi, %{status: :halted}, _code, _message), do: multi

  defp maybe_halt_stage(multi, stage, code, message) do
    Multi.update(
      multi,
      :stage_halted,
      ExecutionStage.Changeset.halt(stage, code, message, DateTime.utc_now())
    )
  end

  defp maybe_audit_halted_stage(multi, _execution, nil), do: multi
  defp maybe_audit_halted_stage(multi, _execution, %{status: :halted}), do: multi

  defp maybe_audit_halted_stage(multi, execution, _stage) do
    Multi.insert(multi, :stage_halted_audit, fn %{stage_halted: halted} ->
      Audit.Events.runbook_stage_halted(execution, halted)
    end)
  end

  defp maybe_audit_stage_started(multi, _execution, %{status: :active}), do: multi

  defp maybe_audit_stage_started(multi, execution, _stage) do
    Multi.insert(multi, :stage_started_audit, fn %{stage_active: active} ->
      Audit.Events.runbook_stage_started(execution, active)
    end)
  end

  defp attempt_attrs(execution, stage, attempt) do
    item = attempt.item

    %{
      runner_id: item.runner_id,
      action_id: item.action_id,
      args_raw: attempt.args_raw,
      reason: "runbook: #{stage.title} / #{item.step_id} — #{execution.reason}",
      requested_by_id: execution.requested_by_id,
      api_key_id: execution.api_key_id,
      operation_id: execution.operation_id,
      runbook_id: execution.runbook_id,
      runbook_step_id: item.step_id,
      runbook_execution_id: execution.id,
      runbook_execution_stage_id: stage.id,
      runbook_execution_item_id: item.id,
      attempt_number: item.attempt_count + 1,
      pack_ref: item.pack_ref,
      runbook_pack_hash: item.pack_hash,
      runbook_action_contract: item.action_contract
    }
  end

  defp after_advance_committed(
         %{
           execution: %RunbookExecution{} = execution,
           scheduler_action: action
         } = changes
       )
       when action != :noop do
    Runs.after_undispatched_runbook_attempts_cancelled(changes, execution.id)
    Emisar.Runbooks.broadcast_execution_updated(execution.account_id, execution.id)
    maybe_scrub_after_commit(changes, execution)
  end

  defp after_advance_committed(_changes), do: :ok

  defp continue_after_action(%{scheduler_action: {:succeed_stage, stage}}) do
    advance_execution(stage.runbook_execution_id)
  end

  defp continue_after_action(%{scheduler_action: _action}), do: :ok

  defp halt_after_dispatch_error(execution_id, reason) do
    code = dispatch_error_code(reason)
    message = dispatch_error_message(reason)

    Multi.new()
    |> maybe_lock_execution_account(execution_id)
    |> Multi.run(:execution, &lock_execution(&1, &2, execution_id))
    |> Multi.run(:stage, &lock_current_stage/2)
    |> Multi.merge(fn
      %{execution: %RunbookExecution{status: :active} = execution, stage: stage} ->
        compose_action(%{
          execution: execution,
          scheduler_action: {:halt, execution, stage, code, message}
        })

      _stale ->
        Multi.new()
    end)
    |> Repo.commit_multi(after_commit: &after_halt_committed/1)

    {:error, :dispatch_failed}
  end

  defp after_halt_committed(%{execution_halted: execution} = changes) do
    Runs.after_undispatched_runbook_attempts_cancelled(changes, execution.id)
    Emisar.Runbooks.broadcast_execution_updated(execution.account_id, execution.id)
    _result = scrub_terminal_execution(execution.id)
    :ok
  end

  defp after_halt_committed(_changes), do: :ok

  defp dispatch_error_message(:denied_by_policy), do: "Current policy denied the dispatch."
  defp dispatch_error_message(:runner_out_of_scope), do: "Runner scope changed before dispatch."
  defp dispatch_error_message(:runner_not_found), do: "A frozen runner is no longer available."
  defp dispatch_error_message(:pack_untrusted), do: "The frozen pack is no longer trusted."

  defp dispatch_error_message(:action_contract_changed),
    do: "The frozen action contract changed before dispatch."

  defp dispatch_error_message(_reason), do: "The action attempt could not be dispatched."

  defp dispatch_error_code(:denied_by_policy), do: "denied_by_policy"
  defp dispatch_error_code(:runner_out_of_scope), do: "authorization_lost"
  defp dispatch_error_code(_reason), do: "dispatch_failed"

  defp maybe_scrub_after_commit(changes, execution) do
    if Map.has_key?(changes, :execution_succeeded) or
         Map.has_key?(changes, :execution_halted) do
      _result = scrub_terminal_execution(execution.id)
    end

    :ok
  end

  defp execution_expired?(execution) do
    DateTime.diff(DateTime.utc_now(), execution.inserted_at, :second) >=
      Definition.limit!(:max_execution_seconds)
  end

  @doc "Internal persisted execution result for dispatch and MCP replay."
  def fetch_result(execution_id, account_id) do
    execution_query =
      RunbookExecution.Query.by_account_id(account_id)
      |> RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.with_stages_and_items()

    with {:ok, execution} <- Repo.fetch(execution_query, RunbookExecution.Query) do
      runs = Runs.list_runs_for_runbook_execution(account_id, execution_id)

      {:ok,
       %{
         execution_id: execution.id,
         total: execution.frozen_plan["total_items"],
         plan: execution.frozen_plan,
         runs: runs,
         errors: []
       }}
    end
  end
end
