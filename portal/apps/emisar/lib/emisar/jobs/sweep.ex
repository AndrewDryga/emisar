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
  """

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
    reduce_from(limit, nil, initial, fetch_page, reduce_row)
  end

  @doc """
  Walks every page for its side effects, for a sweep that counts nothing.

  Shares `reduce_pages/4`'s loop so the paging contract has one implementation,
  and returns `:ok` rather than an accumulator nobody asked for.
  """
  def each_row(limit, fetch_page, handle_row)
      when is_function(handle_row, 1) do
    reduce_pages(limit, :ok, fetch_page, fn row, :ok ->
      handle_row.(row)
      :ok
    end)
  end

  defp reduce_from(limit, cursor, acc, fetch_page, reduce_row) do
    rows = fetch_page.(limit, cursor)
    acc = Enum.reduce(rows, acc, reduce_row)

    if length(rows) == limit do
      reduce_from(limit, List.last(rows).id, acc, fetch_page, reduce_row)
    else
      acc
    end
  end
end
