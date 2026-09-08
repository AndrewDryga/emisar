defmodule Emisar.CatalogVisibilityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Catalog, Fixtures}

  setup do
    account = Fixtures.Accounts.create_account()
    runner = Fixtures.Runners.create_runner(account_id: account.id, group: "production")

    action =
      Fixtures.Catalog.create_action(
        runner: runner,
        action_id: "production.inspect",
        pack_id: "production",
        pack_version: "1.0",
        risk: "high"
      )

    version =
      Fixtures.Catalog.create_trusted_pack_version(
        account_id: account.id,
        pack_id: "production",
        version: "1.0"
      )

    foreign = Fixtures.Runners.create_runner()

    Fixtures.Catalog.create_action(
      runner: foreign,
      action_id: "foreign.secret",
      pack_id: "foreign"
    )

    Fixtures.Catalog.create_trusted_pack_version(
      account_id: foreign.account_id,
      pack_id: "foreign"
    )

    %{account: account, runner: runner, action: action, version: version, foreign: foreign}
  end

  for role <- ~w(admin operator viewer) do
    test "#{role} retains shared catalog reads across action-grant changes",
         %{account: _, runner: _, action: _, version: _, foreign: _} = context do
      membership =
        Fixtures.Memberships.create_membership(
          account_id: context.account.id,
          role: unquote(role)
        )

      subject = Fixtures.Subjects.membership_subject(membership)

      {:ok, selected} =
        Accounts.RunnerAccess.new(:restricted, ["staging"], [], :restricted, ["staging"])

      {:ok, no_packs} = Accounts.RunnerAccess.new(:all, [], [], :restricted, [])

      for access <- [
            Accounts.RunnerAccess.all(),
            selected,
            no_packs,
            Accounts.RunnerAccess.none()
          ] do
        Fixtures.Memberships.force_runner_access(membership, access)
        assert {:ok, [action], _} = Catalog.list_actions_for_runner(context.runner.id, subject)
        assert action.id == context.action.id
        assert {:ok, [version], _} = Catalog.list_pack_versions(subject)
        assert version.id == context.version.id
        assert {:ok, [action]} = Catalog.list_pack_actions("production", "1.0", subject)
        assert action.action_id == "production.inspect"

        assert {:ok, [option]} =
                 Catalog.list_action_pack_options_for_runner(context.runner.id, subject)

        assert option == {"production", "production"}
        assert {:ok, ["production"]} = Catalog.list_account_pack_ids(subject)

        assert {:ok, [%{action_id: "production.inspect", risk: "high"}], _} =
                 Catalog.list_action_risks(:account, subject)

        assert {:ok, action} =
                 Catalog.fetch_action_by_id("production.inspect", context.runner.id, subject)

        assert action.id == context.action.id
        assert {:ok, [], _} = Catalog.list_actions_for_runner(context.foreign.id, subject)

        assert {:error, :not_found} =
                 Catalog.fetch_action_by_id("foreign.secret", context.foreign.id, subject)
      end
    end
  end

  test "held subjects lose catalog reads when the current identity or read role is lost",
       %{account: _, runner: _} = context do
    for change <- [:suspended, :deleted, :billing, :deleted_user] do
      membership =
        Fixtures.Memberships.create_membership(account_id: context.account.id, role: "admin")

      subject = Fixtures.Subjects.membership_subject(membership)

      case change do
        :suspended -> Fixtures.Memberships.suspend_membership(membership)
        :deleted -> Fixtures.Memberships.mark_membership_as_deleted(membership)
        :billing -> Fixtures.Memberships.force_role(membership, "billing_manager")
        :deleted_user -> Fixtures.Users.mark_user_as_deleted(subject.actor)
      end

      for result <- [
            Catalog.list_actions_for_runner(context.runner.id, subject),
            Catalog.list_pack_versions(subject),
            Catalog.list_pack_actions("production", "1.0", subject),
            Catalog.list_action_pack_options_for_runner(context.runner.id, subject),
            Catalog.list_account_pack_ids(subject),
            Catalog.list_action_scope_pack_advertisements(subject),
            Catalog.list_console_packs(%{}, subject),
            Catalog.fetch_action_by_id("production.inspect", context.runner.id, subject),
            Catalog.risk_by_action_ids(["production.inspect"], subject),
            Catalog.risk_by_runner_action_pairs(
              [{context.runner.id, "production.inspect"}],
              subject
            ),
            Catalog.list_action_risks(:account, subject)
          ],
          do: assert(result == {:error, :unauthorized})

      assert Catalog.count_pack_versions_needing_decision(subject) == 0
    end
  end

  describe "list_action_scope_pack_advertisements/1" do
    test "grant-editor candidates retain runner and pack limits without widening shared reads",
         %{account: _, runner: _} = context do
      membership =
        Fixtures.Memberships.create_membership(account_id: context.account.id, role: "admin")

      subject = Fixtures.Subjects.membership_subject(membership)
      staging = Fixtures.Runners.create_runner(account_id: context.account.id, group: "staging")

      Fixtures.Catalog.create_action(
        runner: staging,
        action_id: "staging.inspect",
        pack_id: "staging"
      )

      Fixtures.Catalog.create_action(
        runner: staging,
        action_id: "production.inspect",
        pack_id: "production"
      )

      {:ok, access} =
        Accounts.RunnerAccess.new(:restricted, ["staging"], [], :restricted, ["staging"])

      Fixtures.Memberships.force_runner_access(membership, access)

      assert Catalog.list_action_scope_pack_advertisements(subject) ==
               {:ok, %{"staging" => [staging.id]}}

      assert {:ok, [action], _} = Catalog.list_actions_for_runner(context.runner.id, subject)
      assert action.action_id == "production.inspect"
      Fixtures.Memberships.force_runner_access(membership, Accounts.RunnerAccess.none())
      assert Catalog.list_action_scope_pack_advertisements(subject) == {:ok, %{}}

      assert Catalog.list_action_scope_pack_advertisements(%{subject | permissions: MapSet.new()}) ==
               {:error, :unauthorized}
    end
  end
end
