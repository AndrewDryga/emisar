defmodule Emisar.Repo.PaginatorTest do
  use ExUnit.Case, async: true
  alias Emisar.Repo.Paginator

  defmodule CursorQuery do
    def cursor_fields, do: [{:records, :asc, :id}]
  end

  defmodule WideCursorQuery do
    def cursor_fields, do: [{:records, :asc, :name}, {:records, :asc, :id}]
  end

  describe "init/3" do
    test "clamps the requested page limit" do
      assert {:ok, %{limit: 35}} = Paginator.init(CursorQuery, [], [])
      assert {:ok, %{limit: 1}} = Paginator.init(CursorQuery, [], limit: 0)
      assert {:ok, %{limit: 100}} = Paginator.init(CursorQuery, [], limit: 1_000)
    end

    test "a prepended order field overrides its non-adjacent cursor-field twin" do
      # No duplicated keyset slot survives — a crafted cursor could otherwise
      # carry two different boundary values for one column.
      assert {:ok, %{cursor_fields: [{:records, :desc, :id}, {:records, :asc, :name}]}} =
               Paginator.init(WideCursorQuery, [{:records, :desc, :id}], [])
    end

    test "accepts a cursor emitted for the same cursor fields" do
      cursor = Paginator.encode_cursor(:after, CursorQuery.cursor_fields(), %{id: "record-1"})

      assert {:ok, %{direction: :after, values: ["record-1"]}} =
               Paginator.init(CursorQuery, [], cursor: cursor)
    end

    test "rejects a cursor with an unsupported direction or value count" do
      unsupported_direction = encode_cursor({:error, [{:t, "record-1"}]})
      wrong_value_count = encode_cursor({:after, []})

      assert {:error, :invalid_cursor} =
               Paginator.init(CursorQuery, [], cursor: unsupported_direction)

      assert {:error, :invalid_cursor} =
               Paginator.init(CursorQuery, [], cursor: wrong_value_count)
    end
  end

  describe "metadata/2" do
    test "retains the page limit and emits a next cursor when an extra row was loaded" do
      rows = [%{id: "record-1"}, %{id: "record-2"}, %{id: "record-3"}]
      opts = %{cursor_fields: CursorQuery.cursor_fields(), limit: 2}

      assert {[%{id: "record-1"}, %{id: "record-2"}], metadata} = Paginator.metadata(rows, opts)
      assert metadata.limit == 2
      assert metadata.previous_page_cursor == nil
      assert is_binary(metadata.next_page_cursor)
    end
  end

  defp encode_cursor(term),
    do: term |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
end
