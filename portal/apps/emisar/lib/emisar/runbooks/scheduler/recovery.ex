defmodule Emisar.Runbooks.Scheduler.Recovery do
  @moduledoc false

  alias Ecto.Multi
  alias Emisar.{Accounts, Repo, Runs}
  alias Emisar.Runbooks.{ExecutionItem, RunbookExecution, Scheduler}
  require Logger

  @batch_size 50

  def recover_due do
    callbacks = Runs.list_terminal_runbook_callbacks(@batch_size)

    Enum.each(callbacks, fn callback ->
      isolated(callback, "runbook_recovery.callback_crashed", fn ->
        Scheduler.action_run_settled(callback)
      end)
    end)

    execution_ids =
      RunbookExecution.Query.active()
      |> RunbookExecution.Query.ordered_by_least_recently_advanced()
      |> RunbookExecution.Query.limit_to(@batch_size)
      |> Repo.all()
      |> Enum.map(& &1.id)

    Enum.each(execution_ids, fn id ->
      isolated(id, "runbook_recovery.advance_crashed", fn ->
        Scheduler.advance_execution(id)
      end)
    end)

    scrubbed =
      RunbookExecution.Query.terminal_with_raw_inputs()
      |> RunbookExecution.Query.ordered_by_oldest()
      |> RunbookExecution.Query.limit_to(@batch_size)
      |> Repo.all()
      |> Enum.count(fn execution ->
        isolated(execution.id, "runbook_recovery.scrub_crashed", fn ->
          scrub_terminal_execution(execution.id)
        end) == :scrubbed
      end)

    Emisar.Telemetry.runbook_recovery(
      recovery_stats(),
      %{
        callbacks: length(callbacks),
        executions: length(execution_ids),
        scrubs: scrubbed
      },
      @batch_size
    )

    length(callbacks) + length(execution_ids) + scrubbed
  end

  def recovery_stats do
    now = DateTime.utc_now()

    active =
      RunbookExecution.Query.active() |> RunbookExecution.Query.select_count() |> Repo.one()

    waiting = ExecutionItem.Query.waiting_recovery_stats(now) |> Repo.one()

    lag =
      case waiting.oldest_overdue_at do
        %DateTime{} = oldest -> max(DateTime.diff(now, oldest, :second), 0)
        nil -> 0
      end

    %{
      active: active,
      waiting: waiting.waiting,
      overdue: waiting.overdue,
      recovery_lag_seconds: lag
    }
  end

  def scrub_terminal_execution(execution_id) when is_binary(execution_id) do
    multi =
      Multi.new()
      |> maybe_lock_execution_account(execution_id)
      |> Multi.run(:execution, &lock_execution(&1, &2, execution_id))
      |> Multi.run(:items, &lock_execution_items/2)
      |> Multi.run(:scrubbed, &scrub_terminal_payloads/2)

    case Repo.commit_multi(multi) do
      {:ok, %{scrubbed: result}} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_lock_execution_account(multi, execution_id) do
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

  # Deliberately does NOT mark the execution advanced, unlike the same-named
  # helpers in Scheduler and Settlement. Those two lock an execution that is
  # about to make progress, and `last_advanced_at` is what orders `recover_due`
  # so a stalled execution is picked up before a busy one. This one is reached
  # only from scrub_terminal_execution/1, which walks TERMINAL rows: there is no
  # progress to record, and touching the clock would reorder the starvation
  # queue on rows that have already finished. Unify the three at your peril.
  defp lock_execution(repo, _changes, execution_id) do
    execution =
      RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.lock_for_update()
      |> repo.one()

    {:ok, execution}
  end

  defp lock_execution_items(_repo, %{execution: nil}), do: {:ok, []}

  defp lock_execution_items(repo, %{execution: execution}) do
    items =
      ExecutionItem.Query.by_execution_id(execution.id)
      |> ExecutionItem.Query.ordered()
      |> ExecutionItem.Query.lock_for_update()
      |> repo.all()

    {:ok, items}
  end

  defp scrub_terminal_payloads(
         repo,
         %{execution: %RunbookExecution{status: status} = execution, items: items}
       )
       when status in [:succeeded, :halted, :cancelled] do
    if Enum.any?(items, &(&1.status == :running)) do
      {:ok, :waiting_for_peers}
    else
      item_scrub =
        ExecutionItem.Query.scrub_raw_payloads_for_execution(
          execution.id,
          DateTime.utc_now()
        )

      with {:ok, _execution} <-
             repo.update(RunbookExecution.Changeset.scrub_raw_inputs(execution)),
           {_count, nil} <- repo.update_all(item_scrub, []) do
        {:ok, :scrubbed}
      end
    end
  end

  defp scrub_terminal_payloads(_repo, _changes), do: {:ok, :not_terminal}

  # Per-row isolation, like sync_subscriptions and monthly_reports. The callback
  # batch is ordered oldest-first, so a row that raises during settlement sat at
  # the head of EVERY batch: recover_due aborted before it reached the active
  # executions, the job restarted every 5s, and the runbook engine stopped
  # advancing for every tenant until someone noticed. One bad row now costs one
  # row.
  defp isolated(subject, event, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("#{event} subject=#{inspect(subject)} error=#{inspect(error.__struct__)}")
      :error
  end
end
