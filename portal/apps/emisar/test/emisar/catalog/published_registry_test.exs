defmodule Emisar.Catalog.PublishedRegistryTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PublishedRegistry

  describe "list/0" do
    test "returns alphabetically sorted packs" do
      ids = PublishedRegistry.list() |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
    end

    test "every pack lists at least one action and action ids are unique across the catalog" do
      packs = PublishedRegistry.list()
      assert packs != []

      all_action_ids =
        for pack <- packs, action <- pack.actions do
          assert pack.actions != [], "pack #{pack.id} has no actions"
          action.id
        end

      assert all_action_ids == Enum.uniq(all_action_ids),
             "duplicate action id across the catalog"
    end

    test "every pack has a well-formed sha256 content hash" do
      for pack <- PublishedRegistry.list() do
        assert pack.content_hash =~ ~r/^sha256:[0-9a-f]{64}$/,
               "bad content_hash for #{pack.id}: #{inspect(pack.content_hash)}"
      end
    end

    # Golden values captured from the Go runner's `emisar pack validate`
    # (runner/internal/packs computePackHash). If a pack's bytes change,
    # both the Go hash and this expectation must move together — a
    # mismatch here means the portal's Elixir hash has drifted from the
    # runner's, which would make every `--hash` install fail for users.
    # redis is exec-only; cassandra includes a script-kind action, so
    # the pair covers both hash code paths.
    test "content_hash matches the Go runner byte-for-byte (golden values)" do
      assert PublishedRegistry.get("redis").content_hash ==
               "sha256:1231006a60b01d8712b6874c57ec6407112a20183236680b5a1732b8f2649b12"

      assert PublishedRegistry.get("cassandra").content_hash ==
               "sha256:233c8f73bf3f859559e503f60f13edf723174f31f6c186e47c40137a68657454"
    end
  end

  describe "pack_count/0" do
    test "counts every published pack" do
      assert PublishedRegistry.pack_count() == length(PublishedRegistry.list())
    end
  end

  describe "action_count/0" do
    test "counts every declared action" do
      expected = PublishedRegistry.list() |> Enum.map(&length(&1.actions)) |> Enum.sum()
      assert PublishedRegistry.action_count() == expected
    end
  end

  describe "suggest_index/0" do
    test "carries pack-authored detect evidence and omits packs that declare none" do
      by_id = Map.new(PublishedRegistry.suggest_index(), &{&1.id, &1})

      # Authored process/port evidence reaches the runner unchanged.
      grafana = by_id["grafana"]
      assert "grafana-server" in grafana.detect.processes
      # grafana detects by process only — :3000 is shared with Node/dev apps.
      assert grafana.detect.ports == []
      assert "consul" in by_id["consul"].detect.processes
      assert 8500 in by_id["consul"].detect.ports
      assert "postgres" in by_id["postgres"].detect.processes
      assert 5432 in by_id["postgres"].detect.ports
      assert "dockerd" in by_id["docker"].detect.processes

      # An authored binary IS the pack's own evidence, so it survives.
      assert by_id["nic"].detect.binaries == ["ethtool"]

      # A runtime requirement never becomes one: curl, consul, psql, and docker
      # are clients these packs run, not proof the service lives on this host.
      for id <- ~w(grafana consul postgres docker) do
        assert by_id[id].detect.binaries == [],
               "#{id} must not turn a required client into a binary signal"
      end

      # No authored evidence → nothing to suggest on, so the pack is omitted
      # rather than guessed at from its dependencies, whether that dependency
      # looks generic (curl, jq), local (git), or remote (a BMC, GitHub, a
      # cluster, remote infra, SNMP agents). dell-ipmi suggested on a GCP box
      # that happened to ship ipmitool was the bug this guards.
      undetectable =
        ~w(cloudflare dell-ipmi git-local github-cli kubernetes oidc-jwks snmp terraform-readonly)

      for id <- undetectable do
        assert PublishedRegistry.get(id), "expected #{id} to be a real catalog pack"

        refute Map.has_key?(by_id, id),
               "#{id} declares no detect evidence; must not be suggested"
      end

      # Lean shape: only id/name/os/detect — no hash/tarball/description.
      assert grafana |> Map.keys() |> Enum.sort() == [:detect, :id, :name, :os]
    end
  end

  describe "tarball_url/1" do
    test "returns the immutable content-addressed URL for a known id" do
      pack = PublishedRegistry.get("redis")
      assert {:ok, url} = PublishedRegistry.tarball_url("redis")
      # The version + content hash are baked into the immutable path, so the
      # URL a page renders is the exact bytes its --hash pin was cut against.
      assert url == pack.tarball_url
      assert url =~ "/v1/packs/redis/#{pack.version}/"
      assert url =~ String.replace(pack.content_hash, "sha256:", "")
    end

    test "is :error for an unknown id" do
      assert PublishedRegistry.tarball_url("nope") == :error
    end
  end

  describe "tarball_url/2" do
    test "resolves a pack's current version to its tarball" do
      pack = PublishedRegistry.get("redis")
      assert PublishedRegistry.tarball_url("redis", pack.version) == {:ok, pack.tarball_url}
    end

    test "is :error for a version the pack doesn't advertise" do
      # No pack yet ships history in the bundled catalog, so any non-current
      # version is unknown; the remembered-version branch is covered purely in
      # Emisar.Catalog.PublishedRegistry.PackTest.
      assert PublishedRegistry.tarball_url("redis", "9.9.9") == :error
    end

    test "is :error for an unknown id" do
      assert PublishedRegistry.tarball_url("nope", "0.1.0") == :error
    end
  end

  describe "get/1" do
    test "returns the pack struct for a known id" do
      assert %PublishedRegistry.Pack{id: "linux-core"} = PublishedRegistry.get("linux-core")
    end

    test "returns nil for an unknown id" do
      assert PublishedRegistry.get("nope") == nil
    end

    test "an exec action carries its parsed command template" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert action.command == %{
               binary: "cloud-init",
               argv: ["single", "--name={{ args.module }}", "--frequency={{ args.frequency }}"]
             }
    end

    test "a script-kind action carries no command template" do
      pack = PublishedRegistry.get("cassandra")
      action = Enum.find(pack.actions, &(&1.id == "cassandra.analyze_disk_pressure"))

      assert action.kind == "script"
      assert action.command == nil
    end
  end

  describe "resolve_command/4" do
    test "returns the compiled command when the pinned hash matches" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PublishedRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               pack.content_hash,
               nil
             ) == {:ok, action.command}
    end

    test "falls back to the advertised version when no hash is pinned" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PublishedRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               pack.version
             ) == {:ok, action.command}
    end

    test "trusts a pinned hash over the version — a hash drift is :error" do
      # The pinned hash is authoritative: even a matching advertised version
      # must not paper over a hash the runner will actually enforce differently.
      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               "sha256:#{String.duplicate("0", 64)}",
               pack.version
             ) == :error
    end

    test "is :error when neither hash nor version matches" do
      assert PublishedRegistry.resolve_command(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               "9.9.9"
             ) == :error

      assert PublishedRegistry.resolve_command("cloud-init", "cloud-init.single_module", nil, nil) ==
               :error
    end

    test "is :error for a script-kind action even on a hash match" do
      pack = PublishedRegistry.get("cassandra")

      assert PublishedRegistry.resolve_command(
               "cassandra",
               "cassandra.analyze_disk_pressure",
               pack.content_hash,
               nil
             ) == :error
    end

    test "is :error for an unknown pack or action" do
      assert PublishedRegistry.resolve_command("nope", "nope.x", "sha256:abc", nil) == :error

      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_command(
               "cloud-init",
               "cloud-init.nope",
               pack.content_hash,
               nil
             ) == :error
    end
  end
end
