defmodule Emisar.Catalog.PackBaselineTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PackBaseline

  describe "lookup/2" do
    test "returns the canonical hash for a shipped (pack_id, version)" do
      {{pack_id, version}, hash} = PackBaseline.all() |> Enum.at(0)

      assert PackBaseline.lookup(pack_id, version) == hash
    end

    test "returns nil for a pack the release does not ship" do
      assert PackBaseline.lookup("definitely-not-a-real-pack", "9.9.9") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.lookup(nil, "0.1.0") == nil
      assert PackBaseline.lookup("redis", nil) == nil
    end
  end

  describe "current_version/1" do
    test "returns the shipped current version for a pack, and it parses as SemVer" do
      {{pack_id, _version}, _hash} = PackBaseline.all() |> Enum.at(0)

      current = PackBaseline.current_version(pack_id)
      assert is_binary(current)
      assert {:ok, _} = Version.parse(current)
      # The current version is the top of that pack's trust window — never below
      # nothing, and (with no shipped watermark) never retired.
      refute PackBaseline.retired?(pack_id, current)
    end

    test "returns nil for a pack the release does not ship" do
      assert PackBaseline.current_version("definitely-not-a-real-pack") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.current_version(nil) == nil
    end
  end

  describe "retired?/2" do
    # No shipped pack carries a retirement watermark yet (the window and
    # watermarks fill as versions bump through publish), so this also locks
    # "a shipping catalog never retires its own current" — a current version
    # is never strictly below its own retire watermark.
    test "is false for every version in the shipped baseline" do
      for {{pack_id, version}, _hash} <- PackBaseline.all() do
        refute PackBaseline.retired?(pack_id, version),
               "shipped #{pack_id}@#{version} must not be retired"
      end
    end

    test "is false for a pack the release does not ship" do
      refute PackBaseline.retired?("definitely-not-a-real-pack", "9.9.9")
    end

    test "is false for non-binary arguments" do
      refute PackBaseline.retired?(nil, "0.1.0")
      refute PackBaseline.retired?("redis", nil)
    end
  end

  describe "version_retired?/2" do
    test "nothing is retired when the watermark is nil" do
      refute PackBaseline.version_retired?("0.1.0", nil)
      refute PackBaseline.version_retired?("not-a-version", nil)
    end

    test "a version strictly below the watermark is retired" do
      assert PackBaseline.version_retired?("0.1.0", "0.2.0")
      assert PackBaseline.version_retired?("0.1.9", "0.2.0")
    end

    test "the watermark version itself is not retired" do
      refute PackBaseline.version_retired?("0.2.0", "0.2.0")
    end

    test "a version above the watermark is not retired" do
      refute PackBaseline.version_retired?("0.3.0", "0.2.0")
      refute PackBaseline.version_retired?("1.0.0", "0.2.0")
    end

    test "an unparseable advertised version with a live watermark is retired (fail-closed)" do
      assert PackBaseline.version_retired?("not-a-version", "0.2.0")
      assert PackBaseline.version_retired?("", "0.2.0")
    end
  end

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

  describe "retired_below/0" do
    test "maps every retirement watermark to a parseable version" do
      for {pack_id, watermark} <- PackBaseline.retired_below() do
        assert is_binary(pack_id) and pack_id != ""
        assert {:ok, _} = Version.parse(watermark)
      end
    end
  end
end
