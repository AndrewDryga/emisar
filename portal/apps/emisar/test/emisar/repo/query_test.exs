defmodule Emisar.Repo.QueryTest do
  use ExUnit.Case, async: true
  alias Emisar.Repo.Query

  defmodule WithCallbacks do
    def cursor_fields, do: [{:records, :desc, :inserted_at}]
    def filters, do: [:status]
    def preloads, do: [owner: []]
  end

  defmodule WithoutOptionalCallbacks do
  end

  test "fetches required cursor fields" do
    assert Query.fetch_cursor_fields!(WithCallbacks) == [{:records, :desc, :inserted_at}]
  end

  test "returns optional query callbacks when present and empty lists when absent" do
    assert Query.get_filters(WithCallbacks) == [:status]
    assert Query.get_preloads_funs(WithCallbacks) == [owner: []]
    assert Query.get_filters(WithoutOptionalCallbacks) == []
    assert Query.get_preloads_funs(WithoutOptionalCallbacks) == []
  end
end
