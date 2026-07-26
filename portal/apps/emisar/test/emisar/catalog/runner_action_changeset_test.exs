defmodule Emisar.Catalog.RunnerAction.ChangesetTest do
  use ExUnit.Case, async: true
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Catalog.RunnerAction

  @valid_pack_hash "sha256:" <> String.duplicate("a", 64)

  defp base_attrs(extra) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        action_id: "linux.uptime",
        pack_id: "linux-core",
        pack_version: "1.0.0",
        pack_hash: @valid_pack_hash,
        title: "Uptime",
        kind: :exec,
        risk: :low
      },
      extra
    )
  end

  describe "upsert/1 size caps" do
    test "accepts a normal descriptor" do
      changeset =
        RunnerAction.Changeset.upsert(
          base_attrs(%{
            description: "Show how long the host has been up.",
            args_schema: %{"type" => "object", "properties" => %{}}
          })
        )

      assert changeset.valid?
    end

    test "rejects an oversized title" do
      changeset = RunnerAction.Changeset.upsert(base_attrs(%{title: String.duplicate("t", 300)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :title)
    end

    test "rejects an oversized description" do
      changeset =
        RunnerAction.Changeset.upsert(base_attrs(%{description: String.duplicate("d", 5_000)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :description)
    end

    test "rejects an oversized args_schema" do
      huge = %{"junk" => for(i <- 1..5_000, into: %{}, do: {"k#{i}", String.duplicate("v", 32)})}

      changeset = RunnerAction.Changeset.upsert(base_attrs(%{args_schema: huge}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :args_schema)
    end

    test "bounds output schemas independently" do
      valid = %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}}
      }

      assert RunnerAction.Changeset.upsert(base_attrs(%{output_schema: valid})).valid?

      huge = %{"type" => "object", "description" => String.duplicate("x", 8_192)}
      changeset = RunnerAction.Changeset.upsert(base_attrs(%{output_schema: huge}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :output_schema)

      for invalid <- [
            %{"type" => "object", "required" => "status"},
            %{"type" => "object", "$ref" => "#/$defs/missing"},
            %{"type" => "object", "$ref" => "https://example.com/schema"}
          ] do
        changeset = RunnerAction.Changeset.upsert(base_attrs(%{output_schema: invalid}))
        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :output_schema)
      end
    end
  end

  describe "upsert/1 action_id shape" do
    test "accepts the namespaced ids trusted packs advertise" do
      for id <-
            ~w[a.b linux.uptime cassandra.nodetool_status myorg.cassandra.repair acme-corp.do-thing] do
        assert RunnerAction.Changeset.upsert(base_attrs(%{action_id: id})).valid?, id
      end
    end

    test "rejects an unprefixed id (no namespace segment)" do
      changeset = RunnerAction.Changeset.upsert(base_attrs(%{action_id: "unprefixed"}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :action_id)
    end

    test "rejects an id whose segment does not start with a lowercase letter" do
      for id <- ~w[1starts.digit Capital.case _leading.underscore ns.0bad] do
        changeset = RunnerAction.Changeset.upsert(base_attrs(%{action_id: id}))

        refute changeset.valid?, id
        assert Keyword.has_key?(changeset.errors, :action_id)
      end
    end

    test "rejects an id carrying whitespace or illegal characters" do
      for id <- ["has space.x", "weird#.x", "ns.name/evil", "ns.name\ttab"] do
        changeset = RunnerAction.Changeset.upsert(base_attrs(%{action_id: id}))

        refute changeset.valid?, id
        assert Keyword.has_key?(changeset.errors, :action_id)
      end
    end

    test "rejects a trailing-newline id (anchored with \\A…\\z, not ^…$)" do
      changeset = RunnerAction.Changeset.upsert(base_attrs(%{action_id: "linux.uptime\n"}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :action_id)
    end

    test "rejects an oversized id past the 128-char cap" do
      id = "ns." <> String.duplicate("a", 130)

      changeset = RunnerAction.Changeset.upsert(base_attrs(%{action_id: id}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :action_id)
    end

    test "every id in the bundled catalog passes the new validation" do
      ids =
        Application.app_dir(:emisar, "priv/packs/catalog.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("packs")
        |> Enum.flat_map(fn pack -> Enum.map(pack["actions"] || [], & &1["id"]) end)

      refute ids == [], "expected the bundled catalog to advertise actions"

      for id <- ids do
        assert RunnerAction.Changeset.upsert(base_attrs(%{action_id: id})).valid?, id
      end
    end
  end

  describe "upsert/1 pack metadata shape" do
    test "accepts the runner pack metadata boundaries" do
      attrs =
        base_attrs(%{
          pack_id: String.duplicate("a", 128),
          pack_version: String.duplicate("1", 64),
          pack_hash: @valid_pack_hash
        })

      assert RunnerAction.Changeset.upsert(attrs).valid?
    end

    test "rejects pack metadata just past its length boundaries" do
      attrs =
        base_attrs(%{
          pack_id: String.duplicate("a", 129),
          pack_version: String.duplicate("1", 65),
          pack_hash: @valid_pack_hash <> "a"
        })

      errors = attrs |> RunnerAction.Changeset.upsert() |> errors_on()

      assert "should be at most 128 character(s)" in errors.pack_id
      assert "should be at most 64 character(s)" in errors.pack_version
      assert "should be at most 71 character(s)" in errors.pack_hash
    end

    test "rejects malformed pack ids, versions, and hashes" do
      attrs =
        base_attrs(%{
          pack_id: "INVALID/PACK",
          pack_version: "1.0/../escape",
          pack_hash: "sha256:" <> String.duplicate("A", 64)
        })

      errors = attrs |> RunnerAction.Changeset.upsert() |> errors_on()

      assert "has invalid format" in errors.pack_id
      assert "has invalid format" in errors.pack_version
      assert "has invalid format" in errors.pack_hash
    end
  end
end
