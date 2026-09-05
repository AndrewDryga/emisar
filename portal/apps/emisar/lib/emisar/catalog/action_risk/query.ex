defmodule Emisar.Catalog.ActionRisk.Query do
  @moduledoc false
  use Emisar, :query

  def for_target(query, :account), do: query

  def for_target(query, {:runner, id}),
    do: Emisar.Catalog.RunnerAction.Query.by_runner_scope_values(query, [id], [])

  def for_target(query, {:group, name}),
    do: Emisar.Catalog.RunnerAction.Query.by_runner_scope_values(query, [], [name])

  # Lexical MAX(risk) is wrong (medium sorts after critical). Aggregate only
  # the semantic rank, returning one small row per distinct action.
  def aggregate(query) do
    query
    |> group_by([runner_actions: a], a.action_id)
    |> select([runner_actions: a], %{
      action_id: a.action_id,
      risk:
        fragment(
          "(ARRAY['low','medium','high','critical'])[MAX(CASE ? WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 WHEN 'critical' THEN 4 ELSE 5 END)]",
          a.risk
        )
    })
  end

  def cursor_fields, do: [{:runner_actions, :asc, :action_id}]
end
