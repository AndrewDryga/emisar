defmodule Emisar.Catalog.PublishedRegistry.CatalogTest do
  use ExUnit.Case, async: true
  alias Emisar.Catalog.PublishedRegistry.{Catalog, Pack}
  alias Emisar.Catalog.TrustedManifest

  # A minimal, valid two-pack catalog. Each test overrides just the field
  # under test so the invalid input is explicit against a valid baseline.
  defp valid_catalog do
    %{
      "schema_version" => 1,
      "generation" => 7,
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

  defp previous(version, overrides \\ %{}) do
    Map.merge(
      %{
        "version" => version,
        "content_hash" => "sha256:#{String.duplicate("b", 64)}",
        "tarball_url" => "https://registry.emisar.dev/v1/packs/redis/#{version}/x.tar.gz"
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
      assert {:ok, %{generation: 7, packs: packs}} = Catalog.parse(valid_catalog())
      assert Enum.map(packs, & &1.id) == ["nginx", "redis"]

      redis = Enum.find(packs, &(&1.id == "redis"))
      assert %Pack{name: "redis operations", version: "0.1.0"} = redis
      assert redis.content_hash == "sha256:#{String.duplicate("a", 64)}"
      assert redis.tarball_url =~ "registry.emisar.dev"
      assert redis.source_url =~ "/packs/redis"
      assert redis.detect == %{binaries: ["redisctl"], processes: ["redis"], ports: [6379]}
      assert [%{id: "redis.info", command: %{binary: "redis"}}] = redis.actions
    end

    test "rejects a legacy catalog without a generation" do
      legacy = Map.delete(valid_catalog(), "generation")
      assert {:error, "catalog missing generation"} = Catalog.parse(legacy)
    end

    test "rejects a generation outside the shared exact-integer range" do
      for generation <- [0, 9_007_199_254_740_992] do
        assert {:error, message} = Catalog.parse(%{valid_catalog() | "generation" => generation})
        assert message =~ "generation must be an integer between 1 and"
      end

      assert {:ok, %{generation: 9_007_199_254_740_991}} =
               Catalog.parse(%{valid_catalog() | "generation" => 9_007_199_254_740_991})
    end

    test "a pack with no version window carries an empty history and no watermark" do
      assert {:ok, %{packs: packs}} = Catalog.parse(valid_catalog())
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

      assert {:ok, %{packs: packs}} = Catalog.parse(catalog)
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
      assert {:ok, %{packs: packs}} = Catalog.parse(json)
      assert length(packs) == 2
    end

    test "a script-kind action carries no command" do
      script = action("redis.deep", %{"kind" => "script"})
      catalog = put_in_pack(valid_catalog(), 0, "actions", [script])

      assert {:ok, %{packs: packs}} = Catalog.parse(catalog)
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

      assert {:ok, %{packs: packs}} = Catalog.parse(catalog)
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

    test "decodes a pack's setup block, defaulting the optional per-variable fields" do
      catalog =
        put_in_pack(valid_catalog(), 0, "setup", %{
          "summary" => "Authenticates with REDIS_URL.",
          "env" => [
            %{"name" => "REDIS_URL", "required" => true, "description" => "Connection URL."},
            %{"name" => "REDIS_TLS", "default" => "off"}
          ],
          "notes" => ["Reads need no privilege."],
          "host_access" => [
            %{
              "actions" => ["redis.info"],
              "requirement" => "Read the Redis socket.",
              "recipes" => [
                %{
                  "name" => "Debian and Ubuntu",
                  "commands" => ["  sudo install -m 0640 source target  "],
                  "verify" => ["sudo -u emisar test -r target"],
                  "impact" => "Lets redis.info read the socket."
                }
              ]
            }
          ],
          "verify" => "redis.info"
        })

      assert {:ok, %{packs: packs}} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))

      assert redis.setup.summary == "Authenticates with REDIS_URL."
      assert redis.setup.notes == ["Reads need no privilege."]
      assert redis.setup.verify == "redis.info"

      assert redis.setup.host_access == [
               %{
                 actions: ["redis.info"],
                 requirement: "Read the Redis socket.",
                 recipes: [
                   %{
                     name: "Debian and Ubuntu",
                     commands: ["  sudo install -m 0640 source target  "],
                     verify: ["sudo -u emisar test -r target"],
                     impact: "Lets redis.info read the socket."
                   }
                 ]
               }
             ]

      assert redis.setup.env == [
               %{
                 name: "REDIS_URL",
                 required: true,
                 description: "Connection URL.",
                 default: nil,
                 example: nil
               },
               %{
                 name: "REDIS_TLS",
                 required: false,
                 description: nil,
                 default: "off",
                 example: nil
               }
             ]
    end

    test "accepts a catalog published before setup existed" do
      # The live catalog is fed back as `--previous` on the next build, and it
      # carries no setup at all — rejecting it would break every future publish.
      catalog = drop_from_pack(valid_catalog(), 0, "setup")

      assert {:ok, %{packs: packs}} = Catalog.parse(catalog)
      redis = Enum.find(packs, &(&1.id == "redis"))
      assert redis.setup == %{summary: nil, env: [], notes: [], host_access: [], verify: nil}
    end

    test "rejects a setup env entry with no name" do
      catalog = put_in_pack(valid_catalog(), 0, "setup", %{"env" => [%{"description" => "x"}]})

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "setup env"
    end

    test "rejects a setup block that is not an object" do
      catalog = put_in_pack(valid_catalog(), 0, "setup", "SENTRY_AUTH_TOKEN")

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "malformed setup"
    end

    test "rejects setup host access for an unknown action" do
      host_access = [
        %{
          "actions" => ["redis.missing"],
          "requirement" => "Read the Redis socket.",
          "recipes" => [
            %{
              "name" => "systemd",
              "commands" => ["sudo systemctl edit redis"],
              "verify" => ["sudo -u emisar test -r /run/redis.sock"],
              "impact" => "Lets the runner reach Redis."
            }
          ]
        }
      ]

      catalog = put_in_pack(valid_catalog(), 0, "setup", %{"host_access" => host_access})
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unknown action"
    end

    test "rejects duplicate or control-bearing setup host access" do
      group = %{
        "actions" => ["redis.info", "redis.info"],
        "requirement" => "Read the Redis socket.",
        "recipes" => [
          %{
            "name" => "systemd",
            "commands" => ["sudo systemctl edit redis"],
            "verify" => ["sudo -u emisar test -r /run/redis.sock"],
            "impact" => "Lets the runner reach Redis."
          }
        ]
      }

      duplicate = put_in_pack(valid_catalog(), 0, "setup", %{"host_access" => [group]})
      assert {:error, duplicate_message} = Catalog.parse(duplicate)
      assert duplicate_message =~ "repeats setup host_access action"

      unsafe =
        group
        |> Map.put("actions", ["redis.info"])
        |> put_in(["recipes", Access.at(0), "commands"], ["echo ok\nfalse"])

      control = put_in_pack(valid_catalog(), 0, "setup", %{"host_access" => [unsafe]})
      assert {:error, control_message} = Catalog.parse(control)
      assert control_message =~ "malformed setup host_access commands"

      invisible =
        group
        |> Map.put("actions", ["redis.info"])
        |> put_in(["recipes", Access.at(0), "impact"], "safe\u200Bhidden")

      format_control =
        put_in_pack(valid_catalog(), 0, "setup", %{"host_access" => [invisible]})

      assert {:error, format_message} = Catalog.parse(format_control)
      assert format_message =~ "malformed setup host_access recipe prose"
    end

    test "rejects an invalid action risk tier" do
      bad = action("redis.x", %{"risk" => "spicy"})
      catalog = put_in_pack(valid_catalog(), 0, "actions", [bad])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "risk"
    end
  end

  describe "parse/1 trust snapshot" do
    test "carries every pack's current hash, manifest and version" do
      hash = "sha256:#{String.duplicate("a", 64)}"
      assert {:ok, %{trust: trust}} = Catalog.parse(valid_catalog())

      assert trust.baseline[{"redis", "0.1.0"}] == hash
      assert trust.current_versions == %{"redis" => "0.1.0", "nginx" => "0.1.0"}
      assert trust.retired_below == %{}
      assert Map.keys(trust.manifests[{"redis", "0.1.0", hash}]["actions"]) == ["redis.info"]
    end

    test "carries a previous version's hash, retained manifest and watermark" do
      hash = "sha256:#{String.duplicate("b", 64)}"

      catalog =
        valid_catalog()
        |> put_in_pack(0, "version", "0.2.0")
        |> put_in_pack(0, "previous_versions", [
          previous("0.1.0", %{"actions" => [action("redis.legacy")]})
        ])
        |> put_in_pack(0, "retired_below", "0.1.0")

      assert {:ok, %{trust: trust}} = Catalog.parse(catalog)

      assert trust.baseline[{"redis", "0.1.0"}] == hash
      assert trust.current_versions["redis"] == "0.2.0"
      assert trust.retired_below == %{"redis" => "0.1.0"}
      assert Map.keys(trust.manifests[{"redis", "0.1.0", hash}]["actions"]) == ["redis.legacy"]
    end

    test "a previous version with no retained actions keeps its baseline entry" do
      hash = "sha256:#{String.duplicate("b", 64)}"
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", [previous("0.0.9")])

      assert {:ok, %{trust: trust}} = Catalog.parse(catalog)

      assert trust.baseline[{"redis", "0.0.9"}] == hash
      assert trust.manifests[{"redis", "0.0.9", hash}] == nil
    end

    test "a previous version whose retained actions no longer validate keeps its baseline entry" do
      hash = "sha256:#{String.duplicate("b", 64)}"
      docless = Map.delete(action("redis.legacy"), "description")

      catalog =
        put_in_pack(valid_catalog(), 0, "previous_versions", [
          previous("0.0.9", %{"actions" => [docless]})
        ])

      assert {:ok, %{trust: trust}} = Catalog.parse(catalog)

      assert trust.baseline[{"redis", "0.0.9"}] == hash
      assert trust.manifests[{"redis", "0.0.9", hash}] == nil
    end

    test "rejects an unparseable current version" do
      catalog = put_in_pack(valid_catalog(), 0, "version", "0.1")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unparseable version \"0.1\""
    end

    test "rejects an unparseable previous version" do
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", [previous("0.0")])
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unparseable version \"0.0\""
    end

    test "rejects two previous_versions entries for the same version" do
      # Both carry a hash for one (pack_id, version), so whichever bytes
      # auto-trust would come down to document order.
      other_hash = "sha256:#{String.duplicate("d", 64)}"
      history = [previous("0.0.9"), previous("0.0.9", %{"content_hash" => other_hash})]
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", history)

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ ~s(pack "redis" lists version "0.0.9" more than once)
    end

    test "rejects a previous version that repeats the current version" do
      other_hash = "sha256:#{String.duplicate("d", 64)}"
      history = [previous("0.1.0", %{"content_hash" => other_hash})]
      catalog = put_in_pack(valid_catalog(), 0, "previous_versions", history)

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ ~s(pack "redis" lists version "0.1.0" more than once)
    end

    test "rejects an unparseable retirement watermark" do
      catalog = put_in_pack(valid_catalog(), 0, "retired_below", "0.1")
      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "unparseable retired_below \"0.1\""
    end

    test "rejects a current version whose actions cannot build one complete manifest" do
      # Every action is a valid descriptor on its own; the pack blows the
      # manifest's action cap, so the version auto-trust would pin has no
      # manifest at all — reject the document rather than trust half of it.
      actions = Enum.map(1..(TrustedManifest.max_actions() + 1), &action("redis.a#{&1}"))
      catalog = put_in_pack(valid_catalog(), 0, "actions", actions)

      assert {:error, message} = Catalog.parse(catalog)
      assert message =~ "invalid action manifest"
    end
  end
end
