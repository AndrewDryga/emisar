defmodule Emisar.RunnerAccessTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Audit, Catalog, Fixtures, Policies, Repo, Runners, Runs}

  describe "RunnerAccess" do
    test "normalizes restricted access and rejects ambiguous shapes" do
      runner_id = Ecto.UUID.generate()

      assert {:ok,
              %RunnerAccess{
                mode: :restricted,
                groups: ["app", "db"],
                runner_ids: [^runner_id]
              }} = RunnerAccess.restricted([" db ", "app", "db"], [runner_id, runner_id])

      assert RunnerAccess.new(:restricted, [], []) == {:error, :invalid_runner_access}
      assert RunnerAccess.new(:none, ["db"], []) == {:error, :invalid_runner_access}
      assert RunnerAccess.new(:all, [], [runner_id]) == {:error, :invalid_runner_access}
      assert RunnerAccess.new(:restricted, [], ["not-a-uuid"]) == {:error, :invalid_runner_access}
    end

    test "unions directory grants with all dominance" do
      runner_id = Ecto.UUID.generate()
      {:ok, group_access} = RunnerAccess.restricted(["db"], [])
      {:ok, runner_access} = RunnerAccess.restricted([], [runner_id])

      assert RunnerAccess.union([RunnerAccess.none(), group_access, runner_access]) ==
               %RunnerAccess{mode: :restricted, groups: ["db"], runner_ids: [runner_id]}

      assert RunnerAccess.union([group_access, RunnerAccess.all()]) == RunnerAccess.all()
    end

    test "coverage is monotonic and explicit" do
      {:ok, db} = RunnerAccess.restricted(["db"], [])
      {:ok, db_and_app} = RunnerAccess.restricted(["db", "app"], [])

      assert RunnerAccess.covers?(RunnerAccess.all(), db_and_app)
      assert RunnerAccess.covers?(db_and_app, db)
      assert RunnerAccess.covers?(db, RunnerAccess.none())
      refute RunnerAccess.covers?(db, db_and_app)
      refute RunnerAccess.covers?(RunnerAccess.none(), db)
    end

    test "normalizes a restricted pack scope and rejects an unusable one" do
      assert {:ok, access} =
               RunnerAccess.new(:all, [], [], :restricted, [" shell ", "postgres", "postgres"])

      assert access.pack_mode == :restricted
      assert access.pack_ids == ["postgres", "shell"]

      assert RunnerAccess.new(:all, [], [], :restricted, []) == {:error, :invalid_pack_access}
      assert RunnerAccess.new(:all, [], [], :all, ["postgres"]) == {:error, :invalid_pack_access}
      assert RunnerAccess.new(:all, [], [], "everything", []) == {:error, :invalid_pack_access}
    end

    test "a grant reaching no runner carries no pack restriction" do
      assert RunnerAccess.none().pack_mode == :all
      assert RunnerAccess.none().pack_ids == []

      assert RunnerAccess.new(:none, [], [], :restricted, ["postgres"]) ==
               {:error, :invalid_pack_access}
    end

    test "packs union across the grants that reach runners, never through a none grant" do
      {:ok, db} = RunnerAccess.new(:restricted, ["db"], [], :restricted, ["postgres"])
      {:ok, web} = RunnerAccess.new(:restricted, ["web"], [], :restricted, ["nginx"])

      # A grant with no reach must not contribute its default `all` packs.
      assert RunnerAccess.union([RunnerAccess.none(), db]) == db

      assert RunnerAccess.union([db, web]) ==
               %RunnerAccess{
                 mode: :restricted,
                 groups: ["db", "web"],
                 runner_ids: [],
                 pack_mode: :restricted,
                 pack_ids: ["nginx", "postgres"]
               }

      assert RunnerAccess.union([db, RunnerAccess.all()]) == RunnerAccess.all()
    end

    test "coverage checks the pack dimension too" do
      {:ok, one_pack} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      {:ok, two_packs} = RunnerAccess.new(:all, [], [], :restricted, ["postgres", "shell"])

      assert RunnerAccess.covers?(RunnerAccess.all(), two_packs)
      assert RunnerAccess.covers?(two_packs, one_pack)
      assert RunnerAccess.covers?(one_pack, RunnerAccess.none())
      refute RunnerAccess.covers?(one_pack, two_packs)
      # Wider runners never buy a wider pack list.
      refute RunnerAccess.covers?(one_pack, RunnerAccess.all())
    end
  end

  describe "pack_in_scope?/2" do
    test "an unrestricted grant runs every pack and a restricted one only its own" do
      {:ok, restricted} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      assert RunnerAccess.pack_in_scope?("shell", RunnerAccess.all())
      assert RunnerAccess.pack_in_scope?("postgres", restricted)
      refute RunnerAccess.pack_in_scope?("shell", restricted)
      refute RunnerAccess.pack_in_scope?("postgres", RunnerAccess.none())
      # An action with no pack identity cannot be matched against a list.
      refute RunnerAccess.pack_in_scope?(nil, restricted)
      refute RunnerAccess.pack_in_scope?("", restricted)
      assert RunnerAccess.pack_in_scope?(nil, RunnerAccess.all())
    end
  end

  describe "pack_selection_refs/1" do
    test "canonicalizes pack refs and refuses anything else" do
      assert RunnerAccess.pack_selection_refs(["pack:shell", "pack:postgres", "pack:shell"]) ==
               {:ok, ["postgres", "shell"]}

      assert RunnerAccess.pack_selection_refs([]) == {:ok, []}

      for values <- [["postgres"], ["pack:"], ["group:db"], [%{"crafted" => "all"}]] do
        assert RunnerAccess.pack_selection_refs(values) == {:error, :invalid_pack_access}
      end
    end
  end

  describe "from_selection/5" do
    setup do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      web = %{id: Ecto.UUID.generate(), group: "web"}
      ungrouped = %{id: Ecto.UUID.generate(), group: nil}
      %{database: database, web: web, runners: [database, web, ungrouped]}
    end

    test "none and all ignore the selection", %{runners: runners} do
      assert RunnerAccess.from_selection("none", ["group:database"], runners) ==
               {:ok, RunnerAccess.none()}

      assert RunnerAccess.from_selection(:all, [], runners) == {:ok, RunnerAccess.all()}
    end

    test "restricted drops a runner its selected group already covers", %{
      database: database,
      web: web,
      runners: runners
    } do
      values = ["group:database", "runner:#{database.id}", "runner:#{web.id}"]

      assert RunnerAccess.from_selection("restricted", values, runners) ==
               {:ok,
                %RunnerAccess{
                  mode: :restricted,
                  groups: ["database"],
                  runner_ids: [web.id]
                }}
    end

    test "an empty, malformed, or unknown selection fails closed", %{
      database: database,
      runners: runners
    } do
      unknown_runner_id = Ecto.UUID.generate()

      for values <- [
            [],
            ["database"],
            ["group:"],
            ["group:staging"],
            ["runner:#{unknown_runner_id}"],
            ["runner:not-a-uuid"],
            [%{"crafted" => "all"}]
          ] do
        assert RunnerAccess.from_selection("restricted", values, runners) ==
                 {:error, :invalid_runner_access}
      end

      # An unrecognized mode is refused whatever the selection carries.
      assert RunnerAccess.from_selection("everything", ["runner:#{database.id}"], runners) ==
               {:error, :invalid_runner_access}
    end

    test "a group selector is trimmed and deduplicated before it is allowlisted", %{
      runners: runners
    } do
      values = ["group:  database  ", "group:database"]

      assert RunnerAccess.from_selection("restricted", values, runners) ==
               {:ok, %RunnerAccess{mode: :restricted, groups: ["database"], runner_ids: []}}
    end

    test "a restricted pack selection is allowlisted against the account's packs", %{
      runners: runners
    } do
      allowlist = %{
        groups: ["database"],
        runners: runners,
        packs: ["postgres", "shell"]
      }

      assert RunnerAccess.from_selection("all", [], allowlist, "restricted", ["pack:postgres"]) ==
               {:ok,
                %RunnerAccess{
                  mode: :all,
                  groups: [],
                  runner_ids: [],
                  pack_mode: :restricted,
                  pack_ids: ["postgres"]
                }}

      # A pack the account does not carry fails the whole selection rather than
      # resolving to the part that existed.
      assert RunnerAccess.from_selection(
               "all",
               [],
               allowlist,
               "restricted",
               ["pack:postgres", "pack:unknown"]
             ) == {:error, :invalid_pack_access}

      assert RunnerAccess.from_selection("all", [], allowlist, "restricted", []) ==
               {:error, :invalid_pack_access}
    end

    test "a pack selection is dropped when the grant reaches no runner", %{runners: runners} do
      allowlist = %{groups: ["database"], runners: runners, packs: ["postgres"]}

      assert RunnerAccess.from_selection("none", [], allowlist, "restricted", ["pack:postgres"]) ==
               {:ok, RunnerAccess.none()}
    end

    test "an explicit allowlist resolves exactly the refs the lookup answered for", %{
      database: database
    } do
      allowlist = %{groups: ["database"], runners: [database]}

      assert RunnerAccess.from_selection("restricted", ["group:database"], allowlist) ==
               {:ok, %RunnerAccess{mode: :restricted, groups: ["database"], runner_ids: []}}

      # The lookup resolved the group but not this id, so the whole selection
      # fails rather than granting the half that existed.
      values = ["group:database", "runner:#{Ecto.UUID.generate()}"]

      assert RunnerAccess.from_selection("restricted", values, allowlist) ==
               {:error, :invalid_runner_access}
    end
  end

  describe "selection_refs/1" do
    test "canonicalizes the refs an allowlist lookup is asked about" do
      lower = Ecto.UUID.generate()
      upper = String.upcase(lower)

      values = ["group: web ", "group:app", "group:web", "runner:#{upper}", "runner:#{lower}"]

      assert RunnerAccess.selection_refs(values) == {:ok, {["app", "web"], [lower]}}
    end

    test "a malformed ref never reaches the lookup" do
      for values <- [
            ["database"],
            ["group:"],
            ["group:   "],
            ["runner:not-a-uuid"],
            ["runner:#{RunnerAccess.none_runner_id()}"],
            [%{"crafted" => "all"}],
            List.duplicate("group:web", 257)
          ] do
        assert RunnerAccess.selection_refs(values) == {:error, :invalid_runner_access}
      end
    end
  end

  describe "update_membership_runner_access/3" do
    setup do
      {account, owner, owner_subject} = account_with_owner()
      member = create_member(account, "operator")
      member_subject = Fixtures.Subjects.membership_subject(member)

      %{
        account: account,
        owner: owner,
        owner_subject: owner_subject,
        member: member,
        member_subject: member_subject
      }
    end

    test "new account owners explicitly receive all access", %{
      account: account,
      owner: owner
    } do
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert membership.runner_access_mode == :all

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.all()
    end

    test "none, all, and restricted remain distinct", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      db = Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")
      edge = Fixtures.Runners.create_runner(account_id: account.id, name: "edge-1", group: "edge")
      _app = Fixtures.Runners.create_runner(account_id: account.id, name: "app-1", group: "app")

      assert {:ok, all_runners, %{count: 3}} = Runners.list_runners_for_account(member_subject)
      assert Enum.sort(Enum.map(all_runners, & &1.name)) == ["app-1", "db-1", "edge-1"]

      assert {:ok, _membership} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert {:ok, [], %{count: 0}} = Runners.list_runners_for_account(member_subject)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [edge.id])

      assert {:ok, updated} =
               Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert updated.runner_access_mode == :restricted
      assert Accounts.runner_access_for_membership(account.id, member.id) == restricted
      assert {:ok, scoped, %{count: 2}} = Runners.list_runners_for_account(member_subject)
      assert Enum.sort(Enum.map(scoped, & &1.name)) == ["db-1", "edge-1"]
      assert {:ok, fetched_db} = Runners.fetch_runner_by_id(db.id, member_subject)
      assert fetched_db.id == db.id
    end

    test "every mode transition keeps the legacy scope mirror exact", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      {:ok, restricted} = RunnerAccess.restricted(["db"], [runner.id])

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert legacy_scope_rows(member.id) == [
               {"runner", "00000000-0000-0000-0000-000000000000"}
             ]

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert legacy_scope_rows(member.id) == [
               {"group", "db"},
               {"runner", runner.id}
             ]

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.all(),
                 owner_subject
               )

      assert legacy_scope_rows(member.id) == []
    end

    test "rejects an individual runner from another account", %{
      owner_subject: owner_subject,
      member: member
    } do
      foreign_runner = Fixtures.Runners.create_runner()
      {:ok, foreign_access} = RunnerAccess.restricted([], [foreign_runner.id])

      assert Accounts.update_membership_runner_access(
               member,
               foreign_access,
               owner_subject
             ) == {:error, :invalid_runner_access}
    end

    test "single-runner reads hide out-of-scope runners", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "app-1", group: "app")
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert Runners.fetch_runner_by_id(runner.id, member_subject) == {:error, :not_found}
      assert Runners.fetch_runner_by_name(runner.name, member_subject) == {:error, :not_found}
    end

    test "inactive, deleted, missing, and malformed memberships fail closed", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      assert Accounts.runner_access_for_membership(account.id, "bad-id") == RunnerAccess.none()

      malformed = Fixtures.Memberships.create_membership(account_id: account.id)

      from(m in Accounts.Membership, where: m.id == ^malformed.id)
      |> Repo.update_all(set: [runner_access_mode: :none])

      assert Accounts.runner_access_for_membership(account.id, malformed.id) ==
               RunnerAccess.none()

      suspended = Fixtures.Memberships.suspend_membership(member)

      assert Accounts.runner_access_for_membership(account.id, suspended.id) ==
               RunnerAccess.none()

      other = create_member(account, "viewer")

      {:ok, _membership} =
        Accounts.update_membership_runner_access(other, RunnerAccess.none(), owner_subject)

      deleted = Fixtures.Memberships.mark_membership_as_deleted(other)
      assert Accounts.runner_access_for_membership(account.id, deleted.id) == RunnerAccess.none()
    end

    test "directory-owned access refuses manual edits", %{
      account: account,
      owner_subject: owner_subject
    } do
      managed =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          runner_access_directory_managed: true
        )

      assert Accounts.update_membership_runner_access(
               managed,
               RunnerAccess.none(),
               owner_subject
             ) == {:error, :runner_access_managed_by_directory}
    end

    test "an operator cannot edit runner access", %{
      member: member,
      member_subject: member_subject
    } do
      assert Accounts.update_membership_runner_access(
               member,
               RunnerAccess.none(),
               member_subject
             ) == {:error, :unauthorized}
    end

    test "cross-account edits are denied" do
      {account_a, _owner_a, subject_a} = account_with_owner()
      {account_b, _owner_b, _subject_b} = account_with_owner()
      member_b = create_member(account_b, "operator")

      assert account_a.id != account_b.id

      assert Accounts.update_membership_runner_access(
               member_b,
               RunnerAccess.none(),
               subject_a
             ) == {:error, :unauthorized}
    end

    test "a restricted admin cannot delegate beyond current access", %{
      account: account,
      owner_subject: owner_subject,
      member: target
    } do
      admin = create_member(account, "admin")
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])
      {:ok, _admin} = Accounts.update_membership_runner_access(admin, db_access, owner_subject)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert {:ok, _target} =
               Accounts.update_membership_runner_access(target, db_access, admin_subject)

      assert Accounts.update_membership_runner_access(
               target,
               RunnerAccess.all(),
               admin_subject
             ) == {:error, :runner_access_exceeds_subject}
    end

    test "writes one explicit before/after audit event", %{
      account: account,
      owner_subject: owner_subject,
      member: member
    } do
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _member} = Accounts.update_membership_runner_access(member, restricted, owner_subject)

      event =
        Emisar.Audit.Event.Query.all()
        |> Emisar.Audit.Event.Query.by_account_id(account.id)
        |> Emisar.Audit.Event.Query.by_event_type("membership.runner_access_changed")
        |> Repo.one!()

      assert event.payload["before"] == %{
               "mode" => "all",
               "groups" => [],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }

      assert event.payload["after"] == %{
               "mode" => "restricted",
               "groups" => ["db"],
               "runner_ids" => [],
               "pack_mode" => "all",
               "pack_ids" => []
             }
    end
  end

  describe "build_runner_access/5" do
    test "canonicalizes a picker's selection and fails closed on an unknown ref" do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      web = %{id: Ecto.UUID.generate(), group: "web"}
      runners = [database, web]
      values = ["group:database", "runner:#{database.id}", "runner:#{web.id}"]

      assert Accounts.build_runner_access("restricted", values, runners) ==
               {:ok, %RunnerAccess{mode: :restricted, groups: ["database"], runner_ids: [web.id]}}

      assert Accounts.build_runner_access("all", [], runners) == {:ok, RunnerAccess.all()}

      assert Accounts.build_runner_access(
               "restricted",
               ["runner:#{Ecto.UUID.generate()}"],
               runners
             ) == {:error, :invalid_runner_access}
    end

    test "narrows the same grant to the account's packs" do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      allowlist = Accounts.runner_access_allowlist([database], ["postgres", "shell"])

      assert Accounts.build_runner_access("all", [], allowlist, "restricted", ["pack:shell"]) ==
               {:ok,
                %RunnerAccess{
                  mode: :all,
                  groups: [],
                  runner_ids: [],
                  pack_mode: :restricted,
                  pack_ids: ["shell"]
                }}

      assert Accounts.build_runner_access("all", [], allowlist, "restricted", ["pack:nope"]) ==
               {:error, :invalid_pack_access}
    end
  end

  describe "runner_access_allowlist/2" do
    test "names the groups its runners carry plus the account's packs" do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      ungrouped = %{id: Ecto.UUID.generate(), group: nil}

      assert Accounts.runner_access_allowlist([database, ungrouped], ["postgres"]) ==
               %{groups: ["database"], runners: [database, ungrouped], packs: ["postgres"]}

      assert Accounts.runner_access_allowlist([]) == %{groups: [], runners: [], packs: []}
    end
  end

  describe "pack_access_selection_values/1" do
    test "renders a persisted pack scope back as the selector values the picker submits" do
      assert Accounts.pack_access_selection_values(["postgres", "shell"]) ==
               ["pack:postgres", "pack:shell"]

      assert Accounts.pack_access_selection_values([]) == []
    end
  end

  describe "runner_access_selection_values/2" do
    test "renders a persisted scope back as the selector values the picker submits" do
      runner_id = Ecto.UUID.generate()

      assert Accounts.runner_access_selection_values(["database"], [runner_id]) ==
               ["group:database", "runner:#{runner_id}"]

      assert Accounts.runner_access_selection_values([], []) == []
    end
  end

  describe "runner_access_for_subject/1" do
    test "re-reads the current active membership instead of trusting subject state" do
      {account, owner, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      assert Accounts.runner_access_for_subject(subject) == RunnerAccess.all()

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      assert Accounts.runner_access_for_subject(subject) == RunnerAccess.none()

      unbound = Fixtures.Subjects.build_subject(account: account, membership_id: nil)
      assert Accounts.runner_access_for_subject(unbound) == RunnerAccess.none()
    end
  end

  describe "runner_access_for_membership/2" do
    test "returns explicit access only for a current membership in that account" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.all()

      assert Accounts.runner_access_for_membership(Ecto.UUID.generate(), membership.id) ==
               RunnerAccess.none()
    end
  end

  describe "runner_access_for_memberships/1" do
    test "batches explicit modes without an N+1 read" do
      {account, _owner, owner_subject} = account_with_owner()
      all_member = create_member(account, "operator")
      none_member = create_member(account, "viewer")

      {:ok, none_member} =
        Accounts.update_membership_runner_access(
          none_member,
          RunnerAccess.none(),
          owner_subject
        )

      assert Accounts.runner_access_for_memberships([all_member, none_member]) == %{
               all_member.id => RunnerAccess.all(),
               none_member.id => RunnerAccess.none()
             }
    end
  end

  describe "runner_access_for_locked_membership/2" do
    test "loads the explicit aggregate through the caller's transaction repo" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert Accounts.runner_access_for_locked_membership(Repo, membership) ==
               RunnerAccess.all()

      assert membership.account_id == account.id
    end
  end

  describe "fetch_and_lock_active_membership/3" do
    test "returns only the active membership in the requested account" do
      {account, owner, _subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      assert {:ok, locked} =
               Accounts.fetch_and_lock_active_membership(Repo, account.id, membership.id)

      assert locked.id == membership.id

      suspended = Fixtures.Memberships.suspend_membership(membership)

      assert Accounts.fetch_and_lock_active_membership(Repo, account.id, suspended.id) ==
               {:error, :not_found}
    end
  end

  describe "mark_directory_authorization_pending/5" do
    test "marks provider-owned memberships and atomically adopts unmanaged identities" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      managed =
        create_member(account, "operator",
          directory_provider_id: provider.id,
          runner_access_directory_managed: true
        )

      local = create_member(account, "operator")

      assert Accounts.mark_directory_authorization_pending(
               Repo,
               account.id,
               provider.id,
               [managed.user_id, local.user_id],
               7
             ) === {:ok, 7}

      assert Repo.reload!(managed).directory_authorization_pending_version == 7

      adopted = Repo.reload!(local)
      assert adopted.directory_authorization_pending_version == 7
      assert adopted.directory_provider_id == provider.id
      assert adopted.runner_access_directory_managed
    end

    test "does not let a second directory provider take over an owned membership" do
      account = Fixtures.Accounts.create_account()
      owner_provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :jumpcloud)

      member =
        create_member(account, "admin",
          directory_provider_id: owner_provider.id,
          runner_access_directory_managed: true
        )

      assert Accounts.mark_directory_authorization_pending(
               Repo,
               account.id,
               other_provider.id,
               [member.user_id],
               4
             ) === {:ok, 4}

      unchanged = Repo.reload!(member)
      assert unchanged.directory_provider_id == owner_provider.id
      assert is_nil(unchanged.directory_authorization_pending_version)

      assert Accounts.sync_set_membership_authorization(
               unchanged,
               :viewer,
               RunnerAccess.none(),
               other_provider
             ) == {:error, :directory_authorization_provider_conflict}
    end
  end

  describe "list_pending_directory_authorizations/1" do
    test "returns a bounded pending work set" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      memberships =
        for _ <- 1..2 do
          create_member(account, "operator",
            directory_provider_id: provider.id,
            runner_access_directory_managed: true,
            directory_authorization_pending_version: 3
          )
        end

      # Least-recently-updated first, so a bounded batch is deterministic — an
      # unordered LIMIT let the planner re-serve whatever it liked, and a row at
      # the head of every batch starves everything behind it on a path that is
      # fail-closed by design.
      assert [pending] = Accounts.list_pending_directory_authorizations(1)
      assert pending.id == hd(memberships).id
    end
  end

  describe "ensure_runner_access_grant_allowed/2" do
    test "permits only grants covered by the caller's current access" do
      {account, _owner, owner_subject} = account_with_owner()
      admin = create_member(account, "admin")
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])
      {:ok, _admin} = Accounts.update_membership_runner_access(admin, db_access, owner_subject)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert Accounts.ensure_runner_access_grant_allowed(admin_subject, db_access) == :ok

      assert Accounts.ensure_runner_access_grant_allowed(admin_subject, RunnerAccess.all()) ==
               {:error, :runner_access_exceeds_subject}
    end

    # The staff break-glass subject (`Emisar.Admin.support_subject/1`) holds no
    # membership, so its own reach reads as `none` — it is acting as the
    # platform, not delegating reach it never had.
    test "exempts the actorless, membership-less platform subject" do
      platform_subject = Fixtures.Subjects.build_subject(role: :owner)

      assert Accounts.ensure_runner_access_grant_allowed(platform_subject, RunnerAccess.all()) ==
               :ok
    end

    # Both nils are the guard, so an ordinary member can never reach the
    # exemption: a caller holding either half is capped by its own reach.
    test "caps a subject carrying only half the platform shape" do
      user = Fixtures.Users.create_user()
      actor_only = Fixtures.Subjects.build_subject(user: user, role: :owner)

      membership_only =
        Fixtures.Subjects.build_subject(role: :owner, membership_id: Ecto.UUID.generate())

      assert Accounts.ensure_runner_access_grant_allowed(actor_only, RunnerAccess.all()) ==
               {:error, :runner_access_exceeds_subject}

      assert Accounts.ensure_runner_access_grant_allowed(membership_only, RunnerAccess.all()) ==
               {:error, :runner_access_exceeds_subject}
    end
  end

  describe "sync_set_membership_authorization/4" do
    test "atomically marks both role and runner access as directory managed" do
      {account, _owner, _owner_subject} = account_with_owner()
      member = create_member(account, "viewer")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      {:ok, access} = RunnerAccess.restricted(["production"], [])

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 member,
                 :operator,
                 access,
                 provider
               )

      assert updated.role == :operator
      assert updated.directory_managed
      assert updated.runner_access_directory_managed
      assert Accounts.runner_access_for_membership(account.id, member.id) == access
    end

    test "a human owner keeps the owner role while directory runner access still reconciles" do
      {account, owner, _owner_subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 membership,
                 :viewer,
                 RunnerAccess.none(),
                 provider
               )

      assert updated.role == :owner
      refute updated.directory_managed
      assert updated.runner_access_directory_managed
      assert updated.directory_provider_id == provider.id

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               RunnerAccess.none()
    end

    # Role and reach are recomputed from two independent mapping tables, so one
    # group can map to the finance seat while another grants runners. The role
    # in force decides, and a contradiction resets the grant rather than failing
    # the whole sync.
    test "a role that carries no reach resets the directory's grant" do
      {account, _owner, _owner_subject} = account_with_owner()
      member = create_member(account, "viewer")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      {:ok, access} = RunnerAccess.restricted(["production"], [])

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 member,
                 :billing_manager,
                 access,
                 provider
               )

      assert updated.role == :billing_manager
      assert updated.runner_access_mode == :none
      assert Accounts.runner_access_for_membership(account.id, member.id) == RunnerAccess.none()
    end
  end

  describe "runner_in_scope?/2" do
    test "accepts only runners covered by the explicit access value" do
      runner = %{id: Ecto.UUID.generate(), group: "db"}
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      assert Runners.runner_in_scope?(runner, RunnerAccess.all())
      assert Runners.runner_in_scope?(runner, db_access)
      refute Runners.runner_in_scope?(runner, RunnerAccess.none())
      refute Runners.runner_in_scope?(runner, nil)
    end
  end

  describe "enforcement at dispatch time" do
    test "the authenticated membership is re-read and forged attrs are ignored" do
      {account, owner, owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      _membership = Fixtures.Memberships.force_runner_access(membership, restricted)

      forged = create_member(account, "operator")

      assert Runs.dispatch_run(
               %{
                 runner_id: runner.id,
                 action_id: "x.y",
                 reason: "test",
                 requested_by_membership_id: forged.id
               },
               owner_subject
             ) == {:error, :runner_out_of_scope}
    end

    test "an offline queued run is not sent after its initiating access is revoked" do
      {account, owner, owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      _action = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          reason: "test current authorization",
          requested_by_id: owner.id,
          initiating_membership_id: membership.id,
          args: %{}
        })

      Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
      :ok = Runners.subscribe_runner_transport(runner)

      assert Runs.dispatch_to_runner(run) == {:error, :initiator_no_longer_authorized}
      assert Runs.peek_run_by_id(run.id).status == :pending
      refute_receive {:cloud_to_runner, _generation, _payload}, 100

      assert Accounts.runner_access_for_subject(owner_subject) == RunnerAccess.none()
    end

    test "an action outside the member's packs is refused even on a reachable runner" do
      {account, owner, owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.uptime",
        pack_id: "linux-core"
      )

      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)
      {:ok, other_packs} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(membership, other_packs)

      attrs = %{runner_id: runner.id, action_id: "linux.uptime", reason: "test pack scope"}

      assert Runs.dispatch_run(attrs, owner_subject) == {:error, :pack_out_of_scope}

      {:ok, this_pack} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      Fixtures.Memberships.force_runner_access(membership, this_pack)

      assert {:ok, _status, _run} = Runs.dispatch_run(attrs, owner_subject)
    end

    test "a queued run is not released after its initiator's packs are narrowed" do
      {account, owner, _owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.uptime",
        pack_id: "linux-core"
      )

      {:ok, membership} = Accounts.fetch_membership_for_session(owner, nil)

      {:ok, run} =
        Runs.create_run(%{
          account_id: account.id,
          runner_id: runner.id,
          action_id: "linux.uptime",
          source: "operator",
          reason: "test pack scope at release",
          requested_by_id: owner.id,
          initiating_membership_id: membership.id,
          args: %{}
        })

      {:ok, other_packs} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(membership, other_packs)

      assert Runs.dispatch_to_runner(run) == {:error, :initiator_no_longer_authorized}
      assert Runs.peek_run_by_id(run.id).status == :pending
    end

    test "catalog discovery hides an action outside the member's packs" do
      {account, _owner, _owner_subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "linux.uptime",
        pack_id: "linux-core"
      )

      member = create_member(account, "operator")
      member_subject = Fixtures.Subjects.membership_subject(member)

      {:ok, in_scope} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      Fixtures.Memberships.force_runner_access(member, in_scope)

      assert {:ok, _action} =
               Catalog.fetch_action_by_id("linux.uptime", runner.id, member_subject)

      assert Catalog.risk_by_action_ids(["linux.uptime"], member_subject) ==
               {:ok, %{"linux.uptime" => :low}}

      {:ok, out_of_scope} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(member, out_of_scope)

      assert Catalog.fetch_action_by_id("linux.uptime", runner.id, member_subject) ==
               {:error, :not_found}
    end
  end

  describe "run history remains account-wide after scope changes" do
    test "list, fetch, and runner history keep runs outside current reach" do
      {account, _owner, owner_subject} = account_with_owner()
      db = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      edge = Fixtures.Runners.create_runner(account_id: account.id, group: "edge")
      db_run = Fixtures.Runs.create_run(account_id: account.id, runner_id: db.id)
      edge_run = Fixtures.Runs.create_run(account_id: account.id, runner_id: edge.id)
      member = create_member(account, "operator")
      member_subject = Fixtures.Subjects.membership_subject(member)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, runs, _metadata} = Runs.list_runs(member_subject)
      assert MapSet.new(runs, & &1.id) == MapSet.new([db_run.id, edge_run.id])

      assert {:ok, fetched} = Runs.fetch_run_by_id(edge_run.id, member_subject)
      assert fetched.id == edge_run.id

      assert {:ok, [listed], _metadata} =
               Runs.list_recent_runs_for_runner(edge.id, member_subject)

      assert listed.id == edge_run.id
    end
  end

  describe "audit history remains account-wide after scope changes" do
    setup do
      {account, _owner, owner_subject} = account_with_owner()

      db = Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")
      edge = Fixtures.Runners.create_runner(account_id: account.id, name: "edge-1", group: "edge")

      for runner <- [db, edge] do
        Repo.insert!(
          Audit.changeset(account.id, "action_run.succeeded", %{
            target_kind: "runner",
            target_id: runner.id,
            target_label: runner.name
          })
        )
      end

      member = create_member(account, "operator")
      member_subject = Fixtures.Subjects.membership_subject(member)

      %{
        account: account,
        owner_subject: owner_subject,
        member: member,
        member_subject: member_subject,
        db: db,
        edge: edge
      }
    end

    test "a restricted member keeps the complete runner history and labels", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      assert {:ok, all_events, _} = Audit.list_events(member_subject)
      assert length(runner_targets(all_events)) == 2

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _} = Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, scoped, _} = Audit.list_events(member_subject)
      assert runner_targets(scoped) == Enum.sort([db.id, edge.id])

      assert {:ok, options} = Audit.list_target_options("runner", member_subject)
      assert MapSet.new(options) == MapSet.new([{db.id, "db-1"}, {edge.id, "edge-1"}])
    end

    test "a member with no runner access keeps the complete runner history", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      {:ok, _} =
        Accounts.update_membership_runner_access(member, RunnerAccess.none(), owner_subject)

      assert {:ok, events, _} = Audit.list_events(member_subject)
      assert runner_targets(events) == Enum.sort([db.id, edge.id])
    end

    test "direct fetch keeps historical runner receipts reachable", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db
    } do
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _} = Accounts.update_membership_runner_access(member, restricted, owner_subject)

      {:ok, all_events, _} = Audit.list_events(owner_subject)
      in_scope = Enum.find(all_events, &(&1.target_id == db.id))

      out_of_scope =
        Enum.find(all_events, &(&1.target_kind == "runner" and &1.target_id != db.id))

      assert {:ok, _} = Audit.fetch_event_by_id(in_scope.id, member_subject)
      assert {:ok, _} = Audit.fetch_event_by_id(out_of_scope.id, member_subject)
    end

    test "approval receipts remain complete across runner scope", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      db_run = Fixtures.Runs.create_run(account_id: account.id, runner_id: db.id)
      edge_run = Fixtures.Runs.create_run(account_id: account.id, runner_id: edge.id)
      db_request = Fixtures.Approvals.create_request(account_id: account.id, run_id: db_run.id)

      edge_request =
        Fixtures.Approvals.create_request(account_id: account.id, run_id: edge_run.id)

      {:ok, db_event} =
        Audit.log(account.id, "approval.approved",
          target_kind: "approval_request",
          target_id: db_request.id
        )

      {:ok, edge_event} =
        Audit.log(account.id, "approval.approved",
          target_kind: "approval_request",
          target_id: edge_request.id
        )

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, refs} =
               Audit.approval_event_refs([db_request.id, edge_request.id], member_subject)

      assert refs[db_request.id].final == db_event.id
      assert refs[edge_request.id].final == edge_event.id
      assert {:ok, _event} = Audit.fetch_event_by_id(db_event.id, member_subject)
      assert {:ok, _event} = Audit.fetch_event_by_id(edge_event.id, member_subject)
    end

    test "pack receipts remain complete across pack scope", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      {:ok, linux_event} =
        Audit.log(account.id, "pack_trust_adopted",
          target_kind: "pack_version",
          target_id: Ecto.UUID.generate(),
          payload: %{pack_id: "linux-core"}
        )

      {:ok, postgres_event} =
        Audit.log(account.id, "pack_trust_adopted",
          target_kind: "pack_version",
          target_id: Ecto.UUID.generate(),
          payload: %{pack_id: "postgres"}
        )

      {:ok, restricted} = RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)
      assert linux_event.id in Enum.map(events, & &1.id)
      assert postgres_event.id in Enum.map(events, & &1.id)
      assert {:ok, _event} = Audit.fetch_event_by_id(postgres_event.id, member_subject)
    end

    test "ruleset receipts and labels remain complete across runner scope", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      {:ok, _db_policy} =
        Policies.save_scoped_rules(Policies.default_rules(), :runner, db.id, owner_subject)

      {:ok, _edge_policy} =
        Policies.save_scoped_rules(Policies.default_rules(), :group, edge.group, owner_subject)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)
      assert MapSet.new(policy_scope_values(events)) == MapSet.new([db.id, "edge"])

      {:ok, owner_events, _metadata} = Audit.list_events(owner_subject)
      edge_event = Enum.find(owner_events, &(&1.payload["scope_value"] == "edge"))

      assert {:ok, _event} = Audit.fetch_event_by_id(edge_event.id, member_subject)

      assert {:ok, options} = Audit.list_target_options("policy", member_subject)

      assert MapSet.new(options, &elem(&1, 1)) ==
               MapSet.new(["Runner policy · #{db.id}", "Group policy · edge"])
    end

    test "a member with no runner access keeps ruleset receipts", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db
    } do
      {:ok, _policy} =
        Policies.save_scoped_rules(Policies.default_rules(), :runner, db.id, owner_subject)

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, RunnerAccess.none(), owner_subject)

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)
      assert policy_scope_values(events) == [db.id]
    end

    test "cross-account: a shared group name leaks no other account's ruleset receipt", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      {other_account, _other_owner, other_owner_subject} = account_with_owner()
      Fixtures.Runners.create_runner(account_id: other_account.id, name: "db-9", group: "db")

      {:ok, _policy} =
        Policies.save_scoped_rules(Policies.default_rules(), :group, "db", other_owner_subject)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)
      assert policy_scope_values(events) == []
    end

    test "a retention sweep keeps runner names for a restricted member", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      Repo.insert!(Audit.Events.runner_retention_swept(account.id, [db, edge], 720))

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      {:ok, owner_events, _metadata} = Audit.list_events(owner_subject)
      assert fleet_sweep(owner_events).payload["runners"] == ["db-1", "edge-1"]

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)
      sweep = fleet_sweep(events)

      assert sweep.payload["runners"] == ["db-1", "edge-1"]
      assert sweep.payload["count"] == 2
    end

    test "a grant receipt keeps the complete historical scope", %{
      account: account,
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject
    } do
      other_member = create_member(account, "operator")
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      {:ok, edge_only} = RunnerAccess.restricted(["edge"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, db_only, owner_subject)

      {:ok, _other_membership} =
        Accounts.update_membership_runner_access(other_member, edge_only, owner_subject)

      assert {:ok, events, _metadata} = Audit.list_events(member_subject)

      granted_groups =
        Map.new(
          for %{event_type: "membership.runner_access_changed"} = event <- events,
              do: {event.target_id, event.payload["after"]["groups"]}
        )

      assert granted_groups[member.user_id] == ["db"]
      assert granted_groups[other_member.user_id] == ["edge"]
    end

    test "the actor picker may name an account runner outside current scope", %{
      owner_subject: owner_subject,
      member: member,
      member_subject: member_subject,
      db: db,
      edge: edge
    } do
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _membership} =
        Accounts.update_membership_runner_access(member, restricted, owner_subject)

      db_id = db.id

      assert {:ok, [{^db_id, "db-1"}]} =
               Audit.list_actor_options("runner", member_subject, ensure: db.id)

      edge_id = edge.id

      assert {:ok, [{^edge_id, "edge-1"}]} =
               Audit.list_actor_options("runner", member_subject, ensure: edge.id)

      foreign = Fixtures.Runners.create_runner(name: "foreign-1", group: "db")

      assert Audit.list_actor_options("runner", member_subject, ensure: foreign.id) == {:ok, []}
    end
  end

  describe "mixed-revision database guard" do
    test "an old membership insert gets an explicit fail-closed mode" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      membership_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 """
                 INSERT INTO account_memberships
                   (id, account_id, user_id, role, inserted_at, updated_at)
                 VALUES ($1, $2, $3, 'operator', $4, $4)
                 """,
                 [
                   Ecto.UUID.dump!(membership_id),
                   Ecto.UUID.dump!(account.id),
                   Ecto.UUID.dump!(user.id),
                   now
                 ]
               )

      assert Accounts.runner_access_for_membership(account.id, membership_id) ==
               RunnerAccess.none()
    end

    test "an old owner insert preserves the initial-owner all-access exception" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      membership_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 Repo,
                 """
                 INSERT INTO account_memberships
                   (id, account_id, user_id, role, inserted_at, updated_at)
                 VALUES ($1, $2, $3, 'owner', $4, $4)
                 """,
                 [
                   Ecto.UUID.dump!(membership_id),
                   Ecto.UUID.dump!(account.id),
                   Ecto.UUID.dump!(user.id),
                   now
                 ]
               )

      assert Accounts.runner_access_for_membership(account.id, membership_id) ==
               RunnerAccess.all()
    end

    test "old direct scope writes cannot erase explicit none" do
      account = Fixtures.Accounts.create_account()
      member = create_member(account, "operator", runner_access_mode: "none")

      assert_raise Postgrex.Error,
                   ~r/runner access must be written through the explicit aggregate/,
                   fn ->
                     Ecto.Adapters.SQL.query!(
                       Repo,
                       "DELETE FROM user_runner_scopes WHERE membership_id = $1",
                       [Ecto.UUID.dump!(member.id)]
                     )
                   end
    end

    test "the aggregate writer capability does not leak through an outer transaction" do
      {account, _owner, owner_subject} = account_with_owner()
      member = create_member(account, "operator")

      assert {:ok, _member} =
               Accounts.update_membership_runner_access(
                 member,
                 RunnerAccess.none(),
                 owner_subject
               )

      assert_raise Postgrex.Error,
                   ~r/runner access must be written through the explicit aggregate/,
                   fn ->
                     Ecto.Adapters.SQL.query!(
                       Repo,
                       "DELETE FROM user_runner_scopes WHERE membership_id = $1",
                       [Ecto.UUID.dump!(member.id)]
                     )
                   end
    end
  end

  defp legacy_scope_rows(membership_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Repo,
        """
        SELECT scope_type, scope_value
        FROM user_runner_scopes
        WHERE membership_id = $1
        ORDER BY scope_type, scope_value
        """,
        [Ecto.UUID.dump!(membership_id)]
      )

    Enum.map(rows, fn [scope_type, scope_value] -> {scope_type, scope_value} end)
  end

  defp runner_targets(events) do
    events
    |> Enum.filter(&(&1.target_kind == "runner"))
    |> Enum.map(& &1.target_id)
    |> Enum.sort()
  end

  defp policy_scope_values(events) do
    for %{target_kind: "policy"} = event <- events, do: event.payload["scope_value"]
  end

  defp fleet_sweep(events), do: Enum.find(events, &(&1.target_kind == "runner_fleet"))

  defp create_member(account, role, attrs \\ []) do
    user = Fixtures.Users.create_user()

    attrs =
      attrs
      |> Keyword.merge(account_id: account.id, user_id: user.id, role: role)

    Fixtures.Memberships.create_membership(attrs)
  end

  defp account_with_owner do
    user = Fixtures.Users.create_user()

    {:ok, account} =
      Accounts.create_account_with_owner(
        %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
        user
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {account, user, subject}
  end
end
