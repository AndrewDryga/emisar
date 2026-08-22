defmodule Emisar.Catalog.PublishedRegistryTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PublishedRegistry

  # A well-formed hash that is not any published pack's.
  defp drifted_hash, do: "sha256:" <> String.duplicate("0", 64)

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
               "sha256:c91c2cc41e9f6651d13c18c13727f4e05b6a8a7a7630e122ca681bca77f9d308"

      assert PublishedRegistry.get("cassandra").content_hash ==
               "sha256:b15c4f8726c7255c07a405e2cc54222c959d01add776a69d96cc9209ee26df35"
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

    test "an exec action carries the declared args its template renders against" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert Enum.map(action.args, & &1["name"]) == ["module", "frequency"]
      assert Enum.find(action.args, &(&1["name"] == "frequency"))["default"] == "always"
    end

    test "a script-kind action carries no command template" do
      pack = PublishedRegistry.get("cassandra")
      action = Enum.find(pack.actions, &(&1.id == "cassandra.analyze_disk_pressure"))

      assert action.kind == "script"
      assert action.command == nil
    end
  end

  describe "resolve_action/4" do
    test "returns the whole action when the pinned and advertised hashes are ours" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               pack.content_hash,
               pack.content_hash
             ) == {:ok, action}
    end

    test "the advertised hash alone proves an unpinned run" do
      pack = PublishedRegistry.get("cloud-init")
      action = Enum.find(pack.actions, &(&1.id == "cloud-init.single_module"))

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               pack.content_hash
             ) == {:ok, action}
    end

    test "is :error when either side of the proof drifts from our bytes" do
      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               drifted_hash(),
               pack.content_hash
             ) == :error

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               pack.content_hash,
               drifted_hash()
             ) == :error

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               drifted_hash()
             ) == :error
    end

    test "is :error when the runner advertises no hash at all" do
      # An advertisement with no hash names no bytes, so a pinned run has
      # nothing to agree with and an unpinned run has no evidence whatsoever.
      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               pack.content_hash,
               nil
             ) == :error

      assert PublishedRegistry.resolve_action("cloud-init", "cloud-init.single_module", nil, nil) ==
               :error
    end

    test "a matching version is not evidence — only content hashes are" do
      # A version is a label the pack author picks; it can name bytes we don't
      # have, so passing one where a hash belongs proves nothing.
      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.single_module",
               nil,
               pack.version
             ) == :error
    end

    test "is :error for a script-kind action even on a hash match" do
      pack = PublishedRegistry.get("cassandra")

      assert PublishedRegistry.resolve_action(
               "cassandra",
               "cassandra.analyze_disk_pressure",
               pack.content_hash,
               pack.content_hash
             ) == :error
    end

    test "is :error for an unknown pack or action" do
      assert PublishedRegistry.resolve_action("nope", "nope.x", "sha256:abc", "sha256:abc") ==
               :error

      pack = PublishedRegistry.get("cloud-init")

      assert PublishedRegistry.resolve_action(
               "cloud-init",
               "cloud-init.nope",
               pack.content_hash,
               pack.content_hash
             ) == :error
    end
  end
end
