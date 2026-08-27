defmodule Emisar.Runbooks.ExecutionItem.Query do
  use Emisar, :query

  def all,
    do: from(items in Emisar.Runbooks.ExecutionItem, as: :runbook_execution_items)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [runbook_execution_items: i], i.id == ^id)

  def by_execution_id(queryable \\ all(), execution_id),
    do: where(queryable, [runbook_execution_items: i], i.runbook_execution_id == ^execution_id)

  def by_stage_id(queryable \\ all(), stage_id),
    do: where(queryable, [runbook_execution_items: i], i.runbook_execution_stage_id == ^stage_id)

  def select_approval_targets(queryable) do
    select(queryable, [runbook_execution_items: i], %{
      runner_id: i.runner_id,
      pack_ref: i.pack_ref
    })
  end

  def by_status(queryable \\ all(), status),
    do: where(queryable, [runbook_execution_items: i], i.status == ^status)

  def active_workload_for_account(queryable \\ all(), account_id) do
    queryable
    |> join(
      :inner,
      [runbook_execution_items: i],
      execution in Emisar.Runbooks.RunbookExecution,
      on: execution.id == i.runbook_execution_id,
      as: :active_execution
    )
    |> where(
      [runbook_execution_items: i, active_execution: e],
      i.account_id == ^account_id and
        (e.status in [:pending_approval, :active] or i.status == :running)
    )
  end

  def select_count(queryable),
    do: select(queryable, [runbook_execution_items: i], count(i.id))

  def pending(queryable \\ all()),
    do: by_status(queryable, :pending)

  def waiting_recovery_stats(queryable \\ all(), now) do
    queryable
    |> by_status(:waiting)
    |> select([runbook_execution_items: i], %{
      waiting: count(i.id),
      overdue: filter(count(i.id), i.next_attempt_at <= ^now),
      oldest_overdue_at: filter(min(i.next_attempt_at), i.next_attempt_at <= ^now)
    })
  end

  def scrub_raw_payloads_for_execution(queryable \\ all(), execution_id, now) do
    queryable
    |> by_execution_id(execution_id)
    |> update(set: [args_raw: nil, outputs_raw: nil, updated_at: ^now])
  end

  def ordered(queryable \\ all()) do
    order_by(
      queryable,
      [runbook_execution_items: i],
      asc: i.stage_position,
      asc: i.step_position,
      asc: i.runner_ref
    )
  end

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")
end
