defmodule EmisarWeb.PacksRegistry.CatalogTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.PacksRegistry.{Catalog, Pack}

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
      "tarball_url" =>
        "https://storage.googleapis.com/emisar-pack-registry/v1/packs/#{id}/x.tar.gz",
      "requires" => %{"os" => ["linux"], "binaries" => ["#{id}ctl"]},
      "detect" => %{"binaries" => ["#{id}ctl"], "processes" => [id], "ports" => [6379]},
      "actions" => [
        %{
          "id" => "#{id}.info",
          "title" => "#{id} info",
          "kind" => "exec",
          "risk" => "low",
          "command" => %{"binary" => id, "argv" => ["info", "{{ args.section }}"]}
        }
      ]
    }
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
      assert redis.tarball_url =~ "storage.googleapis.com"
      assert redis.source_url =~ "/packs/redis"
      assert redis.detect == %{binaries: ["redisctl"], processes: ["redis"], ports: [6379]}
      assert [%{id: "redis.info", command: %{binary: "redis"}}] = redis.actions
    end

    test "decodes a valid catalog from a JSON string" do
      json = Jason.encode!(valid_catalog())
      assert {:ok, packs} = Catalog.parse(json)
      assert length(packs) == 2
    end

    test "a script-kind action carries no command" do
      catalog =
        put_in_pack(valid_catalog(), 0, "actions", [
          %{"id" => "redis.deep", "title" => "Deep", "kind" => "script", "risk" => "low"}
        ])

      assert {:ok, packs} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))
      assert [%{kind: "script", command: nil}] = redis.actions
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
      dup = %{"id" => "redis.info", "title" => "Dup", "kind" => "script", "risk" => "low"}
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
      bad = %{
        "id" => "redis.bad",
        "title" => "Bad",
        "kind" => "exec",
        "risk" => "low",
        "command" => %{"binary" => "redis", "argv" => ["info", 42]}
      }

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
      bad = %{"id" => "redis.x", "title" => "X", "kind" => "exec", "risk" => "spicy"}
      catalog = put_in_pack(valid_catalog(), 0, "actions", [bad])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "risk"
    end
  end
end
