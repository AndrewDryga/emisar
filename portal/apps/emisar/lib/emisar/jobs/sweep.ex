defmodule Emisar.Jobs.Sweep do
  @moduledoc """
  The keyset paging loop every recurrent sweep shares.

  Nine jobs each had their own copy of it, four byte-identical, and the contract
  they were all restating is small but easy to get subtly wrong: read a page
  keyed on the LAST row's id (never an offset, which drifts as rows are deleted
  underneath the sweep), fold the page, and stop when a short page proves the
  source is exhausted. A full page always means "ask again", so a source that
  returns exactly `limit` rows on its final page costs one extra empty read
  rather than silently dropping the tail.

  Rows must be ordered by the same id used as the cursor, and must carry `:id`.

  A row that raises is logged and skipped rather than killing the tick: the
  page is keyset-ordered and every tick restarts at the head, so one poisoned
  account would otherwise starve every account after it on every future tick.
  """
  require Logger

  @doc """
  Folds `initial` over every page.

  `fetch_page` receives `(limit, cursor)` — the cursor is `nil` on the first
  page and the previous page's last id after that — and returns the rows.
  `reduce_row` receives `(row, accumulator)` per row, like `Enum.reduce/3`.

  A sweep that accumulates nothing passes `:ok` and returns it, which keeps the
  counting and non-counting sweeps on one loop.
  """
  def reduce_pages(limit, initial, fetch_page, reduce_row)
      when is_integer(limit) and limit > 0 and
             is_function(fetch_page, 2) and is_function(reduce_row, 2) do
    reduce_from(limit, nil, initial, fetch_page, reduce_row, sweep_name(reduce_row))
  end

  @doc """
  Walks every page for its side effects, for a sweep that counts nothing.

  Shares `reduce_pages/4`'s paging loop so the contract has one implementation,
  and returns `:ok` rather than an accumulator nobody asked for.
  """
  def each_row(limit, fetch_page, handle_row)
      when is_integer(limit) and limit > 0 and
             is_function(fetch_page, 2) and is_function(handle_row, 1) do
    reduce_row = fn row, :ok ->
      handle_row.(row)
      :ok
    end

    # Named after `handle_row`, never the wrapper above: the wrapper is defined
    # HERE, so its module would blame this module for every sweep's failures.
    reduce_from(limit, nil, :ok, fetch_page, reduce_row, sweep_name(handle_row))
  end

  defp reduce_from(limit, cursor, acc, fetch_page, reduce_row, sweep) do
    rows = fetch_page.(limit, cursor)
    acc = Enum.reduce(rows, acc, &reduce_row_safely(&1, &2, reduce_row, sweep))

    if length(rows) == limit do
      reduce_from(limit, List.last(rows).id, acc, fetch_page, reduce_row, sweep)
    else
      acc
    end
  end

  # Only the exception STRUCT is logged: a sweep row carries customer data, and
  # so can the message an Ecto or Postgrex error renders from it.
  defp reduce_row_safely(row, acc, reduce_row, sweep) do
    reduce_row.(row, acc)
  rescue
    error ->
      Logger.warning("sweep.row_failed row=#{row.id}",
        job: sweep,
        error: inspect(error.__struct__)
      )

      acc
  end

  # The caller's own fold names the sweep, so the signal points at the job
  # without every one of them having to pass its module.
  defp sweep_name(fun) do
    {:module, module} = Function.info(fun, :module)
    inspect(module)
  end
end
