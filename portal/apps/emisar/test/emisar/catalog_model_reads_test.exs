defmodule Emisar.CatalogModelReadsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Catalog, Fixtures, Repo, Runners}

  setup do
    account = Fixtures.Accounts.create_account()
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    %{account: account, subject: subject, membership: membership}
  end

  describe "model_inventory/1" do
    test "complete identities match the full projection without loading descriptors", %{
      account: account,
      subject: subject
    } do
      first = Fixtures.Runners.create_runner(account_id: account.id, name: "first")
      second = Fixtures.Runners.create_runner(account_id: account.id, name: "second")
      advertise(first, ["acme", "other"])
      advertise(second, ["acme"])
      trust_all(subject)
      assert {:ok, full} = Catalog.model_catalog(subject)
      observe_queries()

      assert {:ok, inventory} = Catalog.model_inventory(subject)
      queries = queries()
      assert Enum.map(inventory.packs, & &1.pack_ref) == Enum.map(full.packs, & &1.pack_ref)

      assert Enum.map(inventory.runners, & &1.runner_ref) ==
               Enum.map(full.runners, & &1.runner_ref)

      refute Enum.any?(inventory.packs, &Map.has_key?(&1, :actions))
      refute Enum.any?(queries, &String.contains?(&1.query, "FROM \"catalog_runner_actions\""))
      assert [%{rows: 2, columns: columns}] = table_reads(queries, "catalog_pack_versions")
      refute "trusted_manifest" in columns
      assert [%{rows: 2, columns: columns}] = table_reads(queries, "runners")
      refute "connection_token_id" in columns
      refute "connection_lease_id" in columns
    end

    test "manifest shape matches persisted projection for malformed scalar versions", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      advertise(runner, ["acme"])
      trust_all(subject)
      [pack] = Fixtures.Catalog.list_pack_versions(account.id)

      for schema_version <- [1, "1", 1.0, nil, 2] do
        # Corrupt durable shape cannot be arranged through a trust mutation.
        manifest = Map.put(pack.trusted_manifest, "schema_version", schema_version)
        pack |> Ecto.Changeset.change(trusted_manifest: manifest) |> Repo.update!()
        assert {:ok, inventory} = Catalog.model_inventory(subject)
        assert {:ok, full} = Catalog.model_catalog(subject)
        assert Enum.map(inventory.packs, & &1.pack_ref) == Enum.map(full.packs, & &1.pack_ref)
        assert length(inventory.packs) == if(schema_version === 1, do: 1, else: 0)
      end
    end

    test "permission denial precedes SQL and foreign inventory is empty", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      advertise(runner, ["acme"])
      trust_all(subject)
      {_user, _account, other} = Fixtures.Subjects.owner_subject()
      assert {:ok, %{packs: [], runners: []}} = Catalog.model_inventory(other)
      denied = %{subject | permissions: MapSet.new()}
      observe_queries()
      assert Catalog.model_inventory(denied) == {:error, :unauthorized}
      assert queries() == []
    end
  end

  describe "model_catalog/2" do
    test "loads complete sibling evidence only for selected exact deployments", %{
      account: account,
      subject: subject
    } do
      first = Fixtures.Runners.create_runner(account_id: account.id)
      second = Fixtures.Runners.create_runner(account_id: account.id)
      advertise(first, ["acme", "other"])
      advertise(second, ["acme", "other"])
      trust_all(subject)
      assert {:ok, inventory} = Catalog.model_inventory(subject)
      [acme] = Enum.filter(inventory.packs, &(&1.pack_id == "acme"))
      observe_queries()

      assert {:ok, snapshot} =
               Catalog.model_catalog(subject, runner_ids: [first.id], pack_refs: [acme.pack_ref])

      assert [%{pack_ref: ref, actions: actions}] = snapshot.packs
      assert ref == acme.pack_ref
      assert length(actions) == 2
      assert [%{rows: 2}] = table_reads(queries(), "catalog_runner_actions")

      # Asking for inspect must still compare the changed sibling descriptor.
      advertise(first, ["acme", "other"], changed_sibling: true)
      {:ok, runner_ref} = Runners.public_ref(first)

      assert Catalog.resolve_model_action("acme.inspect", ref, [runner_ref], subject) ==
               {:error, :not_found}
    end

    test "stale selections do not bypass fresh runner or pack grants", %{
      account: account,
      subject: subject,
      membership: membership
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      advertise(runner, ["acme", "other"])
      trust_all(subject)
      assert {:ok, inventory} = Catalog.model_inventory(subject)
      refs = Enum.map(inventory.packs, & &1.pack_ref)
      {:ok, access} = Accounts.RunnerAccess.new(:all, [], [], :restricted, ["acme"])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, %{packs: [%{pack_id: "acme"}]}} =
               Catalog.model_catalog(subject, runner_ids: [runner.id], pack_refs: refs)

      other = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, access} = Accounts.RunnerAccess.new(:restricted, [], [other.id])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, %{packs: [], runners: []}} =
               Catalog.model_catalog(subject, runner_ids: [runner.id], pack_refs: refs)
    end

    test "explicit runner refs fail as a whole and foreign selections stay hidden", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      advertise(runner, ["acme"])
      trust_all(subject)
      {:ok, inventory} = Catalog.model_inventory(subject)
      [pack] = inventory.packs
      {:ok, ref} = Runners.public_ref(runner)
      foreign = Fixtures.Runners.create_runner()
      {:ok, foreign_ref} = Runners.public_ref(foreign)

      assert Catalog.resolve_model_action(
               "acme.inspect",
               pack.pack_ref,
               [ref, foreign_ref],
               subject
             ) ==
               {:error, :not_found}

      assert {:ok, %{packs: [], runners: []}} =
               Catalog.model_catalog(subject,
                 runner_ids: [foreign.id],
                 pack_refs: [pack.pack_ref]
               )

      denied = %{subject | permissions: MapSet.new()}
      observe_queries()
      assert Catalog.model_catalog(denied, runner_ids: [runner.id]) == {:error, :unauthorized}
      assert queries() == []
    end
  end

  describe "list_model_runners/2" do
    test "selects fresh slim scoped rows and distinguishes empty from omitted selection", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      foreign = Fixtures.Runners.create_runner()
      assert {:ok, [slim]} = Runners.list_model_runners(subject, ids: [runner.id, foreign.id])
      assert slim.id == runner.id
      assert slim.online?
      assert slim.connection_token_id == nil
      assert slim.connection_lease_id == nil
      assert {:ok, []} = Runners.list_model_runners(subject, ids: [])
      assert {:ok, [_]} = Runners.list_model_runners(subject)
      denied = %{subject | permissions: MapSet.new()}
      observe_queries()
      assert Runners.list_model_runners(denied) == {:error, :unauthorized}
      assert queries() == []
    end
  end

  defp advertise(runner, pack_ids, opts \\ []) do
    actions =
      for pack_id <- pack_ids, action <- ["inspect", "sibling"] do
        title = if action == "sibling" and opts[:changed_sibling], do: "Changed", else: action

        %{
          "id" => pack_id <> "." <> action,
          "pack_id" => pack_id,
          "title" => title,
          "kind" => "exec",
          "risk" => "low",
          "description" => "Inspect deployment",
          "side_effects" => [],
          "args" => [],
          "examples" => []
        }
      end

    assert {:ok, _runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "packs" =>
                 Map.new(pack_ids, fn id ->
                   {id, %{"version" => "1.0.0", "hash" => Fixtures.Catalog.pack_hash(id)}}
                 end),
               "actions" => actions
             })
  end

  defp trust_all(subject) do
    for pack <- Fixtures.Catalog.list_pack_versions(subject.account.id) do
      assert {:ok, _trusted} = Catalog.trust_pack_version(pack.id, subject)
    end
  end

  defp observe_queries do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, [:emisar, :repo, :query], &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def query_event(_event, _measurements, metadata, owner) do
    if self() == owner do
      case metadata.result do
        {:ok, %{num_rows: rows, columns: columns}} ->
          send(owner, {:model_query, %{query: metadata.query, rows: rows, columns: columns}})

        _other ->
          :ok
      end
    end
  end

  defp queries(acc \\ []) do
    receive do
      {:model_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp table_reads(queries, table) do
    Enum.filter(queries, &String.contains?(&1.query, "FROM \"#{table}\""))
  end
end
