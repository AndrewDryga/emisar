defmodule EmisarWeb.PacksRegistry.CacheTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.PacksRegistry.Cache

  @catalog_url "https://registry.emisar.dev/v1/catalog.json"

  defp catalog_json(id, opts \\ []) do
    tarball_url =
      Keyword.get(
        opts,
        :tarball_url,
        "https://registry.emisar.dev/v1/#{id}.tar.gz"
      )

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
          "tarball_url" => tarball_url,
          "previous_versions" => Keyword.get(opts, :previous_versions, []),
          "requires" => %{"os" => [], "binaries" => []},
          "detect" => %{"binaries" => [], "processes" => [], "ports" => []},
          "actions" => []
        }
      ]
    })
  end

  describe "evaluate/2" do
    test "a validated fetch under the registry base replaces the catalog" do
      assert {:ok, [pack]} = Cache.evaluate({:ok, catalog_json("redis")}, @catalog_url)
      assert pack.id == "redis"
    end

    test "a fetch failure keeps the last-good catalog" do
      assert {:keep, message} = Cache.evaluate({:error, :timeout}, @catalog_url)
      assert message =~ "fetch failed"
    end

    test "a malformed published catalog keeps the last-good catalog" do
      assert {:keep, message} = Cache.evaluate({:ok, "{garbage"}, @catalog_url)
      assert message =~ "rejected published catalog"
    end

    test "a valid but empty published catalog keeps the last-good catalog" do
      empty = Jason.encode!(%{"schema_version" => 1, "packs" => []})
      assert {:keep, message} = Cache.evaluate({:ok, empty}, @catalog_url)
      assert message =~ "no packs"
    end

    test "an off-base tarball_url is rejected on the remote path" do
      off_base = catalog_json("redis", tarball_url: "https://evil.example.com/redis.tar.gz")
      assert {:keep, message} = Cache.evaluate({:ok, off_base}, @catalog_url)
      assert message =~ "not under the registry base"
    end

    test "an off-base tarball_url in previous_versions is rejected" do
      previous = [
        %{
          "version" => "0.0.9",
          "content_hash" => "sha256:#{String.duplicate("c", 64)}",
          "tarball_url" => "https://evil.example.com/redis-old.tar.gz"
        }
      ]

      catalog = catalog_json("redis", previous_versions: previous)
      assert {:keep, message} = Cache.evaluate({:ok, catalog}, @catalog_url)
      assert message =~ "not under the registry base"
    end

    test "a self-host catalog_url override pins tarballs to that base" do
      self_host_url = "https://packs.acme.internal/registry/catalog.json"

      under_base =
        catalog_json("redis", tarball_url: "https://packs.acme.internal/registry/redis.tar.gz")

      assert {:ok, [pack]} = Cache.evaluate({:ok, under_base}, self_host_url)
      assert pack.id == "redis"

      # Our canonical registry.emisar.dev URL is off-base for a self-hoster —
      # the pin follows the configured catalog_url, not a hardcoded base.
      off_base = catalog_json("redis", tarball_url: "https://registry.emisar.dev/v1/redis.tar.gz")

      assert {:keep, message} = Cache.evaluate({:ok, off_base}, self_host_url)
      assert message =~ "not under the registry base"
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
