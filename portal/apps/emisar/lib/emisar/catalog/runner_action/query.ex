defmodule Emisar.Catalog.RunnerAction.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(runner_actions in Emisar.Catalog.RunnerAction, as: :runner_actions)

  def by_id(queryable, id),
    do: where(queryable, [runner_actions: a], a.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runner_actions: a], a.account_id == ^account_id)

  def by_runner_id(queryable, runner_id),
    do: where(queryable, [runner_actions: a], a.runner_id == ^runner_id)

  def by_runner_ids(queryable, runner_ids) when is_list(runner_ids),
    do: where(queryable, [runner_actions: a], a.runner_id in ^runner_ids)

  def by_action_id(queryable, action_id),
    do: where(queryable, [runner_actions: a], a.action_id == ^action_id)

  def by_action_ids(queryable, action_ids) when is_list(action_ids),
    do: where(queryable, [runner_actions: a], a.action_id in ^action_ids)

  def select_action_risk_rows(queryable),
    do: select(queryable, [runner_actions: a], {a.runner_id, a.action_id, a.risk})

  def by_pack(queryable, pack_id, pack_version) do
    where(
      queryable,
      [runner_actions: a],
      a.pack_id == ^pack_id and a.pack_version == ^pack_version
    )
  end

  def by_pack_id(queryable, pack_id),
    do: where(queryable, [runner_actions: a], a.pack_id == ^pack_id)

  def by_pack_hash(queryable, pack_hash),
    do: where(queryable, [runner_actions: a], a.pack_hash == ^pack_hash)

  # Distinct runner ids advertising the filtered actions — the blast radius
  # of trusting a pack (which hosts will run it).
  def distinct_runner_ids(queryable),
    do: queryable |> distinct(true) |> select([runner_actions: a], a.runner_id)

  # Distinct pack ids in the scoped actions — the option set for the runner
  # detail page's Pack filter (the packs THAT runner advertises).
  def distinct_pack_ids(queryable),
    do: queryable |> distinct(true) |> select([runner_actions: a], a.pack_id)

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

  # The runner-detail action catalog's filters: a 58-82-action list is
  # undiscoverable without them. Search matches the id + title; Pack narrows to
  # one advertised pack; Risk to a tier. All three are the LiveTable `%Filter{}`
  # grammar, so a control at its default reads inactive and doesn't raise "clear".
  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :action,
        title: "Search actions",
        type: :string,
        # Substring, case-insensitive, over the action id AND its human title —
        # "log" finds `caddy.access_log_tail` and "Tail access log".
        fun: fn queryable, term ->
          pattern = Like.contains(term)

          {queryable,
           dynamic(
             [runner_actions: a],
             ilike(a.action_id, ^pattern) or ilike(a.title, ^pattern)
           )}
        end
      },
      %Filter{
        name: :pack_id,
        title: "Pack",
        type: {:list, :string},
        # Options are per-runner — the RunnerDetail LiveView injects the packs
        # this runner advertises at render, like the runs page's Runner picker.
        values: [],
        fun: fn queryable, pack_ids ->
          {queryable, dynamic([runner_actions: a], a.pack_id in ^pack_ids)}
        end
      },
      %Filter{
        name: :risk,
        title: "Risk",
        type: {:list, :string},
        values: [
          {"low", "Low"},
          {"medium", "Medium"},
          {"high", "High"},
          {"critical", "Critical"}
        ],
        fun: fn queryable, risks ->
          {queryable, dynamic([runner_actions: a], a.risk in ^risks)}
        end
      }
    ]
end
