defmodule Emisar.Repo.PaginatorTest do
  use ExUnit.Case, async: true
  alias Emisar.Repo.Paginator

  defmodule CursorQuery do
    def cursor_fields, do: [{:records, :asc, :id}]
  end

  defmodule WideCursorQuery do
    def cursor_fields, do: [{:records, :asc, :name}, {:records, :asc, :id}]
  end

  defmodule TypedCursorQuery do
    def cursor_fields,
      do: [
        {:records, :asc, :name},
        {:records, :asc, :position},
        {:records, :asc, :score},
        {:records, :asc, :archived},
        {:records, :asc, :occurred_at},
        {:records, :asc, :recorded_at},
        {:records, :asc, :effective_on},
        {:records, :asc, :starts_at}
      ]
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

    test "round-trips every supported value type, in both directions" do
      record = typed_record()

      values = [
        record.name,
        record.position,
        record.score,
        record.archived,
        record.occurred_at,
        record.recorded_at,
        record.effective_on,
        record.starts_at
      ]

      for direction <- [:after, :before] do
        cursor = Paginator.encode_cursor(direction, TypedCursorQuery.cursor_fields(), record)

        assert {:ok, %{direction: ^direction, values: ^values}} =
                 Paginator.init(TypedCursorQuery, [], cursor: cursor)
      end
    end

    test "rejects a cursor with an unsupported direction or value count" do
      unsupported_direction = encode_cursor(["sideways", [["binary", "record-1"]]])
      no_values = encode_cursor(["after", []])
      extra_value = encode_cursor(["after", [["binary", "record-1"], ["binary", "record-2"]]])

      assert Paginator.init(CursorQuery, [], cursor: unsupported_direction) ==
               {:error, :invalid_cursor}

      assert Paginator.init(CursorQuery, [], cursor: no_values) == {:error, :invalid_cursor}
      assert Paginator.init(CursorQuery, [], cursor: extra_value) == {:error, :invalid_cursor}
    end

    test "rejects malformed Base64 and malformed JSON" do
      not_base64 = "record-1!!"
      not_json = Base.url_encode64("{\"after\": ", padding: false)

      assert Paginator.init(CursorQuery, [], cursor: not_base64) == {:error, :invalid_cursor}
      assert Paginator.init(CursorQuery, [], cursor: not_json) == {:error, :invalid_cursor}
      assert Paginator.init(CursorQuery, [], cursor: :after) == {:error, :invalid_cursor}
    end

    test "rejects an outer envelope that is not the exact direction/values pair" do
      envelopes = [
        "after",
        ["after"],
        ["after", [["binary", "record-1"]], "extra"],
        %{"direction" => "after", "values" => [["binary", "record-1"]]},
        ["after", %{"0" => ["binary", "record-1"]}]
      ]

      for envelope <- envelopes do
        cursor = encode_cursor(envelope)

        assert Paginator.init(CursorQuery, [], cursor: cursor) == {:error, :invalid_cursor},
               "accepted outer envelope #{inspect(envelope)}"
      end
    end

    test "rejects leaves with an unknown tag, a wrong shape, or a mismatched value type" do
      leaves = [
        "record-1",
        nil,
        ["record-1"],
        ["binary", "record-1", "record-2"],
        ["term", "record-1"],
        [["binary"], "record-1"],
        %{"binary" => "record-1"},
        ["binary", 1],
        ["binary", nil],
        ["integer", "1"],
        ["integer", 1.0],
        ["float", 1],
        ["boolean", "true"],
        ["datetime", "1754302272131415000"],
        ["datetime", 10_000_000_000_000_000_000_000_000_000_000],
        ["naive_datetime", 0],
        ["naive_datetime", "2026-08-04"],
        ["date", "2026-13-45"],
        ["time", "25:00:00"]
      ]

      for leaf <- leaves do
        cursor = encode_cursor(["after", [leaf]])

        assert Paginator.init(CursorQuery, [], cursor: cursor) == {:error, :invalid_cursor},
               "accepted leaf #{inspect(leaf)}"
      end
    end

    test "rejects an Erlang term cursor, including a small one that expands to a large term" do
      etf = encode_term({:after, [{:t, "record-1"}]})
      compressed_etf = encode_term(List.duplicate("record-1", 100_000), compressed: 9)

      assert byte_size(compressed_etf) < 10_924
      assert Paginator.init(CursorQuery, [], cursor: etf) == {:error, :invalid_cursor}
      assert Paginator.init(CursorQuery, [], cursor: compressed_etf) == {:error, :invalid_cursor}
    end

    test "rejects an oversized cursor by its encoded and its decoded length" do
      too_long = String.duplicate("a", 10_925)
      # Base64 of 8193 bytes is exactly 10924 characters, so this one clears the
      # encoded cap and is stopped by the decoded cap alone.
      over_decoded_cap = Base.url_encode64(String.duplicate("a", 8193), padding: false)

      assert byte_size(over_decoded_cap) == 10_924
      assert Paginator.init(CursorQuery, [], cursor: too_long) == {:error, :invalid_cursor}

      assert Paginator.init(CursorQuery, [], cursor: over_decoded_cap) ==
               {:error, :invalid_cursor}
    end
  end

  describe "encode_cursor/3" do
    test "raises rather than emitting a cursor for a value with no cursor type" do
      assert_raise ArgumentError, ~r/has no cursor type/, fn ->
        Paginator.encode_cursor(:after, CursorQuery.cursor_fields(), %{id: nil})
      end

      assert_raise ArgumentError, ~r/has no cursor type/, fn ->
        Paginator.encode_cursor(:after, CursorQuery.cursor_fields(), %{id: %{nested: "map"}})
      end
    end

    test "raises rather than emitting a cursor that could never be decoded back" do
      oversized = %{id: String.duplicate("a", 8_192)}

      assert_raise ArgumentError, ~r/exceeds the 8192-byte keyset cursor cap/, fn ->
        Paginator.encode_cursor(:after, CursorQuery.cursor_fields(), oversized)
      end
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

    test "the emitted cursors decode back to their own direction and boundary row" do
      rows = [%{id: "record-1"}, %{id: "record-2"}, %{id: "record-3"}]
      opts = %{direction: :after, cursor_fields: CursorQuery.cursor_fields(), limit: 2}

      assert {[%{id: "record-1"}, %{id: "record-2"}], metadata} = Paginator.metadata(rows, opts)

      assert {:ok, %{direction: :before, values: ["record-1"]}} =
               Paginator.init(CursorQuery, [], cursor: metadata.previous_page_cursor)

      assert {:ok, %{direction: :after, values: ["record-2"]}} =
               Paginator.init(CursorQuery, [], cursor: metadata.next_page_cursor)
    end
  end

  defp typed_record do
    %{
      name: "record-1",
      position: 42,
      score: 1.5,
      archived: false,
      occurred_at: DateTime.from_naive!(~N[2026-08-04 10:11:12.131415], "Etc/UTC"),
      recorded_at: ~N[2026-08-04 10:11:12.131415],
      effective_on: ~D[2026-08-04],
      starts_at: ~T[10:11:12.131415]
    }
  end

  defp encode_cursor(term), do: term |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp encode_term(term, opts \\ []),
    do: term |> :erlang.term_to_binary(opts) |> Base.url_encode64(padding: false)
end
