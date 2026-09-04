defmodule Emisar.Runs.RunEvent.Query do
  use Emisar, :query

  def all,
    do: from(events in Emisar.Runs.RunEvent, as: :events)

  def by_id(queryable, id),
    do: where(queryable, [events: e], e.id == ^id)

  def by_run_id(queryable, run_id),
    do: where(queryable, [events: e], e.run_id == ^run_id)

  def by_run_ids(queryable, run_ids) when is_list(run_ids),
    do: where(queryable, [events: e], e.run_id in ^run_ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [events: e], e.account_id == ^account_id)

  def by_kind(queryable, kind),
    do: where(queryable, [events: e], e.kind == ^kind)

  def by_stream(queryable, stream),
    do: where(queryable, [events: e], e.stream == ^stream)

  def by_seq_from(queryable \\ all(), seq),
    do: where(queryable, [events: e], e.seq >= ^seq)

  def by_seq_before(queryable \\ all(), seq),
    do: where(queryable, [events: e], e.seq < ^seq)

  def ordered_by_seq(queryable \\ all()),
    do: order_by(queryable, [events: e], asc: e.seq)

  @doc """
  The most recent events first — `seq` DESC, capped at `limit`. Owns both
  the order and the limit so a caller can't get an unordered or unbounded
  slice; the context reverses the page back to chronological order for a
  tail preview (`Runs.list_recent_events_for_run/3`).
  """
  def recent_by_seq(queryable \\ all(), limit) when is_integer(limit) do
    queryable
    |> order_by([events: e], desc: e.seq)
    |> limit(^limit)
  end

  @doc """
  The most recent progress events for each run, ordered chronologically within
  each run. A window keeps the per-run cap in SQL so one noisy action cannot
  crowd other actions out of an execution preview.
  """
  def recent_progress_for_runs(run_ids, limit)
      when is_list(run_ids) and is_integer(limit) do
    ranked =
      all()
      |> by_run_ids(run_ids)
      |> by_kind(:progress)
      |> windows([events: e],
        per_run: [partition_by: e.run_id, order_by: [desc: e.seq]]
      )
      |> select([events: e], %{
        id: e.id,
        run_id: e.run_id,
        seq: e.seq,
        stream: e.stream,
        payload: e.payload,
        rank: over(row_number(), :per_run)
      })

    from(event in subquery(ranked),
      where: event.rank <= ^limit,
      order_by: [asc: event.run_id, asc: event.seq],
      select: %{
        id: event.id,
        run_id: event.run_id,
        seq: event.seq,
        stream: event.stream,
        payload: event.payload
      }
    )
  end
end
