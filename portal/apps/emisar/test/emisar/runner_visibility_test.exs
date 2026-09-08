defmodule Emisar.RunnerVisibilityTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Auth.Subject
  alias Emisar.{Fixtures, Runners}

  setup do
    account = Fixtures.Accounts.create_account()

    staging =
      Fixtures.Runners.create_runner(account_id: account.id, name: "staging", group: "staging")

    production =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "production",
        group: "production"
      )

    foreign = Fixtures.Runners.create_runner(name: "other-workspace")
    %{account: account, staging: staging, production: production, foreign: foreign}
  end

  for role <- ~w(admin operator viewer) do
    test "#{role} keeps account-wide reads with no runner or pack action grants",
         %{account: _, staging: _, production: _} = context do
      membership =
        Fixtures.Memberships.create_membership(
          account_id: context.account.id,
          role: unquote(role)
        )

      subject = Fixtures.Subjects.membership_subject(membership)
      {:ok, selected} = RunnerAccess.restricted(["staging"], [])
      {:ok, no_packs} = RunnerAccess.new(:all, [], [], :restricted, [])

      {:ok, one_pack} =
        RunnerAccess.new(:restricted, ["staging"], [], :restricted, ["linux-core"])

      for access <- [RunnerAccess.all(), selected, no_packs, one_pack, RunnerAccess.none()] do
        Fixtures.Memberships.force_runner_access(membership, access)
        assert_shared_inventory(subject, context)
      end
    end
  end

  test "execution candidates remain scoped even though the same runners are readable",
       %{account: _, staging: _, production: _} = context do
    membership =
      Fixtures.Memberships.create_membership(account_id: context.account.id, role: "admin")

    subject = Fixtures.Subjects.membership_subject(membership)
    {:ok, selected} = RunnerAccess.restricted(["staging"], [])
    Fixtures.Memberships.force_runner_access(membership, selected)

    assert_shared_inventory(subject, context)
    assert {:ok, [runner]} = Runners.list_runners_in_action_scope(subject, preload: [:online?])
    assert runner.id == context.staging.id
    assert :ok = Runners.ensure_runner_ids_in_action_scope([context.staging.id], subject)

    assert {:error, :unauthorized} =
             Runners.ensure_runner_ids_in_action_scope([context.production.id], subject)

    assert {:error, {:unknown_target, 0}} =
             Runners.resolve_runbook_target_sets(
               [%{"selection" => "all", "refs" => ["group:production"]}],
               subject
             )

    for operation <- [
          &Runners.disable_runner/2,
          &Runners.enable_runner/2,
          &Runners.delete_runner/2
        ] do
      assert {:error, :not_found} = operation.(context.production, subject)
    end

    Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
    assert {:ok, []} = Runners.list_runners_in_action_scope(subject)
    assert_shared_inventory(subject, context)
  end

  test "a held human subject loses reads on current identity or read-role loss",
       %{account: _, production: _} = context do
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

      assert_read_denied(subject, context.production)
    end
  end

  test "an agent keeps shared reads after action grants are removed, but not after revocation",
       %{account: _, staging: _, production: _} = context do
    membership =
      Fixtures.Memberships.create_membership(account_id: context.account.id, role: "operator")

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: context.account.id,
        created_by_id: membership.user_id
      )

    subject = Subject.for_api_key(key, context.account)
    Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
    assert_shared_inventory(subject, context)
    assert {:ok, []} = Runners.list_runners_in_action_scope(subject)

    Fixtures.ApiKeys.mark_revoked(key)
    assert_read_denied(subject, context.production)
  end

  test "shared inventory does not make another account or an unbound subject readable",
       %{account: _, production: _, foreign: _} = context do
    membership =
      Fixtures.Memberships.create_membership(account_id: context.account.id, role: "viewer")

    subject = Fixtures.Subjects.membership_subject(membership)
    assert {:error, :not_found} = Runners.fetch_runner_by_id(context.foreign.id, subject)
    assert {:error, :not_found} = Runners.fetch_runner_by_name(context.foreign.name, subject)
    assert_read_denied(%{subject | membership_id: nil}, context.production)
    assert_read_denied(%{subject | permissions: MapSet.new()}, context.production)
  end

  defp assert_shared_inventory(subject, context) do
    expected = Enum.sort([context.staging.id, context.production.id])
    assert {:ok, runners, metadata} = Runners.list_runners_for_account(subject)
    assert Enum.sort(Enum.map(runners, & &1.id)) == expected
    assert metadata.count == 2
    assert {:ok, all} = Runners.list_all_runners_for_account(subject)
    assert Enum.sort(Enum.map(all, & &1.id)) == expected
    assert {:ok, options} = Runners.list_runner_options(subject)
    assert Enum.sort(Enum.map(options, &elem(&1, 0))) == expected
    assert {:ok, groups} = Runners.list_group_summaries(subject)
    assert Enum.sort(groups) == [{"production", 1}, {"staging", 1}]
    assert {:ok, runner} = Runners.fetch_runner_by_id(context.production.id, subject)
    assert runner.id == context.production.id
    assert {:ok, runner} = Runners.fetch_runner_by_name(context.production.name, subject)
    assert runner.id == context.production.id

    assert {:ok, facts, %{coverage: :complete}} =
             Runners.list_pack_advertisement_facts(10, subject)

    assert Enum.sort(Enum.map(facts, & &1.id)) == expected
    assert {:ok, fleet} = Runners.fetch_fleet_status(subject)
    assert fleet.counts.total == 2
    assert Runners.any_runners?(subject)
  end

  defp assert_read_denied(subject, runner) do
    for read <- [
          &Runners.list_runners_for_account/1,
          &Runners.list_all_runners_for_account/1,
          &Runners.list_runners_in_action_scope/1,
          &Runners.list_runner_options/1,
          &Runners.list_group_summaries/1,
          &Runners.fetch_fleet_status/1,
          &Runners.fetch_runner_by_id(runner.id, &1),
          &Runners.fetch_runner_by_name(runner.name, &1),
          &Runners.list_pack_advertisement_facts(10, &1)
        ] do
      assert read.(subject) == {:error, :unauthorized}
    end

    refute Runners.any_runners?(subject)
  end
end
