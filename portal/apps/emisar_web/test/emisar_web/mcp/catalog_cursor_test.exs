defmodule EmisarWeb.MCP.CatalogCursorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.CatalogCursor

  test "round-trips only for the exact tool, scope, and filters" do
    filters = %{"availability" => "all", "pack_id" => nil}
    cursor = CatalogCursor.encode("list_packs", "scope-a", filters, "demo@1")

    assert CatalogCursor.decode(cursor, "list_packs", "scope-a", filters) == {:ok, "demo@1"}

    assert CatalogCursor.decode(cursor, "list_runners", "scope-a", filters) ==
             {:error, :invalid_cursor}

    assert CatalogCursor.decode(cursor, "list_packs", "scope-b", filters) ==
             {:error, :invalid_cursor}

    assert CatalogCursor.decode(cursor, "list_packs", "scope-a", %{
             "availability" => "executable"
           }) == {:error, :invalid_cursor}
  end

  test "rejects a re-signed payload swapped onto another cursor's signature" do
    cursor = CatalogCursor.encode("list_packs", "scope", %{}, "last")
    forged = CatalogCursor.encode("list_packs", "scope", %{}, "forged")
    [protected, _payload, signature] = String.split(cursor, ".")
    [_protected, forged_payload, _signature] = String.split(forged, ".")
    tampered = Enum.join([protected, forged_payload, signature], ".")

    assert CatalogCursor.decode(tampered, "list_packs", "scope", %{}) == {:error, :invalid_cursor}
  end

  test "rejects an oversized cursor" do
    assert CatalogCursor.decode(String.duplicate("x", 4_097), "list_packs", "scope", %{}) ==
             {:error, :invalid_cursor}
  end
end
