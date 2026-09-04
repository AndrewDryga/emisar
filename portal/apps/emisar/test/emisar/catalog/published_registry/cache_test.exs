defmodule Emisar.Catalog.PublishedRegistry.CacheTest do
  # The installed snapshot lives in a global `:persistent_term`, so the refresh
  # tests below swap it for a synthetic catalog and restore it afterwards.
  use ExUnit.Case, async: false
  alias Emisar.Catalog.PublishedRegistry.Cache

  @catalog_url "https://registry.emisar.dev/v1/catalog.json"

  # Parsing the bundled catalog costs about a second, so the refresh tests boot
  # once and each swaps (and restores) the global snapshot from there.
  setup_all do
    %{boot: Cache.boot_state()}
  end

  defp catalog_json(id, opts \\ []) do
    Jason.encode!(catalog_document(id, opts))
  end

  defp catalog_document(id, opts) do
    tarball_url =
      Keyword.get(
        opts,
        :tarball_url,
        "https://registry.emisar.dev/v1/#{id}.tar.gz"
      )

    %{
      "schema_version" => 1,
      "packs" => [
        %{
          "id" => id,
          "name" => "#{id} ops",
          "version" => Keyword.get(opts, :version, "0.1.0"),
          "description" => "",
          "vendor" => "emisar",
          "homepage" => "https://github.com/andrewdryga/emisar",
          "source_url" => "https://github.com/andrewdryga/emisar/tree/main/packs/#{id}",
          "content_hash" => "sha256:#{String.duplicate("b", 64)}",
          "tarball_url" => tarball_url,
          "previous_versions" => Keyword.get(opts, :previous_versions, []),
          "retired_below" => Keyword.get(opts, :retired_below),
          "requires" => %{"os" => [], "binaries" => []},
          "detect" => %{"binaries" => [], "processes" => [], "ports" => []},
          "actions" => []
        }
      ]
    }
  end

  describe "evaluate/2" do
    test "a validated fetch under the registry base replaces the catalog" do
      assert {:ok, %{packs: [pack], trust: trust}} =
               Cache.evaluate({:ok, catalog_json("redis")}, @catalog_url)

      assert pack.id == "redis"
      assert trust.current_versions == %{"redis" => "0.1.0"}
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

      assert {:ok, %{packs: [pack]}} = Cache.evaluate({:ok, under_base}, self_host_url)
      assert pack.id == "redis"

      # Our canonical registry.emisar.dev URL is off-base for a self-hoster —
      # the pin follows the configured catalog_url, not a hardcoded base.
      off_base = catalog_json("redis", tarball_url: "https://registry.emisar.dev/v1/redis.tar.gz")

      assert {:keep, message} = Cache.evaluate({:ok, off_base}, self_host_url)
      assert message =~ "not under the registry base"
    end
  end

  describe "boot_state/0" do
    test "a registry that never answers holds what boot installed" do
      test_pid = self()

      put = fn snapshot ->
        send(test_pid, :installed)
        Cache.install_snapshot(snapshot)
      end

      boot = %{Cache.boot_state() | url: @catalog_url, put: put}
      kept = Cache.refresh(boot, {:error, :nxdomain})

      refute_received :installed
      assert kept.source == :bundled
      assert kept.checked_at == nil
      assert kept.loaded_at == boot.loaded_at
      assert Cache.current() != []
    end

    test "a restart onto an installed snapshot keeps it, watermarks and all" do
      installed = Cache.snapshot()
      on_exit(fn -> Cache.install_snapshot(installed) end)

      retired = catalog_json("redis", version: "0.3.0", retired_below: "0.2.0")
      {:ok, remote} = Cache.evaluate({:ok, retired}, @catalog_url)
      Cache.install_snapshot(remote)

      test_pid = self()

      put = fn snapshot ->
        send(test_pid, :installed)
        Cache.install_snapshot(snapshot)
      end

      state = %{Cache.boot_state() | url: @catalog_url, put: put}

      assert state.source == :remote
      assert state.checked_at == nil
      # No digest: the preserved snapshot came from bytes this process never
      # saw, so the next body must be parsed and compared, not byte-matched.
      assert state.digest == nil
      assert Cache.trust_snapshot().retired_below == %{"redis" => "0.2.0"}

      kept = Cache.refresh(state, {:error, :nxdomain})

      refute_received :installed
      assert kept.checked_at == nil
      assert Cache.trust_snapshot().retired_below == %{"redis" => "0.2.0"}
    end
  end

  describe "refresh/2" do
    setup %{boot: boot} do
      installed = Cache.snapshot()
      on_exit(fn -> Cache.install_snapshot(installed) end)

      test_pid = self()

      put = fn snapshot ->
        send(test_pid, :installed)
        Cache.install_snapshot(snapshot)
      end

      # Seed from a synthetic catalog so each test judges swaps and watermarks
      # against a known baseline rather than the real bundled one.
      state = %{boot | url: @catalog_url, put: put}
      state = Cache.refresh(state, {:ok, catalog_json("redis")})
      assert_received :installed

      %{state: state}
    end

    test "a byte-identical body is not swapped in twice", %{state: state} do
      body = catalog_json("nginx")

      loaded = Cache.refresh(state, {:ok, body})
      assert_received :installed

      unchanged = Cache.refresh(loaded, {:ok, body})
      refute_received :installed

      assert unchanged.source == :remote
      assert unchanged.loaded_at == loaded.loaded_at
      assert DateTime.compare(unchanged.checked_at, loaded.checked_at) in [:gt, :eq]
      assert Enum.map(Cache.current(), & &1.id) == ["nginx"]
    end

    test "a body that re-encodes to the same catalog is not swapped in", %{state: state} do
      document = catalog_document("nginx", [])

      loaded = Cache.refresh(state, {:ok, Jason.encode!(document)})
      assert_received :installed

      # Same document, different bytes: the digest moves, the snapshot doesn't.
      unchanged = Cache.refresh(loaded, {:ok, Jason.encode!(document, pretty: true)})

      refute_received :installed
      assert unchanged.digest != loaded.digest
      assert unchanged.loaded_at == loaded.loaded_at
      assert DateTime.compare(unchanged.checked_at, loaded.checked_at) in [:gt, :eq]
    end

    test "a malformed publish holds the last-good catalog", %{state: state} do
      kept = Cache.refresh(state, {:ok, "{garbage"})

      refute_received :installed
      assert kept.digest == state.digest
      assert kept.checked_at == state.checked_at
      assert Enum.map(Cache.current(), & &1.id) == ["redis"]
    end
  end

  describe "boot" do
    test "the running cache is populated from the bundled catalog" do
      # checked_at stays nil until a registry body validates — boot reached no
      # registry, so an alert on its staleness must not fire on a fresh node.
      assert %{
               source: :bundled,
               checked_at: nil,
               loaded_at: %DateTime{},
               count: count
             } = Cache.status()

      assert count > 0
      assert Cache.current() != []
      assert map_size(Cache.trust_snapshot().baseline) > 0
    end
  end
end
