defmodule Emisar.Catalog.PackBaselineTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PackBaseline

  describe "all/0" do
    test "is populated from the shipped catalog with well-formed sha256 hashes" do
      baseline = PackBaseline.all()

      assert map_size(baseline) > 0

      for {{pack_id, version}, hash} <- baseline do
        assert is_binary(pack_id) and pack_id != ""
        assert is_binary(version) and version != ""
        assert hash =~ ~r/^sha256:[0-9a-f]{64}$/, "bad baseline hash for #{pack_id}@#{version}"
      end
    end
  end

  describe "lookup/2" do
    test "returns the canonical hash for a shipped (pack_id, version)" do
      {{pack_id, version}, hash} = PackBaseline.all() |> Enum.at(0)

      assert PackBaseline.lookup(pack_id, version) == hash
    end

    test "returns nil for a pack the release does not ship" do
      assert PackBaseline.lookup("definitely-not-a-real-pack", "9.9.9") == nil
    end
  end
end
