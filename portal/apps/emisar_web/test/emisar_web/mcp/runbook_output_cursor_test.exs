defmodule EmisarWeb.MCP.RunbookOutputCursorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.{CatalogCursor, RunbookOutputCursor}

  test "round-trips one execution position and rejects another execution or scope" do
    cursor = RunbookOutputCursor.encode("scope-a", "execution-a", 42)

    assert RunbookOutputCursor.decode(cursor, "scope-a", "execution-a") == {:ok, 42}

    assert RunbookOutputCursor.decode(cursor, "scope-a", "execution-b") ==
             {:error, :invalid_cursor}

    assert RunbookOutputCursor.decode(cursor, "scope-b", "execution-a") ==
             {:error, :invalid_cursor}
  end

  test "rejects another cursor mode and malformed positions" do
    foreign = CatalogCursor.encode("wait_for_run", "scope", %{"run_id" => "run"}, "0:0:0")

    assert RunbookOutputCursor.decode(foreign, "scope", "execution") ==
             {:error, :invalid_cursor}

    for position <- ["-1", "1.0", "nope"] do
      cursor =
        CatalogCursor.encode(
          "wait_for_run",
          "scope",
          %{"mode" => "runbook_outputs", "runbook_execution_id" => "execution"},
          position
        )

      assert RunbookOutputCursor.decode(cursor, "scope", "execution") ==
               {:error, :invalid_cursor}
    end
  end
end
