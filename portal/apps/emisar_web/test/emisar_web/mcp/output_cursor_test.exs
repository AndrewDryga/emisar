defmodule EmisarWeb.MCP.OutputCursorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{CatalogCursor, OutputCursor}

  test "round-trips a seq only for the exact run and scope" do
    cursor = OutputCursor.encode("scope-a", "run-1", 42)

    assert {:ok, 42} = OutputCursor.decode(cursor, "scope-a", "run-1")

    # Bound to the run: another run's id rejects.
    assert {:error, :invalid_cursor} = OutputCursor.decode(cursor, "scope-a", "run-2")

    # Bound to the credential lineage: another scope rejects.
    assert {:error, :invalid_cursor} = OutputCursor.decode(cursor, "scope-b", "run-1")
  end

  test "seq 0 is the start-of-output seed" do
    cursor = OutputCursor.encode("scope", "run", 0)
    assert {:ok, 0} = OutputCursor.decode(cursor, "scope", "run")
  end

  test "rejects a cursor minted for a different tool" do
    # A recent_runs cursor for the same scope must not decode as an output cursor.
    foreign = CatalogCursor.encode("recent_runs", "scope", %{"run_id" => "run"}, "42")
    assert {:error, :invalid_cursor} = OutputCursor.decode(foreign, "scope", "run")
  end

  test "rejects a non-integer payload, garbage, and nil" do
    # Same tool/scope/filters but a last_key that is not a seq.
    non_seq = CatalogCursor.encode("wait_for_run", "scope", %{"run_id" => "run"}, "not-a-seq")
    assert {:error, :invalid_cursor} = OutputCursor.decode(non_seq, "scope", "run")

    assert {:error, :invalid_cursor} = OutputCursor.decode("garbage", "scope", "run")
    assert {:error, :invalid_cursor} = OutputCursor.decode(nil, "scope", "run")
  end
end
