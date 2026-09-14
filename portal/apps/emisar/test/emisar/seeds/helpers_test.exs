defmodule Emisar.Seeds.HelpersTest do
  # The seed helpers live under priv/repo/seeds, outside the compiled app, and
  # read the published snapshot from a global `:persistent_term`, so this suite
  # loads them once and swaps a synthetic catalog in around each test.
  use ExUnit.Case, async: false
  alias Emisar.Catalog.PublishedRegistry.Cache

  @catalog_url "https://registry.emisar.dev/v1/catalog.json"
  @current_hash "sha256:#{String.duplicate("a", 64)}"
  @previous_hash "sha256:#{String.duplicate("b", 64)}"
  @unretained_hash "sha256:#{String.duplicate("c", 64)}"

  # One pack at 0.3.0 with two windowed previous versions: 0.2.0 still carries
  # its descriptors, 0.2.1 predates descriptor retention.
  defp published_catalog do
    %{
      "schema_version" => 1,
      "packs" => [
        %{
          "id" => "redis",
          "name" => "redis operations",
          "version" => "0.3.0",
          "description" => "Ops for redis.",
          "vendor" => "emisar",
          "homepage" => "https://github.com/andrewdryga/emisar",
          "source_url" => "https://github.com/andrewdryga/emisar/tree/main/packs/redis",
          "content_hash" => @current_hash,
          "tarball_url" => "https://registry.emisar.dev/v1/packs/redis/0.3.0/x.tar.gz",
          "requires" => %{"os" => ["linux"], "binaries" => []},
          "detect" => %{"binaries" => [], "processes" => [], "ports" => []},
          "actions" => [action("redis.info")],
          "previous_versions" => [
            %{
              "version" => "0.2.0",
              "content_hash" => @previous_hash,
              "tarball_url" => "https://registry.emisar.dev/v1/packs/redis/0.2.0/x.tar.gz",
              "actions" => [action("redis.legacy")]
            },
            %{
              "version" => "0.2.1",
              "content_hash" => @unretained_hash,
              "tarball_url" => "https://registry.emisar.dev/v1/packs/redis/0.2.1/x.tar.gz"
            }
          ]
        }
      ]
    }
  end

  defp action(id) do
    %{
      "id" => id,
      "title" => "Action #{id}",
      "summary" => "What #{id} does.",
      "description" => "What #{id} does, at length.",
      "kind" => "exec",
      "risk" => "low",
      "side_effects" => ["Read-only."],
      "args" => [%{"name" => "key", "type" => "string", "required" => true}],
      "examples" => [],
      "search_terms" => []
    }
  end

  setup_all do
    helpers = Emisar.Seeds.Helpers

    unless Code.ensure_loaded?(helpers) do
      Code.require_file(Application.app_dir(:emisar, "priv/repo/seeds/helpers.exs"))
    end

    {:ok, helpers: helpers}
  end

  setup do
    installed = Cache.snapshot()
    on_exit(fn -> Cache.install_snapshot(installed) end)

    {:ok, snapshot} = Cache.evaluate({:ok, Jason.encode!(published_catalog())}, @catalog_url)
    Cache.install_snapshot(snapshot)
    :ok
  end

  describe "baseline_action_descriptors/2" do
    test "reads the current version when none is given", %{helpers: helpers} do
      assert helpers.baseline_action_descriptors("redis") == [
               %{
                 "id" => "redis.info",
                 "pack_id" => "redis",
                 "title" => "Action redis.info",
                 "summary" => "What redis.info does.",
                 "description" => "What redis.info does, at length.",
                 "kind" => "exec",
                 "risk" => "low",
                 "side_effects" => ["Read-only."],
                 "args" => [%{"name" => "key", "type" => "string", "required" => true}],
                 "examples" => [],
                 "search_terms" => []
               }
             ]
    end

    test "reads the retained manifest of the given previous version", %{helpers: helpers} do
      assert [%{"id" => "redis.legacy", "pack_id" => "redis"}] =
               helpers.baseline_action_descriptors("redis", "0.2.0")
    end

    test "raises when the given version retains no descriptors", %{helpers: helpers} do
      assert_raise RuntimeError, "shipped pack redis 0.2.1 retains no action descriptors", fn ->
        helpers.baseline_action_descriptors("redis", "0.2.1")
      end
    end

    test "raises for a version outside the trust window", %{helpers: helpers} do
      assert_raise RuntimeError, "missing shipped-pack baseline for redis 0.1.0", fn ->
        helpers.baseline_action_descriptors("redis", "0.1.0")
      end
    end

    test "raises for a pack the registry does not publish", %{helpers: helpers} do
      assert_raise RuntimeError, "missing current shipped pack version for nginx", fn ->
        helpers.baseline_action_descriptors("nginx")
      end
    end
  end

  describe "baseline_action_descriptor/3" do
    test "finds the action at the given version, not the current one", %{helpers: helpers} do
      assert %{"id" => "redis.legacy"} =
               helpers.baseline_action_descriptor("redis", "redis.legacy", "0.2.0")

      message = "missing shipped action redis.legacy in pack redis (current)"

      assert_raise RuntimeError, message, fn ->
        helpers.baseline_action_descriptor("redis", "redis.legacy")
      end
    end

    test "names the version when the action is missing there", %{helpers: helpers} do
      assert_raise RuntimeError, "missing shipped action redis.info in pack redis 0.2.0", fn ->
        helpers.baseline_action_descriptor("redis", "redis.info", "0.2.0")
      end
    end
  end
end
