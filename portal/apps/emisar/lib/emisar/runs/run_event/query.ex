defmodule Emisar.Runs.RunEvent.Query do
  use Emisar, :query

  def all,
    do: from(events in Emisar.Runs.RunEvent, as: :events)

  def by_id(q, id),
    do: where(q, [events: e], e.id == ^id)

  def by_run_id(q, run_id),
    do: where(q, [events: e], e.run_id == ^run_id)

  def by_account_id(q, account_id),
    do: where(q, [events: e], e.account_id == ^account_id)

  @doc """
  Restrict to events whose parent run reached a terminal state before
  `cutoff`. The run's `finished_at` is the authoritative "this run is
  old" signal; the event's own `inserted_at` only correlates. Used by
  `Workers.ActionRunEventRetention` to prune progress chunks once the
  run that produced them ages out of the account's retention window.
  Pair with `by_account_id/2` so the `(account_id, inserted_at)` index
  carries the account scan.

  A subquery (not a join) keeps this safe to compose into a bulk
  delete — Postgres `DELETE` with a correlated `IN` is unambiguous,
  whereas a join-delete leans on `USING` semantics.
  """
  def with_run_finished_before(q, %DateTime{} = cutoff) do
    finished_run_ids = Emisar.Runs.ActionRun.Query.finished_before_ids(cutoff)
    where(q, [events: e], e.run_id in subquery(finished_run_ids))
  end

  def by_kind(q, kind),
    do: where(q, [events: e], e.kind == ^kind)

  def by_stream(q, stream),
    do: where(q, [events: e], e.stream == ^stream)

  def ordered_by_seq(q \\ all()),
    do: order_by(q, [events: e], asc: e.seq)

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:events, :asc, :seq}, {:events, :asc, :id}]
end
