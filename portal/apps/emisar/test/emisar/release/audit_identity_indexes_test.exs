defmodule Emisar.Release.AuditIdentityIndexesTest do
  use ExUnit.Case, async: false
  alias Emisar.Fixtures.Release, as: Fixture
  alias Emisar.Repo

  @version 20_261_028_000_000
  @migration Emisar.Repo.Migrations.IndexAuditIdentityLabels

  setup_all do
    path =
      Application.app_dir(
        :emisar,
        "priv/repo/migrations/20261028000000_index_audit_identity_labels.exs"
      )

    Code.require_file(path)
    :ok
  end

  test "resumes each completed index prefix and rolls back without removing ordinary evidence indexes" do
    indexes = definitions()

    for count <- 0..length(indexes) do
      Fixture.with_schema(fn schema ->
        create_audit_table(schema)

        ordinary =
          for side <- ["actor", "target"] do
            definition =
              Fixture.definition(
                "audit_events",
                "account_id, #{side}_kind, #{side}_id",
                "audit_events_account_#{side}_idx"
              )

            Fixture.create_index(schema, definition)
            {definition.name, Fixture.index(schema, definition.name)}
          end

        existing = Enum.take(indexes, count)
        Enum.each(existing, &Fixture.create_index(schema, &1))
        before = Map.new(existing, &{&1.name, Fixture.index(schema, &1.name)})

        assert Ecto.Migrator.up(Repo, @version, @migration, prefix: schema) == :ok

        for index <- indexes do
          current = Fixture.index(schema, index.name)
          assert current.valid and current.ready and current.live
          if previous = before[index.name], do: assert(current.oid == previous.oid)
        end

        assert Ecto.Migrator.up(Repo, @version, @migration, prefix: schema) == :already_up
        assert Ecto.Migrator.down(Repo, @version, @migration, prefix: schema) == :ok
        assert Enum.all?(indexes, &is_nil(Fixture.index(schema, &1.name)))
        assert Fixture.migrated_versions(schema) == []

        for {name, index} <- ordinary, do: assert(Fixture.index(schema, name) == index)

        assert Ecto.Migrator.up(Repo, @version, @migration, prefix: schema) == :ok
        assert Fixture.migrated_versions(schema) == [@version]
      end)
    end
  end

  test "repairs real interrupted actor and target builds before recording the migration" do
    Fixture.with_migration_repo(fn schema, repo ->
      create_audit_table(schema, repo)

      for index <- definitions() do
        assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                 Fixture.interrupt_index_build(schema, index, repo)

        assert %{valid: false, ready: false} = Fixture.index(schema, index.name, repo)
      end

      assert Ecto.Migrator.up(repo, @version, @migration, prefix: schema) == :ok

      for index <- definitions() do
        assert %{valid: true, ready: true, live: true} = Fixture.index(schema, index.name, repo)
      end

      assert Ecto.Migrator.migrated_versions(repo, prefix: schema) == [@version]
    end)
  end

  test "rejects a same-name index with a missing label predicate without replacing it" do
    for index <- definitions() do
      Fixture.with_schema(fn schema ->
        create_audit_table(schema)
        Fixture.create_index(schema, %{index | predicate: nil})
        before = Fixture.index(schema, index.name)

        assert_raise RuntimeError, ~r/does not match the owned index definition/, fn ->
          Ecto.Migrator.up(Repo, @version, @migration, prefix: schema)
        end

        assert Fixture.index(schema, index.name) == before
        assert Fixture.migrated_versions(schema) == []
      end)
    end
  end

  defp definitions do
    for side <- ["actor", "target"] do
      Fixture.definition(
        "audit_events",
        "account_id, #{side}_kind, #{side}_id, occurred_at DESC, id DESC",
        "audit_events_#{side}_latest_label_idx",
        "#{side}_id IS NOT NULL AND #{side}_label IS NOT NULL AND BTRIM(#{side}_label) <> ''"
      )
    end
  end

  defp create_audit_table(schema, repo \\ Repo) do
    table = Fixture.qualified(schema, "audit_events")

    Fixture.sql(
      """
      CREATE TABLE #{table} (
        account_id uuid, occurred_at timestamp, id uuid,
        actor_kind varchar(255), actor_id uuid, actor_label varchar(255),
        target_kind varchar(255), target_id uuid, target_label varchar(255)
      )
      """,
      [],
      repo
    )
  end
end
