defmodule Emisar.Catalog.RunnerAction.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(runner_actions in Emisar.Catalog.RunnerAction, as: :runner_actions)

  def none(queryable), do: where(queryable, false)

  def by_id(queryable, id),
    do: where(queryable, [runner_actions: a], a.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runner_actions: a], a.account_id == ^account_id)

  def by_runner_id(queryable, runner_id),
    do: where(queryable, [runner_actions: a], a.runner_id == ^runner_id)

  def by_runner_ids(queryable, runner_ids) when is_list(runner_ids),
    do: where(queryable, [runner_actions: a], a.runner_id in ^runner_ids)

  def by_deployments(queryable, []), do: none(queryable)

  def by_deployments(queryable, deployments) when is_list(deployments) do
    predicate =
      Enum.reduce(deployments, dynamic(false), fn {runner_id, pack_id, version, hash},
                                                  predicate ->
        dynamic(
          [runner_actions: action],
          ^predicate or
            (action.runner_id == ^runner_id and action.pack_id == ^pack_id and
               action.pack_version == ^version and action.pack_hash == ^hash)
        )
      end)

    where(queryable, ^predicate)
  end

  def by_action_id(queryable, action_id),
    do: where(queryable, [runner_actions: a], a.action_id == ^action_id)

  def by_action_ids(queryable, action_ids) when is_list(action_ids),
    do: where(queryable, [runner_actions: a], a.action_id in ^action_ids)

  @doc """
  Restrict to an exact bounded set of `{runner_id, action_id}` pairs — the
  approvals queue resolves each frozen request's own runner+action, and a
  cross-product `runner_id in ... and action_id in ...` would answer for pairs
  nobody asked about. The caller bounds the list.
  """
  def by_runner_action_pairs(queryable, pairs) when is_list(pairs) do
    predicate =
      Enum.reduce(pairs, dynamic(false), fn {runner_id, action_id}, predicate ->
        dynamic(
          [runner_actions: a],
          ^predicate or (a.runner_id == ^runner_id and a.action_id == ^action_id)
        )
      end)

    where(queryable, ^predicate)
  end

  @doc """
  Restrict to the actions advertised by the runners a membership scope grants —
  matched by runner id or by the runner's group, which needs the runner row.
  The caller resolves the none/all modes before calling.
  """
  def by_runner_scope_values(queryable, runner_ids, groups) do
    queryable
    |> with_named_binding(:scope_runner, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [runner_actions: a],
        runner in ^Emisar.Runners.Runner.Query.not_deleted(),
        on: a.runner_id == runner.id,
        as: ^binding
      )
    end)
    |> where([scope_runner: r], r.id in ^runner_ids or r.group in ^groups)
  end

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

  @doc "Locks one advertised action after its owning pack-version lock is held."
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

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

  # Ordered by (action_id, id), NOT last_seen_at: that column is in the observe
  # upsert's replace set, so it moves every time a runner re-advertises. A
  # keyset cursor over a moving column re-serves the boundary row on the next
  # page when a runner reconnects mid-list — and, for the account-wide grouped
  # view where it actually tie-breaks, can skip rows too. `id` is stable and
  # unique, so the order is fully determined either way.
  def ordered_by_action_seen(queryable),
    do: order_by(queryable, [runner_actions: a], asc: a.action_id, asc: a.id)

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  # -- Pagination ------------------------------------------------------

  # Matches ordered_by_action_seen/1. Both columns are immutable for a given
  # row, which is what makes the cursor stable across a re-advertisement.
  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [
      {:runner_actions, :asc, :action_id},
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
