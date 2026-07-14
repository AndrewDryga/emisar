defmodule EmisarWeb.MCP.CatalogCursorTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.CatalogCursor

  test "round-trips only for the exact tool, scope, and filters" do
    filters = %{"availability" => "all", "pack_id" => nil}
    cursor = CatalogCursor.encode("list_packs", "scope-a", filters, "demo@1")

    assert {:ok, "demo@1"} =
             CatalogCursor.decode(cursor, "list_packs", "scope-a", filters)

    assert {:error, :invalid_cursor} =
             CatalogCursor.decode(cursor, "list_runners", "scope-a", filters)

    assert {:error, :invalid_cursor} =
             CatalogCursor.decode(cursor, "list_packs", "scope-b", filters)

    assert {:error, :invalid_cursor} =
             CatalogCursor.decode(cursor, "list_packs", "scope-a", %{
               "availability" => "executable"
             })
  end

  test "rejects tampering and oversized cursors" do
    cursor = CatalogCursor.encode("list_packs", "scope", %{}, "last")
    [protected, payload, signature] = String.split(cursor, ".")
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    last = :binary.last(signature)
    {index, 1} = :binary.match(alphabet, <<last>>)
    alternate_index = div(index, 4) * 4 + rem(index + 1, 4)
    alternate = binary_part(alphabet, alternate_index, 1)

    noncanonical_signature =
      binary_part(signature, 0, byte_size(signature) - 1) <> alternate

    tampered = Enum.join([protected, payload, noncanonical_signature], ".")

    assert Base.url_decode64!(signature, padding: false) ==
             Base.url_decode64!(noncanonical_signature, padding: false)

    assert {:error, :invalid_cursor} =
             CatalogCursor.decode(tampered, "list_packs", "scope", %{})

    assert {:error, :invalid_cursor} =
             CatalogCursor.decode(String.duplicate("x", 4_097), "list_packs", "scope", %{})
  end
end
