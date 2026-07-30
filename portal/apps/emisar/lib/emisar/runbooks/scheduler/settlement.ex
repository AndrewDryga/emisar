defmodule Emisar.Runbooks.Scheduler.Settlement do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Crypto, Repo, Runs}
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Extractor, RunbookExecution, Scheduler}
  alias Emisar.Runbooks.Scheduler.Recovery

  def action_run_settled(
        %Runs.ActionRun{
          runbook_execution_item_id: item_id,
          runbook_execution_id: execution_id
        } = run
      )
      when is_binary(item_id) and is_binary(execution_id) do
    item = ExecutionItem.Query.by_id(item_id) |> Repo.peek()

    with %ExecutionItem{} = item <- item,
         true <- item.status == :running and item.attempt_count == run.attempt_number,
         outcome <- attempt_outcome(run, item),
         {:ok, changed?} <-
           settle_item(run, outcome, item.runbook_execution_stage_id) do
      if changed?, do: Scheduler.advance_execution(execution_id), else: :noop
    else
      _stale_or_missing -> :noop
    end
  end

  def action_run_settled(_run), do: :noop

  defp attempt_outcome(%Runs.ActionRun{status: :success} = run, item) do
    Extractor.evaluate(run, item.output_plan, item.success_plan)
  end

  defp attempt_outcome(%Runs.ActionRun{status: :denied}, _item),
    do: {:error, "denied_by_policy", "Current policy denied the action.", []}

  defp attempt_outcome(%Runs.ActionRun{status: :refused}, _item),
    do: {:error, "runner_refused", "The runner refused the action.", []}

  defp attempt_outcome(%Runs.ActionRun{status: :cancelled}, _item),
    do: {:error, "cancelled", "The action attempt was cancelled.", []}

  defp attempt_outcome(%Runs.ActionRun{}, _item),
    do: {:error, "action_failed", "The action attempt did not succeed.", []}

  defp settle_item(run, outcome, stage_id) do
    Multi.new()
    |> Multi.run(:active_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(run.account_id, repo: repo)
    end)
    |> Multi.run(:execution, &lock_execution(&1, &2, run.runbook_execution_id))
    |> Multi.run(:stage, fn repo, _changes ->
      stage =
        ExecutionStage.Query.by_id(stage_id)
        |> ExecutionStage.Query.lock_for_update()
        |> repo.one()

      {:ok, stage}
    end)
    |> Multi.run(:item, fn repo, _changes ->
      item =
        ExecutionItem.Query.by_id(run.runbook_execution_item_id)
        |> ExecutionItem.Query.lock_for_update()
        |> repo.one()

      {:ok, item}
    end)
    |> Multi.run(:attempt, fn repo, _changes ->
      attempt =
        Runs.ActionRun.Query.all()
        |> Runs.ActionRun.Query.by_id(run.id)
        |> Runs.ActionRun.Query.lock_for_update()
        |> repo.one()

      {:ok, attempt}
    end)
    |> Multi.merge(&compose_settlement(&1, run, outcome))
    |> Repo.commit_multi(after_commit: &after_item_settlement_committed/1)
    |> case do
      {:ok, %{item_settlement: :stale}} -> {:ok, false}
      {:ok, _changes} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_execution(repo, _changes, execution_id) do
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

  defp compose_settlement(changes, supplied_run, outcome) do
    execution = changes.execution
    item = changes.item
    run = changes.attempt

    if settlement_current?(execution, item, run, supplied_run) do
      settle_current_item(execution, item, outcome)
    else
      Multi.run(Multi.new(), :item_settlement, fn _repo, _changes -> {:ok, :stale} end)
    end
  end

  defp after_item_settlement_committed(%{
         execution: execution,
         item_settlement: %ExecutionItem{}
       }) do
    Emisar.Runbooks.broadcast_execution_updated(execution.account_id, execution.id)

    if execution.status == :halted do
      _result = Recovery.scrub_terminal_execution(execution.id)
    end

    :ok
  end

  defp after_item_settlement_committed(_changes), do: :ok

  defp settlement_current?(
         %RunbookExecution{status: execution_status},
         %ExecutionItem{status: :running} = item,
         %Runs.ActionRun{} = run,
         %Runs.ActionRun{} = supplied
       )
       when execution_status in [:active, :halted] do
    Runs.ActionRun.terminal?(run.status) and run.id == supplied.id and
      run.runbook_execution_item_id == item.id and run.attempt_number == item.attempt_count
  end

  defp settlement_current?(_execution, _item, _run, _supplied), do: false

  defp settle_current_item(execution, item, {:ok, result}) do
    {:ok, raw} = Jason.encode(result.raw)
    digest = Crypto.hash_hex(raw)
    now = DateTime.utc_now()

    cond do
      result.conditions_met? ->
        Multi.new()
        |> Multi.update(
          :item_settlement,
          ExecutionItem.Changeset.succeed(
            item,
            result.public,
            raw,
            digest,
            result.evidence,
            now
          )
        )
        |> Multi.insert(:item_succeeded_audit, fn %{item_settlement: succeeded} ->
          Audit.Events.runbook_item_succeeded(execution, succeeded)
        end)

      execution.status == :active and wait_available?(item, now) ->
        next_attempt_at = DateTime.add(now, item.wait["interval_seconds"], :second)

        Multi.new()
        |> Multi.update(
          :item_settlement,
          ExecutionItem.Changeset.wait(
            item,
            result.public,
            raw,
            digest,
            result.evidence,
            next_attempt_at,
            now
          )
        )
        |> Multi.insert(:item_waiting_audit, fn %{item_settlement: waiting} ->
          Audit.Events.runbook_item_waiting(execution, waiting)
        end)

      execution.status == :active and is_map(item.wait) ->
        fail_item_multi(
          execution,
          item,
          "wait_timed_out",
          "Wait budget ended before the success conditions passed.",
          %{public: result.public, raw: raw, digest: digest, evidence: result.evidence},
          now
        )

      true ->
        fail_item_multi(
          execution,
          item,
          "condition_unmet",
          condition_unmet_message(execution),
          %{public: result.public, raw: raw, digest: digest, evidence: result.evidence},
          now
        )
    end
  end

  defp settle_current_item(execution, item, {:error, code, message, evidence}) do
    fail_item_multi(
      execution,
      item,
      code,
      message,
      %{public: %{}, raw: nil, digest: nil, evidence: evidence},
      DateTime.utc_now()
    )
  end

  defp fail_item_multi(execution, item, code, message, result, now) do
    Multi.new()
    |> Multi.update(
      :item_settlement,
      ExecutionItem.Changeset.fail(
        item,
        code,
        message,
        result.public,
        result.raw,
        result.digest,
        result.evidence,
        now
      )
    )
    |> Multi.insert(:item_failed_audit, fn %{item_settlement: failed} ->
      Audit.Events.runbook_item_failed(execution, failed)
    end)
  end

  defp wait_available?(%ExecutionItem{wait: nil}, _now), do: false

  defp wait_available?(%ExecutionItem{} = item, now) do
    started = item.wait_started_at || now
    next = DateTime.add(now, item.wait["interval_seconds"], :second)

    item.attempt_count < item.wait["max_attempts"] and
      DateTime.diff(next, started, :second) <= item.wait["timeout_seconds"]
  end

  defp condition_unmet_message(%RunbookExecution{status: :halted}),
    do: "Success conditions did not pass before the execution halted."

  defp condition_unmet_message(%RunbookExecution{}),
    do: "One or more success conditions did not pass."
end
