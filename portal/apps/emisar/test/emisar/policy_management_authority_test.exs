defmodule Emisar.PolicyManagementAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Audit, Fixtures, Policies, Repo}

  test "group policies require complete current coverage, including individual grants" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)

    first =
      Fixtures.Runners.create_runner(
        account_id: subject.account.id,
        group: "production",
        connected?: false
      )

    second =
      Fixtures.Runners.create_runner(
        account_id: subject.account.id,
        group: "production",
        connected?: false
      )

    policy =
      Fixtures.Policies.create_policy(
        account_id: subject.account.id,
        scope_type: :group,
        scope_value: "production"
      )

    {:ok, partial} = RunnerAccess.new(:restricted, [], [first.id], :all)
    Fixtures.Memberships.force_runner_access(membership, partial)

    assert {:ok, ^policy} = Policies.fetch_scoped_policy_by_id(policy.id, subject)

    assert Policies.save_scoped_rules(Policies.default_rules(), :group, "production", subject) ==
             {:error, :unauthorized}

    assert Policies.delete_scoped_policy(policy, subject) == {:error, :unauthorized}
    assert Repo.reload!(policy) == policy
    refute Repo.exists?(Audit.Event)

    {:ok, complete} = RunnerAccess.new(:restricted, [], [first.id, second.id], :all)
    Fixtures.Memberships.force_runner_access(membership, complete)

    assert {:ok, updated} =
             Policies.save_scoped_rules(Policies.default_rules(), :group, "production", subject)

    assert updated.id == policy.id
    assert {:ok, _deleted} = Policies.delete_scoped_policy(updated, subject)
  end

  for invalidation <- [:demoted, :pending, :deleted_user, :suspended] do
    test "policy writes reject #{invalidation} current identity and keep the saved rules" do
      membership = Fixtures.Memberships.create_membership(role: "admin")
      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: subject.account.id, connected?: false)

      policy =
        Fixtures.Policies.create_policy(
          account_id: subject.account.id,
          scope_type: :runner,
          scope_value: runner.id
        )

      invalidate(membership, subject, unquote(invalidation))

      assert {:error, :unauthorized} = Policies.save_rules(Policies.default_rules(), subject)

      assert {:error, :unauthorized} =
               Policies.save_scoped_rules(Policies.default_rules(), :runner, runner.id, subject)

      assert Policies.delete_scoped_policy(policy, subject) == {:error, :unauthorized}
      refute Policies.policy_management_capabilities(subject).can_manage?
      assert Repo.reload!(policy) == policy
      refute Repo.exists?(Audit.Event)
    end
  end

  test "unsaved previews remain readable after action scope changes, but mutation stays denied" do
    membership = Fixtures.Memberships.create_membership(role: "admin")
    subject = Fixtures.Subjects.membership_subject(membership)

    runner =
      Fixtures.Runners.create_runner(
        account_id: subject.account.id,
        group: "production",
        connected?: false
      )

    input = Policies.editor_input(Policies.default_rules())
    assert {:ok, preview} = Policies.preview_policy(input, {:runner, runner.id}, subject)
    Fixtures.Memberships.force_runner_access(membership, RunnerAccess.none())
    assert Policies.preview_current?(preview, subject)
    assert {:ok, %{total: 0}} = Policies.preview_policy(input, {:group, "production"}, subject)

    assert Policies.save_scoped_rules(Policies.default_rules(), :runner, runner.id, subject) ==
             {:error, :unauthorized}

    assert Policies.preview_policy(input, {:runner, Emisar.Repo.generate_id()}, subject) ==
             {:error, :not_found}
  end

  defp invalidate(membership, _subject, :demoted),
    do: Fixtures.Memberships.force_role(membership, "viewer")

  defp invalidate(membership, _subject, :pending),
    do: Fixtures.Memberships.mark_directory_authorization_pending(membership, 1)

  defp invalidate(membership, _subject, :suspended),
    do: Fixtures.Memberships.suspend_membership(membership)

  defp invalidate(_membership, subject, :deleted_user),
    do: Fixtures.Users.mark_user_as_deleted(subject.actor)
end
