defmodule Emisar.Catalog.RunnerAction.Query do
  use Emisar, :query

  def all,
    do: from(runner_actions in Emisar.Catalog.RunnerAction, as: :runner_actions)

  def by_id(queryable, id),
    do: where(queryable, [runner_actions: a], a.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runner_actions: a], a.account_id == ^account_id)

  def by_runner_id(queryable, runner_id),
    do: where(queryable, [runner_actions: a], a.runner_id == ^runner_id)

  def by_action_id(queryable, action_id),
    do: where(queryable, [runner_actions: a], a.action_id == ^action_id)

  def by_risk(queryable, risk),
    do: where(queryable, [runner_actions: a], a.risk == ^risk)

  def by_account_runner_and_action(queryable, account_id, runner_id, action_id) do
    queryable
    |> where(
      [runner_actions: a],
      a.account_id == ^account_id and
        a.runner_id == ^runner_id and
        a.action_id == ^action_id
    )
  end

  def except_action_ids(queryable, action_ids) when is_list(action_ids),
    do: where(queryable, [runner_actions: a], a.action_id not in ^action_ids)

  def ordered_by_action(queryable),
    do: order_by(queryable, [runner_actions: a], asc: a.action_id)

  def ordered_by_action_seen(queryable),
    do: order_by(queryable, [runner_actions: a], asc: a.action_id, asc: a.last_seen_at)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runner_actions, :asc, :action_id}, {:runner_actions, :asc, :id}]
end
