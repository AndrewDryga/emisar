defmodule EmisarWeb.PacksRegistry.CacheTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.PacksRegistry.Cache

  defp catalog_json(id) do
    Jason.encode!(%{
      "schema_version" => 1,
      "packs" => [
        %{
          "id" => id,
          "name" => "#{id} ops",
          "version" => "0.1.0",
          "description" => "",
          "vendor" => "emisar",
          "homepage" => "https://github.com/andrewdryga/emisar",
          "source_url" => "https://github.com/andrewdryga/emisar/tree/main/packs/#{id}",
          "content_hash" => "sha256:#{String.duplicate("b", 64)}",
          "tarball_url" => "https://storage.googleapis.com/emisar-pack-registry/#{id}.tar.gz",
          "requires" => %{"os" => [], "binaries" => []},
          "detect" => %{"binaries" => [], "processes" => [], "ports" => []},
          "actions" => []
        }
      ]
    })
  end

  describe "evaluate/1" do
    test "a validated fetch replaces the catalog" do
      assert {:ok, [pack]} = Cache.evaluate({:ok, catalog_json("redis")})
      assert pack.id == "redis"
    end

    test "a fetch failure keeps the last-good catalog" do
      assert {:keep, message} = Cache.evaluate({:error, :timeout})
      assert message =~ "fetch failed"
    end

    test "a malformed published catalog keeps the last-good catalog" do
      assert {:keep, message} = Cache.evaluate({:ok, "{garbage"})
      assert message =~ "rejected published catalog"
    end
  end

  describe "boot" do
    test "the running cache is populated from the bundled catalog" do
      assert %{source: :bundled, count: count} = Cache.status()
      assert count > 0
      assert Cache.current() != []
    end
  end
end
