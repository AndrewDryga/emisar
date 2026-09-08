defmodule Emisar.RetentionBatchesTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Billing, Catalog, Fixtures, Repo, Runners}
  alias Emisar.Catalog.PackBaseline

  setup do
    {_user, account, subject} = Fixtures.Subjects.owner_subject()
    %{account: account, subject: subject}
  end

  describe "delete_inactive_runners/4" do
    test "slim tiny batches delete every eligible row and audit actual changes once per batch", %{
      account: account
    } do
      runners = for index <- 1..5, do: offline_runner(account, name: "old-#{index}")
      other = offline_runner(Fixtures.Accounts.create_account())
      disabled = account |> offline_runner() |> Fixtures.Runners.disable_runner()
      observe_queries(account.id)

      assert Runners.delete_inactive_runners(account.id, 24, nil, batch_size: 2) == {:ok, 5}
      queries = queries()
      pages = Enum.filter(queries, &String.contains?(&1.query, "FOR NO KEY UPDATE"))
      assert Enum.map(pages, & &1.rows) == [2, 2, 1, 0]
      assert Enum.all?(pages, &(length(&1.columns) == 3))
      assert Enum.all?(runners, &Repo.reload!(&1).deleted_at)
      assert is_nil(Repo.reload!(other).deleted_at)
      assert is_nil(Repo.reload!(disabled).deleted_at)
      assert marker_counts(account.id, "runner.retention_swept") == [1, 2, 2]

      assert Runners.delete_inactive_runners(account.id, 24, nil, batch_size: 2) == {:ok, 0}
      assert marker_counts(account.id, "runner.retention_swept") == [1, 2, 2]
    end

    test "an invalid audit rolls back its deletion batch", %{account: account, subject: subject} do
      runner = offline_runner(account)
      subscription = subscription(account)
      subject = %{subject | context: %Emisar.RequestContext{request_id: %{invalid: true}}}

      assert {:error, %Ecto.Changeset{}} =
               Runners.delete_inactive_runners(account.id, 24, subject, batch_size: 1)

      assert is_nil(Repo.reload!(runner).deleted_at)
      assert is_nil(Repo.reload!(subscription).runner_quantity_sync_requested_at)
      assert marker_counts(account.id, "runner.retention_swept") == []
    end

    test "a later batch failure preserves earlier deletion, billing request and receipt for retry",
         %{account: account} do
      [first, second] = for index <- 1..2, do: offline_runner(account, name: "retry#{index}")
      subscription = subscription(account)
      fault_second_batch(account.id, "runners")
      dynamic_repo = Repo.get_dynamic_repo()

      try do
        assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
          Runners.delete_inactive_runners(account.id, 24, nil, batch_size: 1)
        end
      after
        Repo.put_dynamic_repo(dynamic_repo)
      end

      assert %DateTime{} = Repo.reload!(first).deleted_at
      assert is_nil(Repo.reload!(second).deleted_at)
      assert %DateTime{} = Repo.reload!(subscription).runner_quantity_sync_requested_at
      assert marker_counts(account.id, "runner.retention_swept") == [1]
      assert Runners.delete_inactive_runners(account.id, 24, nil, batch_size: 1) == {:ok, 1}
      assert marker_counts(account.id, "runner.retention_swept") == [1, 1]
    end
  end

  describe "list_retention_protected_pack_refs/3" do
    test "ignores malformed root and entry JSON without hiding a later advertiser", %{
      account: account
    } do
      malformed =
        for value <- [nil, false, true, 42, "scalar", [], [%{"version" => "v"}]] do
          runner = Fixtures.Runners.create_runner(account_id: account.id)
          corrupt_pack_map(runner, value)
          runner
        end

      runner = Fixtures.Runners.create_runner(account_id: account.id)

      Fixtures.Runners.advertise_packs(runner, %{
        "valid" => %{"version" => "v", "hash" => "h"},
        "null" => nil,
        "false" => false,
        "true" => true,
        "number" => 42,
        "string" => "v",
        "array" => [%{"version" => "v"}]
      })

      refs = Enum.map(~w(null false true number string array valid), &{&1, "v"})
      assert Runners.list_retention_protected_pack_refs(account.id, refs) == [{"valid", "v"}]
      assert Runners.list_advertised_pack_refs(account.id, refs) == [{"valid", "v"}]

      subject = scoped_subject(account, Enum.map([runner | malformed], & &1.id))
      deployments = Enum.map(refs, fn {id, version} -> {id, version, "h"} end)

      assert Runners.list_visible_pack_deployments(deployments, subject) ==
               {:ok, [{"valid", "v", "h"}]}
    end

    test "preserves candidate order and duplicates without multiplying duplicate advertisers", %{
      account: account
    } do
      runners = for _ <- 1..2, do: Fixtures.Runners.create_runner(account_id: account.id)

      for runner <- runners do
        Fixtures.Runners.advertise_packs(runner, %{
          "a" => %{"version" => "v", "hash" => "ha"},
          "b" => %{"version" => "v", "hash" => "hb"}
        })
      end

      refs = [{"b", "v"}, {"a", "v"}, {"missing", "v"}, {"b", "v"}]
      expected = [{"b", "v"}, {"a", "v"}, {"b", "v"}]
      assert Runners.list_retention_protected_pack_refs(account.id, refs) == expected
      assert Runners.list_advertised_pack_refs(account.id, refs) == expected

      subject = scoped_subject(account, Enum.map(runners, & &1.id))
      deployments = [{"b", "v", "hb"}, {"a", "v", "ha"}, {"b", "v", "hb"}, {"a", "v", "ha"}]

      assert Runners.list_visible_pack_deployments(deployments, subject) ==
               {:ok, Enum.reverse(deployments)}

      assert Runners.list_retention_protected_pack_refs(account.id, []) == []
      assert Runners.list_advertised_pack_refs(account.id, []) == []
      assert Runners.list_visible_pack_deployments([], subject) == {:ok, []}
    end

    test "finds matches beyond one hundred unhelpful runners and handles entirely absent refs", %{
      account: account
    } do
      for index <- 1..101 do
        Fixtures.Runners.create_runner(account_id: account.id, name: "unhelpful-#{index}")
      end

      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.advertise_packs(runner, %{"late" => %{"version" => "v", "hash" => "h"}})
      refs = [{"absent", "v"}, {"late", "v"}]
      assert Runners.list_retention_protected_pack_refs(account.id, refs) == [{"late", "v"}]
      assert Runners.list_advertised_pack_refs(account.id, refs) == [{"late", "v"}]
      assert Runners.list_retention_protected_pack_refs(account.id, [{"absent", "v"}]) == []

      # Group scope includes the unhelpful prefix as well as the eventual match.
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      {:ok, access} = Accounts.RunnerAccess.restricted([runner.group], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert Runners.list_visible_pack_deployments(
               [{"absent", "v", "h"}, {"late", "v", "h"}],
               subject
             ) == {:ok, [{"late", "v", "h"}]}
    end

    test "JSON default-version semantics preserve map types instead of coercing values", %{
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      values = [nil, false, true, 1, ["v"], %{"x" => "v"}, "v"]

      packs =
        Map.new(Enum.with_index(values), fn {version, index} ->
          {"p#{index}", %{"version" => version}}
        end)

      packs = Map.merge(packs, %{"missing" => %{}, "not-map" => "v"})
      Fixtures.Runners.advertise_packs(runner, packs)

      refs = [
        {"p0", "unknown"},
        {"p1", "unknown"},
        {"p2", "true"},
        {"p3", "1"},
        {"p4", "v"},
        {"p5", "v"},
        {"p6", "v"},
        {"missing", "unknown"},
        {"not-map", "unknown"}
      ]

      assert Runners.list_retention_protected_pack_refs(account.id, refs) ==
               [{"p0", "unknown"}, {"p1", "unknown"}, {"p6", "v"}, {"missing", "unknown"}]
    end
  end

  describe "list_visible_pack_deployments/3" do
    test "requires string hashes without coercing malformed JSON or accepting hidden advertisers",
         %{
           account: account
         } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      hashes = [nil, false, true, 42, ["h"], %{"hash" => "h"}, "h", ""]

      packs =
        Map.new(Enum.with_index(hashes), fn {hash, index} ->
          {"hash#{index}", %{"version" => "v", "hash" => hash}}
        end)

      Fixtures.Runners.advertise_packs(runner, Map.put(packs, "missing", %{"version" => "v"}))
      subject = scoped_subject(account, [runner.id])
      hidden = Fixtures.Runners.create_runner(account_id: account.id)
      foreign = Fixtures.Runners.create_runner()

      for advertiser <- [hidden, foreign] do
        Fixtures.Runners.advertise_packs(advertiser, %{
          "hash0" => %{"version" => "v", "hash" => "null"},
          "hidden" => %{"version" => "v", "hash" => "h"}
        })
      end

      candidates =
        Enum.with_index(["null", "false", "true", "42", "h", "h", "h", ""], fn hash, index ->
          {"hash#{index}", "v", hash}
        end) ++ [{"missing", "v", ""}, {"hidden", "v", "h"}]

      assert Runners.list_visible_pack_deployments(candidates, subject) ==
               {:ok, [{"hash7", "v", ""}, {"hash6", "v", "h"}]}

      membership = Repo.get!(Accounts.Membership, subject.membership_id)
      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())
      assert Runners.list_visible_pack_deployments(candidates, subject) == {:ok, []}
    end

    test "matches exact string version/hash in fresh scope and excludes another account", %{
      account: account
    } do
      mine = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      other = Fixtures.Runners.create_runner()

      Fixtures.Runners.advertise_packs(mine, %{
        "p" => %{"version" => "v", "hash" => "h"},
        "numeric" => %{"version" => 1, "hash" => "h"}
      })

      Fixtures.Runners.advertise_packs(other, %{"foreign" => %{"version" => "v", "hash" => "h"}})
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      {:ok, access} = Accounts.RunnerAccess.restricted(["db"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      candidates = [
        {"p", "v", "h"},
        {"p", "v", "wrong"},
        {"numeric", "1", "h"},
        {"foreign", "v", "h"}
      ]

      assert Runners.list_visible_pack_deployments(candidates, subject) ==
               {:ok, [{"p", "v", "h"}]}

      Fixtures.Runners.move_to_group(mine, "hidden")
      assert Runners.list_visible_pack_deployments(candidates, subject) == {:ok, []}
      denied = Fixtures.Subjects.permissionless_subject(account)
      assert Runners.list_visible_pack_deployments(candidates, denied) == {:error, :unauthorized}
    end
  end

  describe "delete_unseen_pack_versions/4" do
    test "each manual batch rechecks management authority and preserves earlier receipts", %{
      account: account
    } do
      first = stale_version(account, "first", "v1")
      second = stale_version(account, "second", "v1")
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      id = {__MODULE__, self(), make_ref()}

      :telemetry.attach(
        id,
        [:emisar, :repo, :query],
        &__MODULE__.demote_on_second_pack_batch/4,
        %{
          owner: self(),
          membership: membership,
          counter: :atomics.new(1, [])
        }
      )

      try do
        assert {:error, :unauthorized} =
                 Catalog.delete_unseen_pack_versions(account.id, 30, subject, batch_size: 1)
      after
        :telemetry.detach(id)
      end

      assert is_nil(Repo.reload(first))
      assert Repo.reload!(second)
      assert marker_counts(account.id, "pack_retention_swept") == [1]
    end

    test "lexical pack/version cursor crosses ties and a protected head exactly once", %{
      account: account
    } do
      # Creation/UUID order deliberately differs from the indexed traversal;
      # lexical 10 precedes 2, and version 2 appears under both pack IDs.
      removed = [
        stale_version(account, "b", "2.0.0"),
        stale_version(account, "a", "unknown"),
        stale_version(account, "a", "3.0.0")
      ]

      protected = [
        stale_version(account, "a", "2.0.0"),
        stale_version(account, "a", "10.0.0")
      ]

      for version <- protected do
        runner = Fixtures.Runners.create_runner(account_id: account.id)

        Fixtures.Runners.advertise_packs(runner, %{
          version.pack_id => %{"version" => version.version}
        })
      end

      foreign = stale_version(Fixtures.Accounts.create_account(), "a", "3.0.0")
      observe_queries(account.id)

      assert Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 2) == {:ok, 3}
      pages = queries() |> Enum.filter(&String.contains?(&1.query, "FOR NO KEY UPDATE"))
      assert Enum.map(pages, & &1.rows) == [2, 2, 1, 0]
      assert Enum.all?(pages, &(length(&1.columns) == 6))
      assert Enum.all?(protected, &Repo.reload/1)
      assert Enum.all?(removed, &is_nil(Repo.reload(&1)))
      assert Repo.reload(foreign)
      assert marker_counts(account.id, "pack_retention_swept") == [1, 2]

      assert Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 2) == {:ok, 0}
      assert marker_counts(account.id, "pack_retention_swept") == [1, 2]
    end

    test "advances past a protected page, deletes exact pairs with one action statement per batch",
         %{account: account} do
      live = Fixtures.Runners.create_runner(account_id: account.id)
      protected = for index <- 1..2, do: stale_version(account, "protected#{index}", "v")

      Fixtures.Runners.advertise_packs(
        live,
        Map.new(protected, &{&1.pack_id, %{"version" => &1.version}})
      )

      removed = for index <- 1..3, do: stale_version(account, "remove#{index}", "v")
      actions = for version <- removed, do: action(live, version)

      cross_pair =
        Fixtures.Catalog.create_action(
          runner: live,
          action_id: "keep.cross",
          pack_id: "remove1",
          pack_version: "other"
        )

      other_account = Fixtures.Accounts.create_account()
      other_pin = stale_version(other_account, "remove1", "v")
      observe_queries(account.id)

      assert Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 2) == {:ok, 3}
      queries = queries()
      pages = Enum.filter(queries, &String.contains?(&1.query, "FOR NO KEY UPDATE"))
      assert Enum.map(pages, & &1.rows) == [2, 2, 1, 0]
      assert Enum.all?(pages, &(length(&1.columns) == 6))

      assert Enum.count(
               queries,
               &String.starts_with?(&1.query, "DELETE FROM \"catalog_runner_actions\"")
             ) == 2

      assert Enum.all?(protected, &Repo.reload/1)
      assert Enum.all?(removed ++ actions, &is_nil(Repo.reload(&1)))
      assert Repo.reload(cross_pair)
      assert Repo.reload(other_pin)
      assert marker_counts(account.id, "pack_retention_swept") == [1, 2]
      assert Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 2) == {:ok, 0}
    end

    test "manual scan advances through an entirely out-of-scope page and uses the pending hash",
         %{account: account} do
      hidden = for index <- 1..2, do: stale_version(account, "hidden#{index}", "v")

      visible =
        Fixtures.Catalog.create_observed_pack_version(
          account_id: account.id,
          pack_id: "visible",
          version: "v",
          hash: "old",
          pending_hash: "new"
        )

      Fixtures.Catalog.backdate_pack_version_last_seen(visible, old_seen())
      runner = offline_runner(account, group: "db")

      Fixtures.Runners.advertise_packs(runner, %{
        "visible" => %{"version" => "v", "hash" => visible.pending_hash}
      })

      subject = scoped_subject(account, [runner.id])

      assert Catalog.delete_unseen_pack_versions(account.id, 30, subject, batch_size: 2) ==
               {:ok, 1}

      assert Enum.all?(hidden, &Repo.reload/1)
      refute Repo.reload(visible)
      assert marker_counts(account.id, "pack_retention_swept") == [1]
    end

    test "audit failure rolls back both actions and pins and emits no receipt", %{
      account: account,
      subject: subject
    } do
      version = stale_version(account, "rollback", "v")
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      action = action(runner, version)
      subject = %{subject | context: %Emisar.RequestContext{request_id: %{invalid: true}}}

      assert {:error, %Ecto.Changeset{}} =
               Catalog.delete_unseen_pack_versions(account.id, 30, subject, batch_size: 1)

      assert Repo.reload(version)
      assert Repo.reload(action)
      assert marker_counts(account.id, "pack_retention_swept") == []
    end

    test "a later batch failure preserves earlier pins/actions removal and retries only the remainder",
         %{account: account} do
      [first, second] = for index <- 1..2, do: stale_version(account, "retry#{index}", "v")
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      first_action = action(runner, first)
      second_action = action(runner, second)
      fault_second_batch(account.id, "catalog_pack_versions")
      dynamic_repo = Repo.get_dynamic_repo()

      try do
        assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
          Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 1)
        end
      after
        Repo.put_dynamic_repo(dynamic_repo)
      end

      refute Repo.reload(first)
      refute Repo.reload(first_action)
      assert Repo.reload(second)
      assert Repo.reload(second_action)
      assert marker_counts(account.id, "pack_retention_swept") == [1]
      assert Catalog.delete_unseen_pack_versions(account.id, 30, nil, batch_size: 1) == {:ok, 1}
      assert marker_counts(account.id, "pack_retention_swept") == [1, 1]
    end
  end

  describe "delete_unadvertised_retired_pack_versions/2" do
    test "protected and nonretired head pages do not hide a retired tail", %{account: account} do
      {pack_id, watermark} = PackBaseline.retired_below() |> Enum.sort() |> hd()

      kept =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: watermark
        )

      advertised =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.0"
        )

      offline = offline_runner(account)
      Fixtures.Runners.advertise_packs(offline, %{pack_id => %{"version" => "0.0.0"}})

      removed =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "0.0.1"
        )

      malformed =
        Fixtures.Catalog.create_trusted_pack_version(
          account_id: account.id,
          pack_id: pack_id,
          version: "unknown"
        )

      assert Catalog.delete_unadvertised_retired_pack_versions(account.id, batch_size: 1) ==
               {:ok, 2}

      assert Repo.reload(kept)
      assert Repo.reload(advertised)
      # PackBaseline deliberately retires malformed published-pack versions.
      refute Repo.reload(malformed)
      refute Repo.reload(removed)
      assert marker_counts(account.id, "pack_retirement_swept") == [1, 1]
    end
  end

  def observe_query(_event, _measurements, metadata, %{account_id: account_id, owner: owner}) do
    if account_id in metadata.params do
      case metadata.result do
        {:ok, %{num_rows: rows, columns: columns}} ->
          send(owner, {:retention_query, %{query: metadata.query, rows: rows, columns: columns}})

        _ ->
          :ok
      end
    end
  end

  # Fail the next database operation AFTER the second batch has locked its
  # candidates. Ecto's documented dynamic repo is process-local: no production
  # hook, global adapter override, database trigger or concurrent test changes.
  def fail_second_batch(_event, _measurements, metadata, %{
        owner: owner,
        account_id: account_id,
        table: table,
        counter: counter
      }) do
    if self() == owner and account_id in metadata.params and
         String.contains?(metadata.query, "FROM \"#{table}\"") and
         String.contains?(metadata.query, "FOR NO KEY UPDATE") and
         :atomics.add_get(counter, 1, 1) == 2 do
      Repo.put_dynamic_repo(:retention_batch_unavailable_repo)
    end
  end

  def demote_on_second_pack_batch(_event, _measurements, metadata, %{
        owner: owner,
        membership: membership,
        counter: counter
      }) do
    if self() == owner and String.contains?(metadata.query, "FROM \"accounts\"") and
         String.contains?(metadata.query, "FOR NO KEY UPDATE") and
         :atomics.add_get(counter, 1, 1) == 2 do
      Fixtures.Memberships.force_role(membership, "viewer")
    end
  end

  defp fault_second_batch(account_id, table) do
    id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(id, [:emisar, :repo, :query], &__MODULE__.fail_second_batch/4, %{
      account_id: Ecto.UUID.dump!(account_id),
      owner: self(),
      table: table,
      counter: :atomics.new(1, [])
    })

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp observe_queries(account_id) do
    id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(id, [:emisar, :repo, :query], &__MODULE__.observe_query/4, %{
      account_id: Ecto.UUID.dump!(account_id),
      owner: self()
    })

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp queries(acc \\ []) do
    receive do
      {:retention_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp offline_runner(account, attrs \\ []) do
    runner = Fixtures.Runners.create_runner([account_id: account.id, connected?: false] ++ attrs)

    Fixtures.Runners.mark_disconnected_at(
      runner,
      DateTime.add(DateTime.utc_now(), -48 * 3600, :second)
    )
  end

  # Exercise stored JSON values the map-typed schema cannot load or construct.
  # Explicit text-to-jsonb avoids Postgrex encoding the serialized JSON twice.
  defp corrupt_pack_map(runner, packs) do
    Repo.query!("UPDATE runners SET packs = $1::text::jsonb WHERE id = $2", [
      Jason.encode!(packs),
      Ecto.UUID.dump!(runner.id)
    ])
  end

  defp old_seen, do: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

  defp stale_version(account, pack_id, version) do
    Fixtures.Catalog.create_trusted_pack_version(
      account_id: account.id,
      pack_id: pack_id,
      version: version
    )
    |> Fixtures.Catalog.backdate_pack_version_last_seen(old_seen())
  end

  defp action(runner, version) do
    Fixtures.Catalog.create_action(
      runner: runner,
      action_id: "#{version.pack_id}.check",
      pack_id: version.pack_id,
      pack_version: version.version
    )
  end

  defp marker_counts(account_id, type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type(type)
    |> Repo.all()
    |> Enum.map(& &1.payload["count"])
    |> Enum.sort()
  end

  defp scoped_subject(account, ids) do
    {:ok, access} = Accounts.RunnerAccess.restricted([], ids)

    Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    |> Fixtures.Memberships.force_runner_access(access)
    |> Fixtures.Subjects.membership_subject()
  end

  defp subscription(account) do
    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: "sub_#{account.id}",
        paddle_price_id: "pri_team",
        plan: "team",
        status: "active",
        collection_mode: "automatic"
      })

    {:ok, subscription} =
      Billing.upsert_subscription(account.id, %{
        paddle_subscription_id: subscription.paddle_subscription_id,
        runner_quantity_sync_requested_at: nil
      })

    subscription
  end
end
