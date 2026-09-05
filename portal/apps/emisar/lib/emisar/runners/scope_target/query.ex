defmodule Emisar.Runners.ScopeTarget.Query do
  @moduledoc false
  use Emisar, :query

  # A SQL projection, not a materialized fleet: only the caller's page crosses
  # the database boundary. Explicit grants keep an empty group selectable.
  def all(runners, account_id, granted_groups) do
    runner_targets =
      select(runners, [runners: r], %{
        account_id: r.account_id,
        scope_type: "runner",
        scope_value: fragment("?::text", r.id),
        group_sort: coalesce(r.group, ""),
        kind_sort: 1,
        label: r.name
      })

    groups =
      runners
      |> where([runners: r], not is_nil(r.group) and r.group != "")
      |> select([runners: r], %{
        account_id: r.account_id,
        scope_type: "group",
        scope_value: r.group,
        group_sort: r.group,
        kind_sort: 0,
        label: r.group
      })

    grants =
      from(g in fragment("SELECT unnest(?::text[]) AS name", ^granted_groups),
        where: g.name != "",
        select: %{
          account_id: type(^account_id, Ecto.UUID),
          scope_type: "group",
          scope_value: g.name,
          group_sort: g.name,
          kind_sort: 0,
          label: g.name
        }
      )

    runner_targets |> union(^groups) |> union(^grants)
  end
end
