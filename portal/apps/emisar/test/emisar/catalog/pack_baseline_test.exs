defmodule Emisar.Catalog.PackBaselineTest do
  # The published snapshot lives in a global `:persistent_term`, so the tests
  # that install a synthetic catalog swap it and restore it afterwards.
  use Emisar.DataCase, async: false
  alias Emisar.{Catalog, Fixtures}
  alias Emisar.Catalog.PackBaseline
  alias Emisar.Catalog.PublishedRegistry.Cache

  @catalog_url "https://registry.emisar.dev/v1/catalog.json"
  @current_hash "sha256:#{String.duplicate("a", 64)}"
  @previous_hash "sha256:#{String.duplicate("b", 64)}"
  @unretained_hash "sha256:#{String.duplicate("c", 64)}"

  # A two-pack catalog with a retirement watermark, one previous version whose
  # descriptors the catalog still carries, and one it no longer does.
  defp published_catalog do
    %{
      "schema_version" => 1,
      "packs" => [
        pack("redis", %{
          "version" => "0.3.0",
          "retired_below" => "0.2.0",
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
        }),
        pack("nginx", %{"version" => "1.0.0"})
      ]
    }
  end

  defp pack(id, overrides) do
    Map.merge(
      %{
        "id" => id,
        "name" => "#{id} operations",
        "version" => "0.1.0",
        "description" => "Ops for #{id}.",
        "vendor" => "emisar",
        "homepage" => "https://github.com/andrewdryga/emisar",
        "source_url" => "https://github.com/andrewdryga/emisar/tree/main/packs/#{id}",
        "content_hash" => @current_hash,
        "tarball_url" => "https://registry.emisar.dev/v1/packs/#{id}/x.tar.gz",
        "requires" => %{"os" => ["linux"], "binaries" => []},
        "detect" => %{"binaries" => [], "processes" => [], "ports" => []},
        "actions" => [action("#{id}.info")]
      },
      overrides
    )
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
      "args" => [],
      "examples" => [],
      "search_terms" => []
    }
  end

  setup do
    installed = Cache.snapshot()
    on_exit(fn -> Cache.install_snapshot(installed) end)

    {:ok, snapshot} = Cache.evaluate({:ok, Jason.encode!(published_catalog())}, @catalog_url)
    Cache.install_snapshot(snapshot)
    :ok
  end

  describe "lookup/2" do
    test "returns the canonical hash for a published (pack_id, version)" do
      assert PackBaseline.lookup("redis", "0.3.0") == @current_hash
    end

    test "returns the canonical hash for a retained previous version" do
      assert PackBaseline.lookup("redis", "0.2.0") == @previous_hash
    end

    test "returns nil for a pack the registry does not publish" do
      assert PackBaseline.lookup("definitely-not-a-real-pack", "9.9.9") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.lookup(nil, "0.1.0") == nil
      assert PackBaseline.lookup("redis", nil) == nil
    end
  end

  describe "manifest/3" do
    test "returns the complete manifest for an exact published (pack_id, version, hash)" do
      manifest = PackBaseline.manifest("redis", "0.3.0", @current_hash)
      assert Map.keys(manifest["actions"]) == ["redis.info"]
    end

    test "returns the retained manifest of a previous version" do
      manifest = PackBaseline.manifest("redis", "0.2.0", @previous_hash)
      assert Map.keys(manifest["actions"]) == ["redis.legacy"]
    end

    test "returns nil for a previous version whose descriptors are not retained" do
      assert PackBaseline.manifest("redis", "0.2.1", @unretained_hash) == nil
    end

    test "returns nil for a hash the version does not carry" do
      assert PackBaseline.manifest("redis", "0.3.0", @previous_hash) == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.manifest(nil, "0.3.0", @current_hash) == nil
    end
  end

  describe "observe_state/2 trust reconciliation" do
    test "a baseline entry without a release manifest stays pending" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      Fixtures.Catalog.create_observed_pack_version(
        account_id: account.id,
        pack_id: "redis",
        version: "0.2.1",
        pending_hash: @unretained_hash
      )

      payload = %{
        "hostname" => "host-1",
        "version" => "0.1.0",
        "labels" => %{"env" => "test"},
        "packs" => %{
          "redis" => %{"version" => "0.2.1", "hash" => @unretained_hash}
        },
        "actions" => []
      }

      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.hash == nil
      assert pack_version.pending_hash == @unretained_hash
      assert pack_version.trusted_manifest == nil
    end
  end

  describe "current_version/1" do
    test "returns the published current version for a pack" do
      assert PackBaseline.current_version("redis") == "0.3.0"
      assert PackBaseline.current_version("nginx") == "1.0.0"
    end

    test "returns nil for a pack the registry does not publish" do
      assert PackBaseline.current_version("definitely-not-a-real-pack") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.current_version(nil) == nil
    end
  end

  describe "previous_version/1" do
    test "returns the newest trusted version strictly below the current one" do
      # redis publishes 0.3.0 with 0.2.0 and 0.2.1 still in the window.
      assert PackBaseline.previous_version("redis") == "0.2.1"
    end

    test "returns nil when the window holds only the current version" do
      assert PackBaseline.previous_version("nginx") == nil
    end

    test "returns nil for a pack the registry does not publish" do
      assert PackBaseline.previous_version("definitely-not-a-real-pack") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.previous_version(nil) == nil
    end
  end

  describe "newer_version/2" do
    test "returns the current version when the advertised one is strictly behind" do
      assert PackBaseline.newer_version("redis", "0.2.0") == "0.3.0"
    end

    test "returns nil when the advertised version already is the current one" do
      assert PackBaseline.newer_version("redis", "0.3.0") == nil
    end

    test "returns nil when the advertised version is ahead of the current one" do
      assert PackBaseline.newer_version("redis", "999.0.0") == nil
    end

    test "returns nil for a pack the registry does not publish" do
      assert PackBaseline.newer_version("definitely-not-a-real-pack", "0.0.0") == nil
    end

    test "returns nil (no false hint) for an unparseable advertised version" do
      # The OPPOSITE fail direction from retirement: junk yields nil, so a garbage
      # runner version never surfaces a bogus "update available".
      assert PackBaseline.newer_version("redis", "not-a-semver") == nil
    end

    test "returns nil for non-binary arguments" do
      assert PackBaseline.newer_version(nil, "0.0.0") == nil
      assert PackBaseline.newer_version("redis", nil) == nil
    end
  end

  describe "retired?/2" do
    test "is true below the published watermark and false at or above it" do
      assert PackBaseline.retired?("redis", "0.1.9")
      refute PackBaseline.retired?("redis", "0.2.0")
      refute PackBaseline.retired?("redis", "0.3.0")
    end

    test "is false for a pack with no watermark" do
      refute PackBaseline.retired?("nginx", "0.0.1")
    end

    test "is false for a pack the registry does not publish" do
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
    test "carries every published version, current and retained" do
      assert PackBaseline.all() == %{
               {"redis", "0.3.0"} => @current_hash,
               {"redis", "0.2.0"} => @previous_hash,
               {"redis", "0.2.1"} => @unretained_hash,
               {"nginx", "1.0.0"} => @current_hash
             }
    end
  end

  describe "all_manifests/0" do
    test "carries a manifest per exact version+hash the catalog retains actions for" do
      assert PackBaseline.all_manifests() |> Map.keys() |> Enum.sort() == [
               {"nginx", "1.0.0", @current_hash},
               {"redis", "0.2.0", @previous_hash},
               {"redis", "0.3.0", @current_hash}
             ]
    end
  end

  describe "retired_below/0" do
    test "carries only the packs the catalog watermarks" do
      assert PackBaseline.retired_below() == %{"redis" => "0.2.0"}
    end
  end

  describe "the published snapshot" do
    test "the readers follow a registry refresh, without a redeploy" do
      refute PackBaseline.retired?("nginx", "0.9.0")
      assert PackBaseline.lookup("nginx", "2.0.0") == nil

      refreshed = %{
        "schema_version" => 1,
        "packs" => [pack("nginx", %{"version" => "2.0.0", "retired_below" => "1.0.0"})]
      }

      {:ok, snapshot} = Cache.evaluate({:ok, Jason.encode!(refreshed)}, @catalog_url)
      Cache.install_snapshot(snapshot)

      assert PackBaseline.retired?("nginx", "0.9.0")
      assert PackBaseline.lookup("nginx", "2.0.0") == @current_hash
      assert PackBaseline.current_version("nginx") == "2.0.0"
    end
  end
end
