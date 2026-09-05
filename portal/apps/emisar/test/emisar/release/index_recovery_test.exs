defmodule Emisar.Release.IndexRecoveryTest do
  use ExUnit.Case, async: false
  alias Emisar.Fixtures.Release, as: Fixture
  alias Emisar.Release.IndexRecovery
  alias Emisar.Repo

  setup_all do
    path =
      Application.app_dir(
        :emisar,
        "priv/repo/migrations/20261024000000_recover_skipped_concurrent_indexes.exs"
      )

    Code.require_file(path)
    :ok
  end

  for version <- Fixture.versions() do
    @version version

    test "recovers every successful operation prefix of #{@version}" do
      version = @version
      steps = Fixture.steps(version)

      for length <- 0..length(steps) do
        Fixture.with_schema(fn schema ->
          Fixture.prepare(schema, version, length)

          existing =
            for {:create, index} <- steps,
                current = Fixture.index(schema, index.name),
                into: %{},
                do: {index.name, current}

          assert Fixture.migrate(schema, version) == :ok
          assert Fixture.migrated_versions(schema) == [version]

          for {:create, index} <- steps do
            current = Fixture.index(schema, index.name)
            assert current.valid and current.ready and current.live

            if before = existing[index.name] do
              if before.predicate == current.predicate, do: assert(current.oid == before.oid)
            end
          end

          created = for {:create, index} <- steps, do: index.name

          for {:drop, index} <- steps, index.name not in created do
            refute Fixture.index(schema, index.name)
          end

          assert Fixture.migrate(schema, version) == :already_up
        end)
      end
    end
  end

  test "the release runner interleaves ordinary migrations and never replays applied bodies" do
    Fixture.with_migration_repo(fn schema, repo ->
      source = [
        {20_260_917_000_000, Fixture.Baseline},
        {20_260_919_000_000, Fixture.AfterCascadeKeys}
      ]

      Emisar.Release.with_migration_lock(repo, fn ->
        Emisar.Release.Migrations.run(repo, source, prefix: schema)
      end)

      expected = Enum.sort([20_260_917_000_000, 20_260_919_000_000 | Fixture.versions()])
      assert Enum.sort(Ecto.Migrator.migrated_versions(repo, prefix: schema)) == expected
      refute Fixture.index(schema, "api_key_device_grants_account_id_index", repo)

      Emisar.Release.with_migration_lock(repo, fn ->
        Emisar.Release.Migrations.run(repo, source, prefix: schema)
      end)

      refute Fixture.index(schema, "api_key_device_grants_account_id_index", repo)
    end)
  end

  test "retains an already-added quantity-sync column and its values" do
    Fixture.with_schema(fn schema ->
      Fixture.prepare(schema, 20_261_009_000_000, 1)
      table = Fixture.qualified(schema, "billing_subscriptions")
      Fixture.sql("INSERT INTO #{table} VALUES (gen_random_uuid(), '2026-09-05 12:34:56.123456')")

      assert Fixture.migrate(schema, 20_261_009_000_000) == :ok

      assert Fixture.sql("SELECT runner_quantity_sync_requested_at FROM #{table}").rows ==
               [[~N[2026-09-05 12:34:56.123456]]]
    end)
  end

  test "rejects an incompatible quantity-sync column without recording the version" do
    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      table = Fixture.qualified(schema, "billing_subscriptions")

      Fixture.sql(
        "ALTER TABLE #{table} ADD COLUMN runner_quantity_sync_requested_at timestamptz DEFAULT now()"
      )

      assert_raise RuntimeError, ~r/incompatible shape/, fn ->
        Fixture.migrate(schema, 20_261_009_000_000)
      end

      assert Fixture.migrated_versions(schema) == []
    end)
  end

  test "a wrong same-name index is preserved and prevents version recording" do
    Fixture.with_schema(fn schema ->
      Fixture.prepare(schema, 20_260_921_000_000)

      index =
        Fixture.definition(
          "action_runs",
          "account_id, inserted_at ASC, id",
          "action_runs_account_keyset_idx"
        )

      Fixture.create_index(schema, index)
      before = Fixture.index(schema, index.name)

      assert_raise RuntimeError, ~r/does not match/, fn ->
        Fixture.migrate(schema, 20_260_921_000_000)
      end

      assert Fixture.index(schema, index.name) == before
      assert Fixture.migrated_versions(schema) == []
    end)
  end

  test "matching valid indexes keep their OID across direct recovery" do
    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      index = Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx")
      Fixture.create_index(schema, index)
      before = Fixture.index(schema, index.name)

      IndexRecovery.ensure_index(Repo, schema, "action_runs", ["inserted_at"], name: index.name)

      assert Fixture.index(schema, index.name) == before
    end)
  end

  test "genuine duplicates prevent invalid unique repair and migration version recording" do
    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      Fixture.duplicate_identifiers(schema)
      [{:create, index} | _] = Fixture.steps(20_261_001_000_000)

      assert_raise Postgrex.Error, ~r/could not create unique index/, fn ->
        Fixture.sql(Fixture.create_sql(schema, index, true))
      end

      assert %{valid: false, ready: false} = Fixture.index(schema, index.name)

      assert_raise Postgrex.Error, ~r/could not create unique index/, fn ->
        Fixture.migrate(schema, 20_261_001_000_000)
      end

      assert Fixture.migrated_versions(schema) == []
      assert %{valid: false} = Fixture.index(schema, index.name <> "_ccnew")
      Fixture.remove_duplicate_identifier(schema)

      assert Fixture.migrate(schema, 20_261_001_000_000) == :ok
      assert %{valid: true, ready: true, live: true} = Fixture.index(schema, index.name)
      refute Fixture.index(schema, index.name <> "_ccnew")
      assert Fixture.migrated_versions(schema) == [20_261_001_000_000]

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        Fixture.duplicate_identifiers(schema)
      end
    end)
  end

  test "late-canceled unique builds enforce uniqueness until concurrent repair succeeds" do
    Fixture.with_migration_repo(fn schema, repo ->
      Fixture.create_tables(schema, repo)
      [{:create, index} | _] = Fixture.steps(20_261_001_000_000)
      table = Fixture.qualified(schema, "sso_user_identities")

      insert =
        "INSERT INTO #{table} (account_id, provider_id, provider_identifier) VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'subject')"

      Fixture.sql(insert, [], repo)

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
               Fixture.interrupt_index_build(schema, index, repo, :validation)

      assert %{valid: false, ready: true, live: true} = Fixture.index(schema, index.name, repo)

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        Fixture.sql(insert, [], repo)
      end

      assert Ecto.Migrator.up(
               repo,
               20_261_001_000_000,
               Emisar.Release.Migrations.ActiveIdentifiers,
               prefix: schema
             ) == :ok

      assert %{valid: true, ready: true, live: true} = Fixture.index(schema, index.name, repo)

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        Fixture.sql(insert, [], repo)
      end
    end)
  end

  test "repairs a real canceled nonunique build after IF NOT EXISTS recorded both old versions" do
    Fixture.with_migration_repo(fn schema, repo ->
      Fixture.create_tables(schema, repo)
      staff = Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx")

      console =
        Fixture.definition(
          "audit_events",
          "account_id, occurred_at DESC, id ASC",
          "audit_events_account_console_keyset_idx"
        )

      for index <- [staff, console] do
        assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                 Fixture.interrupt_index_build(schema, index, repo)

        assert %{valid: false, ready: false} = Fixture.index(schema, index.name, repo)
      end

      assert Ecto.Migrator.up(repo, 20_261_021_000_004, Fixture.StaffWindowIndex, prefix: schema) ==
               :ok

      assert Ecto.Migrator.up(repo, 20_261_022_000_000, Fixture.ConsoleKeysetIndex,
               prefix: schema
             ) == :ok

      refute Fixture.index(schema, staff.name, repo).valid
      refute Fixture.index(schema, console.name, repo).valid

      assert Ecto.Migrator.up(
               repo,
               20_261_024_000_000,
               Emisar.Repo.Migrations.RecoverSkippedConcurrentIndexes,
               prefix: schema
             ) == :ok

      for index <- [staff, console] do
        assert %{valid: true, ready: true, live: true} = Fixture.index(schema, index.name, repo)
      end

      assert Enum.sort(Ecto.Migrator.migrated_versions(repo, prefix: schema)) ==
               [20_261_021_000_004, 20_261_022_000_000, 20_261_024_000_000]
    end)
  end

  test "the forward repair retains each successful prefix including all DDL before version recording" do
    for length <- 0..2 do
      Fixture.with_schema(fn schema ->
        Fixture.create_tables(schema)

        indexes = [
          Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx"),
          Fixture.definition(
            "audit_events",
            "account_id, occurred_at DESC, id ASC",
            "audit_events_account_console_keyset_idx"
          )
        ]

        for index <- Enum.take(indexes, length), do: Fixture.create_index(schema, index)

        before =
          for index <- Enum.take(indexes, length),
              into: %{},
              do: {index.name, Fixture.index(schema, index.name)}

        assert Ecto.Migrator.up(
                 Repo,
                 20_261_024_000_000,
                 Emisar.Repo.Migrations.RecoverSkippedConcurrentIndexes,
                 prefix: schema
               ) == :ok

        for index <- indexes do
          current = Fixture.index(schema, index.name)
          assert current.valid and current.ready and current.live
          if prior = before[index.name], do: assert(current.oid == prior.oid)
        end
      end)
    end
  end

  test "cleans only exact invalid reindex remnants including roots truncated for numeric suffixes" do
    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      Fixture.duplicate_domains(schema)
      [{:create, index} | _] = Fixture.steps(20_261_020_000_000)
      assert byte_size(index.name) == 57
      suffixes = ~w(_ccnew _ccnew1 _ccold _ccold12)

      remnants =
        for suffix <- suffixes do
          root_size = min(byte_size(index.name), 63 - byte_size(suffix))
          remnant = %{index | name: binary_part(index.name, 0, root_size) <> suffix}

          assert_raise Postgrex.Error, ~r/could not create unique index/, fn ->
            Fixture.sql(Fixture.create_sql(schema, remnant, true))
          end

          remnant.name
        end

      Fixture.remove_duplicate_domain(schema)
      Fixture.create_index(schema, index)
      unrelated = %{index | name: "unrelated_ccnew1"}
      Fixture.create_index(schema, unrelated)
      original = Fixture.index(schema, index.name)
      other = Fixture.index(schema, unrelated.name)

      assert Fixture.migrate(schema, 20_261_020_000_000) == :ok
      assert Fixture.index(schema, index.name) == original
      assert Fixture.index(schema, unrelated.name) == other
      for name <- remnants, do: refute(Fixture.index(schema, name))
    end)
  end

  test "the account email-domain replacement preserves case-insensitive account uniqueness" do
    Fixture.with_schema(fn schema ->
      Fixture.prepare(schema, 20_261_020_000_000)
      table = Fixture.qualified(schema, "sso_identity_providers")

      Fixture.sql(
        "INSERT INTO #{table} (account_id, allowed_email_domain, enabled) VALUES ('00000000-0000-0000-0000-000000000001', 'example.com', true)"
      )

      assert Fixture.migrate(schema, 20_261_020_000_000) == :ok

      Fixture.sql(
        "INSERT INTO #{table} (account_id, allowed_email_domain, enabled) VALUES ('00000000-0000-0000-0000-000000000002', 'EXAMPLE.COM', true)"
      )

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        Fixture.sql(
          "INSERT INTO #{table} (account_id, allowed_email_domain, enabled) VALUES ('00000000-0000-0000-0000-000000000001', 'EXAMPLE.COM', true)"
        )
      end
    end)
  end

  test "recovers a genuinely dead index left by interrupted DROP INDEX CONCURRENTLY" do
    Fixture.with_migration_repo(
      fn schema, repo ->
        Fixture.create_tables(schema, repo)
        index = Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx")
        Fixture.sql(Fixture.create_sql(schema, index), [], repo)

        assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                 Fixture.interrupt_index_drop(schema, index, repo)

        assert %{valid: false, ready: false, live: false} =
                 Fixture.index(schema, index.name, repo)

        IndexRecovery.ensure_index(repo, schema, "action_runs", ["inserted_at"], name: index.name)

        assert %{valid: true, ready: true, live: true} = Fixture.index(schema, index.name, repo)
      end,
      4
    )
  end

  test "refuses unexpected methods, keys, options, relations and dependent objects without deleting them" do
    cases = [
      {"unique", "CREATE UNIQUE INDEX", "(inserted_at)", "action_runs"},
      {"include", "CREATE INDEX", "(inserted_at) INCLUDE (id)", "action_runs"},
      {"expression", "CREATE INDEX", "((inserted_at + interval '0'))", "action_runs"},
      {"storage", "CREATE INDEX", "(inserted_at) WITH (fillfactor = 70)", "action_runs"},
      {"method", "CREATE INDEX", "USING brin (inserted_at)", "action_runs"},
      {"sort", "CREATE INDEX", "(inserted_at ASC NULLS FIRST)", "action_runs"},
      {"predicate", "CREATE INDEX", "(inserted_at) WHERE status = 'running'", "action_runs"},
      {"table", "CREATE INDEX", "(occurred_at)", "audit_events"}
    ]

    for {_label, create, definition, table} <- cases do
      Fixture.with_schema(fn schema ->
        Fixture.create_tables(schema)
        name = "action_runs_inserted_at_idx"

        Fixture.sql(
          "#{create} #{Fixture.quote_name(name)} ON #{Fixture.qualified(schema, table)} #{definition}"
        )

        before = Fixture.index(schema, name)

        assert_raise RuntimeError, ~r/does not match/, fn ->
          IndexRecovery.ensure_index(Repo, schema, "action_runs", ["inserted_at"], name: name)
        end

        assert Fixture.index(schema, name) == before
      end)
    end

    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      name = "action_runs_inserted_at_idx"
      target = Fixture.qualified(schema, name)
      Fixture.sql("CREATE TABLE #{target} (id integer)")

      assert_raise RuntimeError, ~r/does not match/, fn ->
        IndexRecovery.ensure_index(Repo, schema, "action_runs", ["inserted_at"], name: name)
      end

      assert Fixture.sql("SELECT * FROM #{target}").rows == []
    end)

    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      index = Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx")
      Fixture.create_index(schema, index)
      before = Fixture.index(schema, index.name)

      Fixture.sql(
        "CREATE TABLE #{Fixture.qualified(schema, "dependent")} (index_ref regclass DEFAULT '#{Fixture.qualified(schema, index.name)}'::regclass)"
      )

      assert_raise RuntimeError, ~r/does not match/, fn ->
        IndexRecovery.ensure_index(Repo, schema, "action_runs", ["inserted_at"], name: index.name)
      end

      assert Fixture.index(schema, index.name) == before
    end)
  end

  test "rejects nondefault opclasses, collations and column types" do
    for alteration <- [:opclass, :index_collation, :column_collation, :column_type] do
      Fixture.with_schema(fn schema ->
        Fixture.create_tables(schema)
        table = Fixture.qualified(schema, "action_runs")
        name = "action_runs_in_flight_idx"

        key =
          case alteration do
            :opclass ->
              "status varchar_pattern_ops"

            :index_collation ->
              "status COLLATE \"C\""

            :column_collation ->
              Fixture.sql(
                "ALTER TABLE #{table} ALTER COLUMN status TYPE varchar(255) COLLATE \"C\""
              )

              "status"

            :column_type ->
              Fixture.sql("ALTER TABLE #{table} ALTER COLUMN status TYPE text")
              "status"
          end

        index =
          Fixture.definition(
            "action_runs",
            key <> ", queued_at",
            name,
            "status IN ('pending', 'sent', 'running', 'cancelling')"
          )

        Fixture.create_index(schema, index)
        before = Fixture.index(schema, name)

        assert_raise RuntimeError, ~r/does not match|unexpected type/, fn ->
          IndexRecovery.replace_in_flight_index(Repo, schema)
        end

        assert Fixture.index(schema, name) == before
      end)
    end
  end

  test "wrong drop targets and ambiguous remnants fail closed while other schemas remain untouched" do
    Fixture.with_schema(fn schema ->
      Fixture.create_tables(schema)
      index = Fixture.definition("action_runs", "inserted_at", "api_keys_account_id_index")
      Fixture.create_index(schema, index)
      before = Fixture.index(schema, index.name)

      assert_raise RuntimeError, ~r/does not match/, fn ->
        IndexRecovery.drop_index(Repo, schema, "api_keys", ["account_id"])
      end

      assert Fixture.index(schema, index.name) == before
      root = Fixture.definition("action_runs", "inserted_at", "action_runs_inserted_at_idx")
      Fixture.create_index(schema, root)
      remnant = %{root | name: root.name <> "_ccnew"}
      Fixture.create_index(schema, remnant)
      before = Fixture.index(schema, remnant.name)

      assert_raise RuntimeError, ~r/remnant is valid/, fn ->
        IndexRecovery.ensure_index(Repo, schema, "action_runs", ["inserted_at"], name: root.name)
      end

      assert Fixture.index(schema, remnant.name) == before

      Fixture.isolated_schema(fn other ->
        Fixture.create_tables(other)
        IndexRecovery.ensure_index(Repo, other, "action_runs", ["inserted_at"], name: root.name)
        assert Fixture.index(schema, remnant.name) == before
        assert Fixture.index(other, root.name).valid
      end)
    end)
  end

  test "recognizes exact per-element varchar-to-text predicate spellings without changing the index" do
    cases = [
      {"action_runs", ["status", "queued_at"], "action_runs_in_flight_idx", :in_flight,
       "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('sent'::character varying)::text, ('running'::character varying)::text, ('cancelling'::character varying)::text]))"},
      {"runbook_executions", ["inserted_at", "id"], "runbook_executions_unscrubbed_terminal_idx",
       :unscrubbed,
       "(((status)::text = ANY (ARRAY[('succeeded'::character varying)::text, ('halted'::character varying)::text, ('cancelled'::character varying)::text])) AND (inputs_raw IS NOT NULL))"}
    ]

    for {table, columns, name, predicate, expression} <- cases do
      Fixture.with_schema(fn schema ->
        Fixture.create_tables(schema)
        index = Fixture.definition(table, Enum.join(columns, ", "), name, expression)
        Fixture.create_index(schema, index)
        before = Fixture.index(schema, name)
        assert before.predicate == expression

        IndexRecovery.ensure_index(Repo, schema, table, columns, name: name, predicate: predicate)

        assert Fixture.index(schema, name) == before
      end)
    end
  end

  test "a failed unique replacement leaves its predecessor enforcing uniqueness" do
    Fixture.with_schema(fn schema ->
      Fixture.prepare(schema, 20_261_001_000_000)
      [{:create, replacement}, {:drop, predecessor}] = Fixture.steps(20_261_001_000_000)
      Fixture.create_index(schema, %{replacement | unique: false})
      before = Fixture.index(schema, predecessor.name)

      assert_raise RuntimeError, ~r/does not match/, fn ->
        Fixture.migrate(schema, 20_261_001_000_000)
      end

      assert Fixture.index(schema, predecessor.name) == before
      assert Fixture.migrated_versions(schema) == []

      assert_raise Postgrex.Error, ~r/duplicate key value/, fn ->
        Fixture.duplicate_identifiers(schema)
      end
    end)
  end
end
