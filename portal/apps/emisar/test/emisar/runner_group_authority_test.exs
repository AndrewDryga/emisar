defmodule Emisar.RunnerGroupAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Fixtures, Repo, Runners}
  alias Emisar.Accounts.RunnerAccess

  setup do
    account = Fixtures.Accounts.create_account()
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)
    inside = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

    outside =
      Fixtures.Runners.create_runner(account_id: account.id, group: "database", connected?: false)

    %{
      account: account,
      membership: membership,
      subject: subject,
      inside: inside,
      outside: outside
    }
  end

  describe "refs_outside_runner_access/2" do
    test "one named runner does not grant its group even when the other member is offline",
         %{
           account: account,
           membership: membership,
           subject: subject,
           inside: inside,
           outside: outside
         } do
      {:ok, access} = RunnerAccess.restricted([], [inside.id])
      Fixtures.Memberships.force_runner_access(membership, access)
      {:ok, ref} = Runners.public_ref(inside)

      assert {:ok, ["group:database"]} =
               Runners.refs_outside_runner_access(["runner:#{ref}", "group:database"], subject)

      {ids, groups} = Runners.reachable_scope_values(account.id, access)
      assert ids == [inside.id]
      refute "database" in groups

      assert [%{scope_type: "runner", scope_value: id}] =
               Repo.all(Runners.scope_targets_query(account.id, access))

      assert id == inside.id

      Fixtures.Runners.disable_runner(outside)

      assert {:ok, ["group:database"]} =
               Runners.refs_outside_runner_access(["group:database"], subject)

      Fixtures.Runners.mark_deleted(outside)
      assert {:ok, []} = Runners.refs_outside_runner_access(["group:database"], subject)
    end

    test "complete individual coverage and explicit empty groups remain valid",
         %{
           account: account,
           membership: membership,
           subject: subject,
           inside: inside,
           outside: outside
         } do
      {:ok, access} = RunnerAccess.restricted(["pre-enrollment"], [inside.id, outside.id])
      Fixtures.Memberships.force_runner_access(membership, access)

      assert {:ok, []} =
               Runners.refs_outside_runner_access(
                 ["group:database", "group:pre-enrollment"],
                 subject
               )

      assert {:ok, ["group:unknown"]} =
               Runners.refs_outside_runner_access(["group:unknown"], subject)

      {_ids, groups} = Runners.reachable_scope_values(account.id, access)
      assert Enum.sort(groups) == ["database", "pre-enrollment"]
    end

    test "a stale all-access subject does not bypass current identity or view permission",
         %{membership: membership, subject: subject} do
      Fixtures.Memberships.suspend_membership(membership)
      assert {:error, :unauthorized} = Runners.refs_outside_runner_access(["group:any"], subject)

      assert {:error, :unauthorized} =
               Runners.refs_outside_runner_access([], %{subject | permissions: MapSet.new()})
    end
  end

  describe "runbook_target_projection/1" do
    test "group authority includes offline and disabled members before narrowing candidates",
         %{membership: membership, subject: subject, inside: inside, outside: outside} do
      Fixtures.Runners.create_runner(group: "foreign")
      Fixtures.Runners.disable_runner(outside)
      {:ok, partial} = RunnerAccess.restricted([], [inside.id])
      Fixtures.Memberships.force_runner_access(membership, partial)

      assert {:ok, %{targets: [target], groups: []}} = Runners.runbook_target_projection(subject)
      assert target.id == inside.id

      {:ok, complete} = RunnerAccess.restricted([], [inside.id, outside.id])
      {:ok, group} = RunnerAccess.restricted(["database", "pre-enrollment"], [])

      for {access, groups} <- [
            {complete, ["database"]},
            {group, ["database", "pre-enrollment"]}
          ] do
        Fixtures.Memberships.force_runner_access(membership, access)

        assert {:ok, %{targets: [^target], groups: ^groups}} =
                 Runners.runbook_target_projection(subject)
      end
    end

    test "current read permission and exact active identity are required",
         %{membership: membership, subject: subject} do
      assert {:error, :unauthorized} =
               Runners.runbook_target_projection(%{subject | permissions: MapSet.new()})

      Fixtures.Memberships.suspend_membership(membership)
      assert {:error, :unauthorized} = Runners.runbook_target_projection(subject)
    end
  end

  describe "resolve_runbook_target_sets/2" do
    test "all and random group selection refuse partial authority before physical narrowing",
         %{membership: membership, subject: subject, inside: inside, outside: outside} do
      {:ok, partial} = RunnerAccess.restricted([], [inside.id])
      Fixtures.Memberships.force_runner_access(membership, partial)

      for selection <- ["all", "random_one"] do
        target = %{"selection" => selection, "refs" => ["group:database"]}

        assert {:error, {:unknown_target, 0}} =
                 Runners.resolve_runbook_target_sets([target], subject)
      end

      {:ok, complete} = RunnerAccess.restricted([], [inside.id, outside.id])
      Fixtures.Memberships.force_runner_access(membership, complete)

      assert {:ok, [%{runners: [target]}]} =
               Runners.resolve_runbook_target_sets(
                 [%{"selection" => "all", "refs" => ["group:database"]}],
                 subject
               )

      assert target.id == inside.id
    end

    test "foreign runners with the same group do not affect current workspace authority",
         %{
           account: account,
           membership: membership,
           subject: subject,
           inside: inside,
           outside: outside
         } do
      Fixtures.Runners.create_runner(group: "database")
      {:ok, complete} = RunnerAccess.restricted([], [inside.id, outside.id])
      Fixtures.Memberships.force_runner_access(membership, complete)
      assert {:ok, []} = Runners.refs_outside_runner_access(["group:database"], subject)

      assert Enum.any?(
               Repo.all(Runners.scope_targets_query(account.id, complete)),
               &(&1.scope_type == "group")
             )
    end
  end

  describe "ensure_group_access/4" do
    test "proves complete groups while preserving all and explicit empty group authority",
         %{account: account, inside: inside, outside: outside} do
      {:ok, partial} = RunnerAccess.restricted([], [inside.id])
      {:ok, complete} = RunnerAccess.restricted(["empty"], [inside.id, outside.id])

      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 assert {:ok, _} = Accounts.fetch_and_lock_account(account.id)

                 assert {:error, :unauthorized} =
                          Runners.ensure_group_access(account.id, ["database"], partial)

                 assert :ok =
                          Runners.ensure_group_access(
                            account.id,
                            ["database", "empty"],
                            complete
                          )

                 assert :ok =
                          Runners.ensure_group_access(
                            account.id,
                            ["future"],
                            RunnerAccess.all()
                          )

                 assert {:error, :unauthorized} =
                          Runners.ensure_group_access(account.id, ["future"], partial)

                 assert {:error, :unauthorized} =
                          Runners.ensure_group_access(
                            account.id,
                            ["database"],
                            RunnerAccess.none()
                          )

                 :checked
               end)
    end
  end

  describe "management_by_runner_ids/2" do
    test "separates current management role from current runner authority without pack or online gates",
         %{membership: membership, subject: subject, inside: inside, outside: outside} do
      foreign = Fixtures.Runners.create_runner()
      {:ok, access} = RunnerAccess.new(:restricted, [], [inside.id], :restricted, [])
      Fixtures.Memberships.force_runner_access(membership, access)
      ids = [inside.id, outside.id, foreign.id]

      assert {:ok, %{can_manage?: true, runners: hints}} =
               Runners.management_by_runner_ids(ids, subject)

      assert hints == %{inside.id => true, outside.id => false, foreign.id => false}
      Fixtures.Memberships.force_role(membership, "viewer")

      assert {:ok, %{can_manage?: false, runners: hints}} =
               Runners.management_by_runner_ids(ids, subject)

      refute Enum.any?(hints, fn {_id, allowed?} -> allowed? end)
      Fixtures.Memberships.suspend_membership(membership)
      assert {:error, :unauthorized} = Runners.management_by_runner_ids(ids, subject)
    end
  end
end
