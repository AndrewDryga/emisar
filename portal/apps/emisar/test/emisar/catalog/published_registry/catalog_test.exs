defmodule Emisar.Catalog.PublishedRegistry.CatalogTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PublishedRegistry.{Catalog, Pack}

  # A minimal, valid two-pack catalog. Each test overrides just the field
  # under test so the invalid input is explicit against a valid baseline.
  defp valid_catalog do
    %{
      "schema_version" => 1,
      "packs" => [pack("redis"), pack("nginx")]
    }
  end

  defp pack(id) do
    %{
      "id" => id,
      "name" => "#{id} operations",
      "version" => "0.1.0",
      "description" => "Ops for #{id}.",
      "vendor" => "emisar",
      "homepage" => "https://github.com/andrewdryga/emisar",
      "source_url" => "https://github.com/andrewdryga/emisar/tree/main/packs/#{id}",
      "content_hash" => "sha256:#{String.duplicate("a", 64)}",
      "tarball_url" => "https://registry.emisar.dev/v1/packs/#{id}/x.tar.gz",
      "requires" => %{"os" => ["linux"], "binaries" => ["#{id}ctl"]},
      "detect" => %{"binaries" => ["#{id}ctl"], "processes" => [id], "ports" => [6379]},
      "actions" => [
        action("#{id}.info", %{
          "command" => %{"binary" => id, "argv" => ["info", "{{ args.section }}"]},
          "args" => [%{"name" => "section", "type" => "string", "required" => true}]
        })
      ]
    }
  end

  # A complete trusted descriptor — the shape `emisar pack catalog build`
  # publishes. Tests override only the field under test, since anything less
  # than a full descriptor is now rejected outright.
  defp action(id, overrides \\ %{}) do
    Map.merge(
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
      },
      overrides
    )
  end

  defp put_in_pack(catalog, index, key, value) do
    update_in(catalog["packs"], fn packs ->
      List.update_at(packs, index, &Map.put(&1, key, value))
    end)
  end

  defp drop_from_pack(catalog, index, key) do
    update_in(catalog["packs"], fn packs ->
      List.update_at(packs, index, &Map.delete(&1, key))
    end)
  end

  describe "parse/1" do
    test "decodes a valid catalog into packs sorted by id" do
      assert {:ok, packs} = Catalog.parse(valid_catalog())
      assert Enum.map(packs, & &1.id) == ["nginx", "redis"]

      redis = Enum.find(packs, &(&1.id == "redis"))
      assert %Pack{name: "redis operations", version: "0.1.0"} = redis
      assert redis.content_hash == "sha256:#{String.duplicate("a", 64)}"
      assert redis.tarball_url =~ "registry.emisar.dev"
      assert redis.source_url =~ "/packs/redis"
      assert redis.detect == %{binaries: ["redisctl"], processes: ["redis"], ports: [6379]}
      assert [%{id: "redis.info", command: %{binary: "redis"}}] = redis.actions
    end

    test "a pack with no version window carries an empty history and no watermark" do
      assert {:ok, packs} = Catalog.parse(valid_catalog())
      redis = Enum.find(packs, &(&1.id == "redis"))
      assert redis.previous_versions == []
      assert redis.retired_below == nil
    end

    test "decodes a pack's previous_versions window + retirement watermark" do
      history = [
        %{
          "version" => "0.1.0",
          "content_hash" => "sha256:#{String.duplicate("b", 64)}",
          "tarball_url" => "https://registry.emisar.dev/v1/packs/redis/0.1.0/x.tar.gz"
        }
      ]

      catalog =
        valid_catalog()
        |> put_in_pack(0, "version", "0.2.0")
        |> put_in_pack(0, "previous_versions", history)
        |> put_in_pack(0, "retired_below", "0.1.0")

      assert {:ok, packs} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))

      assert redis.version == "0.2.0"
      assert redis.retired_below == "0.1.0"

      assert redis.previous_versions == [
               %{
                 version: "0.1.0",
                 content_hash: "sha256:#{String.duplicate("b", 64)}",
                 tarball_url: "https://registry.emisar.dev/v1/packs/redis/0.1.0/x.tar.gz"
               }
             ]
    end

    test "rejects the whole catalog on a malformed previous_versions hash" do
      bad = [
        %{
          "version" => "0.1.0",
          "content_hash" => "sha256:nothex",
          "tarball_url" => "https://registry.emisar.dev/v1/x.tar.gz"
        }
      ]

      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", bad)
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "content_hash"
    end

    test "rejects the whole catalog on a cleartext previous_versions tarball URL" do
      bad = [
        %{
          "version" => "0.1.0",
          "content_hash" => "sha256:#{String.duplicate("b", 64)}",
          "tarball_url" => "http://evil.example/x.tar.gz"
        }
      ]

      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", bad)
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unsafe tarball_url"
    end

    test "rejects a previous_versions entry that is not an object" do
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", ["0.1.0"])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "previous_versions entry"
    end

    test "rejects a previous_versions value that is not a list" do
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", "0.1.0")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "previous_versions must be a list"
    end

    test "rejects a malformed retired_below watermark" do
      catalog = put_in_pack(valid_catalog(), 0, "retired_below", 42)
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "retired_below"
    end

    test "decodes a valid catalog from a JSON string" do
      json = Jason.encode!(valid_catalog())
      assert {:ok, packs} = Catalog.parse(json)
      assert length(packs) == 2
    end

    test "a script-kind action carries no command" do
      script = action("redis.deep", %{"kind" => "script"})
      catalog = put_in_pack(valid_catalog(), 0, "actions", [script])

      assert {:ok, packs} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))
      assert [%{kind: "script", command: nil}] = redis.actions
    end

    test "decodes an action's description and its declared args" do
      documented =
        action("redis.info", %{
          "description" => "Redis INFO snapshot — read-only.",
          "args" => [
            %{"name" => "section", "type" => "string", "default" => "all"},
            %{"name" => "token", "type" => "string", "sensitive" => true}
          ]
        })

      catalog = put_in_pack(valid_catalog(), 0, "actions", [documented])

      assert {:ok, packs} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))
      [info] = redis.actions

      assert info.description == "Redis INFO snapshot — read-only."

      assert info.args == [
               %{"name" => "section", "type" => "string", "default" => "all"},
               %{"name" => "token", "type" => "string", "sensitive" => true}
             ]
    end

    test "rejects an action that is not a complete trusted descriptor" do
      # The command preview renders defaults and masks by `sensitive` from
      # these very args, so a half-described action must reject the catalog
      # rather than let the portal preview a command it can't stand behind.
      docless = Map.delete(action("redis.info"), "description")
      catalog = put_in_pack(valid_catalog(), 0, "actions", [docless])

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "complete trusted descriptor"
    end

    test "rejects a malformed args declaration" do
      bad = action("redis.info", %{"args" => ["section"]})
      catalog = put_in_pack(valid_catalog(), 0, "actions", [bad])

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "complete trusted descriptor"
    end

    test "rejects invalid JSON" do
      assert {:error, message} = Catalog.parse("{not json")
      assert message =~ "not valid JSON"
    end

    test "rejects an unsupported schema_version" do
      assert {:error, message} = Catalog.parse(%{"schema_version" => 2, "packs" => []})
      assert message =~ "schema_version"
    end

    test "rejects a document with no packs list" do
      assert {:error, _} = Catalog.parse(%{"schema_version" => 1})
    end

    test "rejects a duplicate pack id" do
      catalog = put_in_pack(valid_catalog(), 1, "id", "redis")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "duplicate pack id"
    end

    test "rejects a duplicate action id across packs" do
      dup = action("redis.info", %{"kind" => "script"})
      catalog = put_in_pack(valid_catalog(), 1, "actions", [dup])

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "duplicate action id"
    end

    test "rejects a malformed content hash" do
      catalog = put_in_pack(valid_catalog(), 0, "content_hash", "sha256:nothex")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "content_hash"
    end

    test "rejects a cleartext tarball URL" do
      catalog = put_in_pack(valid_catalog(), 0, "tarball_url", "http://evil.example/x.tar.gz")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unsafe tarball_url"
    end

    test "rejects a javascript: source URL" do
      catalog = put_in_pack(valid_catalog(), 0, "source_url", "javascript:alert(1)")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unsafe source_url"
    end

    test "rejects a missing required field" do
      catalog = drop_from_pack(valid_catalog(), 0, "name")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "name"
    end

    test "rejects a command whose argv is not all strings" do
      bad = action("redis.bad", %{"command" => %{"binary" => "redis", "argv" => ["info", 42]}})

      catalog = put_in_pack(valid_catalog(), 0, "actions", [bad])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "argv"
    end

    test "rejects a detect port outside 1..65535" do
      catalog =
        put_in_pack(valid_catalog(), 0, "detect", %{
          "binaries" => [],
          "processes" => [],
          "ports" => [70_000]
        })

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "ports"
    end

    test "rejects an invalid action risk tier" do
      bad = action("redis.x", %{"risk" => "spicy"})
      catalog = put_in_pack(valid_catalog(), 0, "actions", [bad])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "risk"
    end
  end
end
