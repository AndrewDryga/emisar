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

  def by_action_ids(queryable, action_ids) when is_list(action_ids),
    do: where(queryable, [runner_actions: a], a.action_id in ^action_ids)

  def by_risk(queryable, risk),
    do: where(queryable, [runner_actions: a], a.risk == ^risk)

  def by_pack(queryable, pack_id, pack_version),
    do:
      where(
        queryable,
        [runner_actions: a],
        a.pack_id == ^pack_id and a.pack_version == ^pack_version
      )

  # Distinct runner ids advertising the filtered actions — the blast radius
  # of trusting a pack (which hosts will run it).
  def distinct_runner_ids(queryable),
    do: queryable |> distinct(true) |> select([runner_actions: a], a.runner_id)

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

  # Ordered (action_id, last_seen_at, id) so the account catalog's grouped view
  # is keyset-stable. `(runner_id, action_id)` is unique, so for the by-runner
  # list `last_seen_at` never tie-breaks — the order is identical to action_id
  # alone there. The trailing `id` makes the tuple unique account-wide (an
  # action_id is advertised by many runners).
  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [
      {:runner_actions, :asc, :action_id},
      {:runner_actions, :asc, :last_seen_at},
      {:runner_actions, :asc, :id}
    ]
end
