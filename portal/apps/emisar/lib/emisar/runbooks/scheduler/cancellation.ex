defmodule Emisar.Runbooks.Scheduler.Cancellation do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Repo, Runs}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{ExecutionItem, ExecutionStage, Runbook, RunbookExecution}
  alias Emisar.Runbooks.Scheduler.Recovery

  def cancel_execution(
        %RunbookExecution{} = expected,
        %Runbook{} = runbook,
        %Subject{} = subject
      ) do
    multi =
      Multi.new()
      |> Multi.run(:active_account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(expected.account_id, repo: repo)
      end)
      |> Multi.run(:execution, fn repo, _changes ->
        execution =
          RunbookExecution.Query.by_account_id(expected.account_id)
          |> RunbookExecution.Query.by_id(expected.id)
          |> RunbookExecution.Query.lock_for_update()
          |> repo.one()

        if execution, do: {:ok, execution}, else: {:error, :not_found}
      end)
      |> Multi.run(:stages, &lock_execution_stages/2)
      |> Multi.run(:items, &lock_execution_items/2)
      |> Multi.merge(&compose_cancellation(&1, runbook, subject))

    case Repo.commit_multi(multi,
           after_commit: &after_execution_cancelled(&1, subject)
         ) do
      {:ok, %{execution: execution}} -> {:ok, Repo.reload!(execution)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_execution_stages(repo, %{execution: execution}) do
    stages =
      ExecutionStage.Query.by_execution_id(execution.id)
      |> ExecutionStage.Query.ordered()
      |> ExecutionStage.Query.lock_for_update()
      |> repo.all()

    {:ok, stages}
  end

  defp lock_execution_items(repo, %{execution: execution}) do
    items =
      ExecutionItem.Query.by_execution_id(execution.id)
      |> ExecutionItem.Query.ordered()
      |> ExecutionItem.Query.lock_for_update()
      |> repo.all()

    {:ok, items}
  end

  defp compose_cancellation(%{execution: %{status: status}}, _runbook, _subject)
       when status != :active,
       do: Multi.new()

  defp compose_cancellation(changes, runbook, subject) do
    now = DateTime.utc_now()
    execution = changes.execution

    multi =
      Multi.new()
      |> Multi.update(
        :execution_cancelled,
        RunbookExecution.Changeset.cancel(execution, now)
      )
      |> Multi.insert(
        :execution_cancel_audit,
        Audit.Events.runbook_execution_cancelled(subject, runbook, execution)
      )

    multi =
      Enum.reduce(changes.stages, multi, fn
        %{status: status} = stage, multi when status in [:pending, :awaiting_approval, :active] ->
          audit_key = {:runbook_stage_cancel_audit, stage.id}
          stage_key = {:runbook_stage_cancelled, stage.id}

          multi
          |> Multi.update(
            stage_key,
            ExecutionStage.Changeset.cancel(stage, now)
          )
          |> Multi.insert(audit_key, fn changes ->
            cancelled = Map.fetch!(changes, stage_key)
            Audit.Events.runbook_stage_cancelled(subject, execution, cancelled)
          end)
          |> maybe_cancel_stage_request(stage)

        _terminal, multi ->
          multi
      end)

    changes.items
    |> Enum.reduce(multi, fn
      %{status: status} = item, multi when status in [:pending, :running, :waiting] ->
        audit_key = {:runbook_item_cancel_audit, item.id}
        item_key = {:runbook_item_cancelled, item.id}

        multi
        |> Multi.update(item_key, ExecutionItem.Changeset.cancel(item, now))
        |> Multi.insert(audit_key, fn changes ->
          cancelled = Map.fetch!(changes, item_key)
          Audit.Events.runbook_item_cancelled(subject, execution, cancelled)
        end)

      _terminal, multi ->
        multi
    end)
    |> Runs.cancel_undispatched_runbook_attempts_in_multi(
      execution.id,
      "runbook execution cancelled"
    )
  end

  defp maybe_cancel_stage_request(multi, %{status: :awaiting_approval, id: stage_id}),
    do: Approvals.cancel_request_for_runbook_stage_in_multi(multi, stage_id)

  defp maybe_cancel_stage_request(multi, _stage), do: multi

  defp after_execution_cancelled(changes, subject) do
    Approvals.after_runbook_stage_cancellation_committed(changes)

    case changes do
      %{execution_cancelled: execution} ->
        Runs.after_undispatched_runbook_attempts_cancelled(changes, execution.id)
        Emisar.Runbooks.broadcast_execution_updated(execution.account_id, execution.id)
        cancel_active_attempts(execution, subject)
        _result = Recovery.scrub_terminal_execution(execution.id)
        :ok

      _unchanged ->
        :ok
    end
  end

  defp cancel_active_attempts(execution, subject) do
    execution.account_id
    |> Runs.list_runs_for_runbook_execution(execution.id)
    |> Enum.reject(&Runs.ActionRun.terminal?(&1.status))
    |> Enum.each(fn run ->
      _result = Runs.cancel_run(run, subject, "runbook execution cancelled")
    end)

    :ok
  end
end
