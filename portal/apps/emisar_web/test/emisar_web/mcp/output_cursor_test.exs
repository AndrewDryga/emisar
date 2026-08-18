defmodule EmisarWeb.MCP.OutputCursorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{CatalogCursor, OutputCursor}

  test "round-trips a {seq, offset, remaining} only for the exact run and scope" do
    cursor = OutputCursor.encode("scope-a", "run-1", 42, 7, 3)

    assert OutputCursor.decode(cursor, "scope-a", "run-1") === {:ok, {42, 7, 3}}

    # Bound to the run: another run's id rejects.
    assert OutputCursor.decode(cursor, "scope-a", "run-2") == {:error, :invalid_cursor}

    # Bound to the credential lineage: another scope rejects.
    assert OutputCursor.decode(cursor, "scope-b", "run-1") == {:error, :invalid_cursor}
  end

  test "{0, 0, _} is the start-of-output seed" do
    cursor = OutputCursor.encode("scope", "run", 0, 0, 0)
    assert OutputCursor.decode(cursor, "scope", "run") === {:ok, {0, 0, 0}}
  end

  test "rejects a cursor minted for a different tool" do
    # A recent_runs cursor for the same scope must not decode as an output cursor.
    foreign = CatalogCursor.encode("recent_runs", "scope", %{"run_id" => "run"}, "42:0:0")
    assert OutputCursor.decode(foreign, "scope", "run") == {:error, :invalid_cursor}
  end

  test "rejects a malformed position, garbage, and nil" do
    # Same tool/scope/filters but a last_key that is not a seq:offset:remaining triple.
    for bad_key <- ["not-a-triple", "12", "12:0", "12:0:", "12:0:x", "-1:0:0", "12:0:-1"] do
      bad = CatalogCursor.encode("wait_for_run", "scope", %{"run_id" => "run"}, bad_key)
      assert OutputCursor.decode(bad, "scope", "run") == {:error, :invalid_cursor}
    end

    assert OutputCursor.decode("garbage", "scope", "run") == {:error, :invalid_cursor}
    assert OutputCursor.decode(nil, "scope", "run") == {:error, :invalid_cursor}
  end
end
