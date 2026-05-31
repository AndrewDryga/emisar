defmodule Emisar.Runs.RunEvent.Query do
  use Emisar, :query

  def all,
    do: from(events in Emisar.Runs.RunEvent, as: :events)

  def by_id(q, id),
    do: where(q, [events: e], e.id == ^id)

  def by_run_id(q, run_id),
    do: where(q, [events: e], e.run_id == ^run_id)

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
