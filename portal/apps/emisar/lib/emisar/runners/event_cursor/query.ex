defmodule Emisar.Runners.EventCursor.Query do
  use Emisar, :query

  def all,
    do: from(cursors in Emisar.Runners.EventCursor, as: :cursors)

  def by_runner_id(q, runner_id),
    do: where(q, [cursors: c], c.runner_id == ^runner_id)

  def by_event_id(q, event_id),
    do: where(q, [cursors: c], c.event_id == ^event_id)

  def by_runner_account_id(q, account_id) do
    q
    |> join(:inner, [cursors: c], r in ^Emisar.Runners.Runner.Query.all(),
      on: r.id == c.runner_id,
      as: :runners
    )
    |> where([runners: r], r.account_id == ^account_id)
  end
end
