defmodule Emisar.Runs.RunEvent.Query do
  use Emisar, :query

  def all,
    do: from(events in Emisar.Runs.RunEvent, as: :events)

  def by_run_id(queryable, run_id),
    do: where(queryable, [events: e], e.run_id == ^run_id)

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
  each run. Each lateral read stops at its own limit on the (run_id, seq) index;
  the projection bounds chunk bytes before any payload reaches the caller.
  """
  def recent_progress_for_runs(run_ids, limit, max_chunk_bytes)
      when is_list(run_ids) and is_integer(limit) and is_integer(max_chunk_bytes) do
    tail =
      all()
      |> by_kind(:progress)
      |> where([events: e], e.run_id == parent_as(:tail_run).id)
      |> recent_by_seq(limit)
      |> select([events: e], %{
        id: e.id,
        run_id: e.run_id,
        seq: e.seq,
        stream: e.stream,
        payload: e.payload
      })

    from(run in Emisar.Runs.ActionRun,
      as: :tail_run,
      where: run.id in ^run_ids,
      inner_lateral_join: event in subquery(tail),
      as: :events,
      on: true,
      order_by: [asc: event.run_id, asc: event.seq],
      select: %{
        id: event.id,
        run_id: event.run_id,
        seq: event.seq,
        stream:
          fragment(
            "CASE WHEN coalesce(?, ?->>'stream') = 'stderr' THEN 'stderr' ELSE 'stdout' END",
            event.stream,
            event.payload
          ),
        chunk:
          fragment(
            """
            substring(
              convert_to(CASE WHEN jsonb_typeof(?->'chunk') = 'string'
                THEN ?->>'chunk' ELSE '' END, 'UTF8')
              FROM greatest(octet_length(convert_to(
                CASE WHEN jsonb_typeof(?->'chunk') = 'string'
                  THEN ?->>'chunk' ELSE '' END, 'UTF8')) - ? + 1, 1)
              FOR ?)
            """,
            event.payload,
            event.payload,
            event.payload,
            event.payload,
            ^max_chunk_bytes,
            ^max_chunk_bytes
          ),
        chunk_bytes:
          fragment(
            "octet_length(CASE WHEN jsonb_typeof(?->'chunk') = 'string' THEN ?->>'chunk' ELSE '' END)",
            event.payload,
            event.payload
          )
      }
    )
  end
end
