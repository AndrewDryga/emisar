defmodule Emisar.Repo.CursorFieldsTest do
  @moduledoc """
  Authoring-time lint: every `cursor_fields/0` entry is non-null on reachable rows.

  `Paginator.encode_cursor/3` reads each cursor field with `Map.fetch!/2` and
  hands it to `encode_value/1`, whose last clause raises on a value it has no
  tag for — `nil` included. A nil-tolerant encoder would be worse, not better:
  the keyset predicate is `col > NULL`, which is NULL, so the page after a nil
  boundary comes back empty and the tail of the list silently disappears. The
  raise is the right runtime behaviour; this is the check that stops the
  declaration from being written, which is where the problem is fixable.

  `SSO.DirectoryGroup.Query` declared exactly that — `external_group_id` stopped
  being `NOT NULL` in `20260927000000` — and nothing noticed because
  `Repo.list/3` never reached it.

  Schema-backed cursors retain the database constraint check. The explicitly
  named SQL projections instead execute their nullable-source contracts and
  walk every expected boundary in both directions. An unregistered projection
  or a changed cursor declaration fails closed.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Catalog, Fixtures, Policies, Runners}

  test "every declared cursor field is NOT NULL on the rows a list can reach" do
    for {query_module, cursor_fields} <- cursor_field_declarations() do
      assert_cursor_fields(query_module, cursor_fields)
    end
  end

  test "an unregistered schema-less query cannot bypass the cursor contract" do
    assert_raise ExUnit.AssertionError,
                 ~r/needs a schema or an executable projection contract/,
                 fn ->
                   assert_cursor_fields(Runners.ScopeTarget.Query, [
                     {:scope_targets, :asc, :label}
                   ])
                 end
  end

  test "schema-backed nullable fields still fail the database constraint check" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_cursor_fields(Audit.Event.Query, [{:events, :asc, :actor_label}])
    end
  end

  test "a derived cursor declaration cannot grow without updating its contract" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_cursor_fields(Audit.IdentityOption.Query, [{:audit_identity_options, :asc, :label}])
    end
  end

  defp assert_cursor_fields(Audit.IdentityOption.Query, cursor_fields) do
    assert cursor_fields == [
             {:audit_identity_options, :asc, :sort_label},
             {:audit_identity_options, :asc, :id}
           ]

    account = Fixtures.Accounts.create_account()
    unnamed = Fixtures.Users.create_user(full_name: nil)

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: unnamed.id,
      role: "owner"
    )

    subject = Fixtures.Subjects.subject_for(unnamed, account, role: :owner)

    directory = Fixtures.Users.create_user(full_name: "Global name")

    membership =
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: directory.id)

    Fixtures.Memberships.sync_display_name(membership, "Same label")
    deleted = Fixtures.Users.create_user(full_name: "Deleted current name")
    Fixtures.Memberships.create_membership(account_id: account.id, user_id: deleted.id)
    Fixtures.Users.mark_user_as_deleted(deleted)
    historical_id = Ecto.UUID.generate()
    unknown_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    identity_event(account, "user", unnamed.id, nil)
    identity_event(account, "user", directory.id, "Old directory name")
    identity_event(account, "user", deleted.id, "Old deleted name")
    identity_event(account, "user", historical_id, "Old snapshot", DateTime.add(now, -3))
    identity_event(account, "user", historical_id, "Same label", DateTime.add(now, -2))
    identity_event(account, "user", historical_id, "   ", DateTime.add(now, -1))
    identity_event(account, "user", historical_id, nil, now)
    identity_event(account, "user", unknown_id, nil)
    identity_event(account, "user", nil, "Missing identity")
    foreign = Fixtures.Accounts.create_account()
    identity_event(foreign, "user", historical_id, "Foreign snapshot")

    expected =
      Enum.sort([
        [unnamed.email, unnamed.id],
        ["Same label", directory.id],
        ["Deleted current name", deleted.id],
        ["Same label", historical_id]
      ])

    events = Audit.Event.Query.all() |> Audit.Authorizer.for_subject(subject)

    for side <- [:actor, :target] do
      query = Audit.IdentityOption.Query.all("user", side, account.id, events)
      read = query_reader(query, Audit.IdentityOption.Query)
      assert_projection_pages(Audit.IdentityOption.Query, read, expected)
    end

    {_raw, named_key} =
      Fixtures.Runners.create_enrollment_key(
        account_id: account.id,
        created_by_id: unnamed.id,
        description: "Current key"
      )

    {_raw, unnamed_key} =
      Fixtures.Runners.create_enrollment_key(account_id: account.id, created_by_id: unnamed.id)

    assert unnamed_key.description == nil
    identity_event(account, "enrollment_key", named_key.id, nil)
    identity_event(account, "enrollment_key", unnamed_key.id, "Historical key")
    query = Audit.IdentityOption.Query.all("enrollment_key", :target, account.id, events)
    expected = [["Current key", named_key.id], ["Historical key", unnamed_key.id]]
    read = query_reader(query, Audit.IdentityOption.Query)
    assert_projection_pages(Audit.IdentityOption.Query, read, expected)
  end

  defp assert_cursor_fields(Policies.Target.Query, cursor_fields) do
    assert cursor_fields == [
             {:policy_targets, :asc, :group_sort},
             {:policy_targets, :asc, :kind_sort},
             {:policy_targets, :asc, :label},
             {:policy_targets, :asc, :scope_value}
           ]

    assert_schema_cursor_fields(Runners.Runner.Query, [
      {:runners, :asc, :name},
      {:runners, :asc, :id}
    ])

    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    [first_blank, second_blank] =
      for name <- ["First blank", "Second blank"] do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: name,
          connected?: false
        )
      end

    Fixtures.Runners.move_to_group(first_blank, "")
    Fixtures.Runners.move_to_group(second_blank, "")

    grouped =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "database",
        group: "database",
        connected?: false
      )

    policy =
      Fixtures.Policies.create_policy(
        account_id: account.id,
        created_by_id: user.id,
        scope_type: :runner,
        scope_value: grouped.id
      )

    Fixtures.Runners.create_runner(name: "Foreign", group: "database", connected?: false)
    runner_ids = [first_blank.id, second_blank.id]
    {:ok, access} = Accounts.RunnerAccess.restricted(["database", "empty"], runner_ids)

    query =
      account.id
      |> Runners.scope_targets_query(access)
      |> Policies.Target.Query.all()
      |> Policies.Target.Query.with_policy()

    expected =
      Enum.sort([
        ["", 1, "First blank", first_blank.id],
        ["", 1, "Second blank", second_blank.id],
        ["database", 0, "database", "database"],
        ["database", 1, "database", grouped.id],
        ["empty", 0, "empty", "empty"]
      ])

    read = query_reader(query, Policies.Target.Query)
    rows = assert_projection_pages(Policies.Target.Query, read, expected)
    assert Enum.count(rows, &is_nil(&1.policy_id)) == 4
    assert Enum.find(rows, &(&1.scope_value == grouped.id)).policy_id == policy.id
  end

  defp assert_cursor_fields(Catalog.ActionRisk.Query, cursor_fields) do
    assert cursor_fields == [{:runner_actions, :asc, :action_id}]
    assert_schema_cursor_fields(Catalog.RunnerAction.Query, cursor_fields)
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.membership_subject(membership)

    [first, second] =
      for _ <- 1..2 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "database",
          connected?: false
        )
      end

    for action_id <- ["db.a", "db.b", "db.c"] do
      Fixtures.Catalog.create_action(runner: first, action_id: action_id, risk: "low")
    end

    for action_id <- ["db.b", "db.d"] do
      Fixtures.Catalog.create_action(runner: second, action_id: action_id, risk: "critical")
    end

    outside =
      Fixtures.Runners.create_runner(account_id: account.id, group: "other", connected?: false)

    Fixtures.Catalog.create_action(runner: outside, action_id: "other.action")
    foreign = Fixtures.Runners.create_runner(connected?: false)
    Fixtures.Catalog.create_action(runner: foreign, action_id: "foreign.action")

    for {target, expected} <- [
          {:account, [["db.a"], ["db.b"], ["db.c"], ["db.d"], ["other.action"]]},
          {{:runner, first.id}, [["db.a"], ["db.b"], ["db.c"]]},
          {{:group, "database"}, [["db.a"], ["db.b"], ["db.c"], ["db.d"]]}
        ] do
      read = &Catalog.list_action_risks(target, subject, page: &1)
      assert_projection_pages(Catalog.ActionRisk.Query, read, expected)
    end
  end

  defp assert_cursor_fields(query_module, cursor_fields) do
    assert_schema_cursor_fields(query_module, cursor_fields)
  end

  defp assert_schema_cursor_fields(query_module, cursor_fields) do
    assert cursor_fields != [], "#{inspect(query_module)} declares an empty cursor"

    nullable =
      for {_binding, _order, field} <- cursor_fields,
          {table, column} = table_and_column(query_module, field),
          nullable_column?(table, column),
          not live_rows_not_null?(table, column),
          do: "#{inspect(query_module)} → #{table}.#{column}"

    assert nullable == []
  end

  defp query_reader(query, query_module) do
    &Repo.list(query, query_module, page: &1, count: false)
  end

  defp assert_projection_pages(query_module, read, expected) do
    assert expected != []
    fields = query_module.cursor_fields()

    {rows, last_metadata} =
      Enum.map_reduce(expected, nil, fn expected_values, previous_metadata ->
        page =
          case previous_metadata do
            nil ->
              [limit: 1]

            %{next_page_cursor: cursor} ->
              assert is_binary(cursor), "projection ended before #{inspect(expected_values)}"
              [limit: 1, cursor: cursor]
          end

        assert {:ok, [row], metadata} = read.(page)
        values = Enum.map(fields, fn {_binding, _order, field} -> Map.fetch!(row, field) end)
        refute nil in values
        assert values == expected_values
        {row, metadata}
      end)

    assert last_metadata.next_page_cursor == nil
    earlier_rows = rows |> Enum.drop(-1) |> Enum.reverse()

    first_cursor =
      Enum.reduce(earlier_rows, last_metadata.previous_page_cursor, fn expected_row, cursor ->
        assert is_binary(cursor)
        assert {:ok, [^expected_row], metadata} = read.(limit: 1, cursor: cursor)
        metadata.previous_page_cursor
      end)

    assert first_cursor == nil
    rows
  end

  defp identity_event(account, kind, id, label, occurred_at \\ DateTime.utc_now()) do
    assert {:ok, event} =
             Audit.log(account.id, "user.updated",
               actor_kind: kind,
               actor_id: id,
               actor_label: label,
               target_kind: kind,
               target_id: id,
               target_label: label,
               occurred_at: occurred_at
             )

    event
  end

  defp cursor_field_declarations do
    {:ok, modules} = :application.get_key(:emisar, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :cursor_fields, 0),
        do: {module, module.cursor_fields()}
  end

  defp table_and_column(query_module, field) do
    schema =
      try do
        query_module |> Module.split() |> Enum.drop(-1) |> Module.safe_concat()
      rescue
        ArgumentError -> nil
      end

    assert schema && Code.ensure_loaded?(schema) && function_exported?(schema, :__schema__, 1),
           "#{inspect(query_module)} needs a schema or an executable projection contract"

    {schema.__schema__(:source), schema.__schema__(:field_source, field)}
  end

  defp nullable_column?(table, column) do
    query = """
    SELECT is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
    """

    case Repo.query!(query, [table, Atom.to_string(column)]) do
      %{rows: [["YES"]]} -> true
      %{rows: [["NO"]]} -> false
      %{rows: []} -> flunk("cursor field #{table}.#{column} does not exist")
    end
  end

  # A soft-delete table may leave a column nullable for TOMBSTONES while a CHECK
  # requires it on every live row — `sso_directory_group_role_mappings` does. Every
  # list pipeline starts at `not_deleted/1` (AGENTS.md §2), so such a column cannot
  # reach a cursor as nil. Read the constraint rather than keep a second hand list:
  # dropping the CHECK must make this fire.
  defp live_rows_not_null?(table, column) do
    query = """
    SELECT pg_get_constraintdef(oid)
    FROM pg_constraint
    WHERE contype = 'c' AND conrelid = to_regclass($1)
    """

    %{rows: rows} = Repo.query!(query, [table])

    Enum.any?(rows, fn [definition] ->
      String.contains?(definition, "deleted_at IS NOT NULL") and
        String.contains?(definition, "#{column} IS NOT NULL")
    end)
  end
end
