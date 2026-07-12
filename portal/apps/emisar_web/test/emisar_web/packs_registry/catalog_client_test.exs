defmodule EmisarWeb.PacksRegistry.CatalogClientTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.PacksRegistry.CatalogClient

  describe "fetch/1" do
    test "returns {:error, reason} on a transport failure instead of crashing" do
      # `.invalid` is guaranteed non-resolvable (RFC 6761), so the fetch hits a
      # transport error — the shape Finch.stream_while reports as a 3-tuple.
      # Matching only {:error, reason} used to crash the Cache with a
      # CaseClauseError; the caller must get a plain {:error, reason} back.
      assert {:error, _reason} =
               CatalogClient.fetch("http://registry.invalid/v1/catalog.json")
    end
  end
end
