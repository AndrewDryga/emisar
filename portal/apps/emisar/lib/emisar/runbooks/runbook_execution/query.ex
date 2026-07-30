defmodule Emisar.Runbooks.RunbookExecution.Query do
  use Emisar, :query

  def all,
    do: from(runbook_executions in Emisar.Runbooks.RunbookExecution, as: :runbook_executions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [runbook_executions: r], r.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbook_executions: r], r.account_id == ^account_id)

  def by_runbook_id(queryable \\ all(), runbook_id),
    do: where(queryable, [runbook_executions: r], r.runbook_id == ^runbook_id)

  def by_api_key_id(queryable \\ all(), api_key_id),
    do: where(queryable, [runbook_executions: r], r.api_key_id == ^api_key_id)

  def by_operation_id(queryable \\ all(), operation_id),
    do: where(queryable, [runbook_executions: r], r.operation_id == ^operation_id)

  def by_runner_access(queryable, %Emisar.Accounts.RunnerAccess{mode: :none}),
    do: where(queryable, [runbook_executions: _], false)

  def by_runner_access(queryable, %Emisar.Accounts.RunnerAccess{mode: :all}), do: queryable

  def by_runner_access(
        queryable,
        %Emisar.Accounts.RunnerAccess{mode: :restricted, runner_ids: runner_ids, groups: groups}
      ) do
    disallowed_item =
      Emisar.Runbooks.ExecutionItem.Query.all()
      |> with_named_binding(:scope_runner, fn queryable, binding ->
        join(
          queryable,
          :left,
          [runbook_execution_items: item],
          runner in ^Emisar.Runners.Runner.Query.all(),
          on: item.runner_id == runner.id,
          as: ^binding
        )
      end)
      |> where(
        [runbook_execution_items: item, scope_runner: runner],
        item.runbook_execution_id == parent_as(:runbook_executions).id and
          (is_nil(runner.id) or
             (runner.id not in ^runner_ids and runner.group not in ^groups))
      )
      |> select([runbook_execution_items: _item], 1)

    where(
      queryable,
      [runbook_executions: _],
      not exists(disallowed_item)
    )
  end

  def active(queryable \\ all()),
    do: where(queryable, [runbook_executions: r], r.status == :active)

  def terminal_with_raw_inputs(queryable \\ all()) do
    where(
      queryable,
      [runbook_executions: r],
      r.status in [:succeeded, :halted, :cancelled] and not is_nil(r.inputs_raw)
    )
  end

  def select_count(queryable),
    do: select(queryable, [runbook_executions: r], count(r.id))

  def with_stages_and_items(queryable \\ all()) do
    queryable
    |> preload(
      [runbook_executions: _execution],
      stages: ^Emisar.Runbooks.ExecutionStage.Query.ordered(),
      items: ^Emisar.Runbooks.ExecutionItem.Query.ordered()
    )
  end

  def older_than(queryable \\ all(), cutoff),
    do: where(queryable, [runbook_executions: r], r.inserted_at <= ^cutoff)

  def ordered_by_oldest(queryable \\ all()),
    do: order_by(queryable, [runbook_executions: r], asc: r.inserted_at, asc: r.id)

  def ordered_by_least_recently_advanced(queryable \\ all()) do
    order_by(queryable, [runbook_executions: r],
      asc_nulls_first: r.last_advanced_at,
      asc: r.inserted_at,
      asc: r.id
    )
  end

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [runbook_executions: r], desc: r.inserted_at, desc: r.id)

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")
end
