defmodule Emisar.RunnerScopesTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Runners, Runs}
  alias Emisar.Fixtures

  describe "Runners.list_runners_for_account/2 with the subject membership" do
    setup do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      %{account: account, subject: subject, membership: membership}
    end

    test "no scopes = sees everything", %{account: account, subject: subject} do
      _a = Fixtures.Runners.create_runner(account_id: account.id, name: "a", group: "dba")
      _b = Fixtures.Runners.create_runner(account_id: account.id, name: "b", group: "app")

      {:ok, runners, _} = Runners.list_runners_for_account(subject)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["a", "b"]
    end

    test "group scope restricts to only that group", %{
      account: account,
      subject: subject,
      membership: membership
    } do
      _a = Fixtures.Runners.create_runner(account_id: account.id, name: "dba1", group: "dba")
      _b = Fixtures.Runners.create_runner(account_id: account.id, name: "dba2", group: "dba")
      _c = Fixtures.Runners.create_runner(account_id: account.id, name: "app1", group: "app")

      {:ok, :ok} =
        Runners.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      {:ok, runners, meta} = Runners.list_runners_for_account(subject)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["dba1", "dba2"]
      # The scope filter runs in the query, before pagination — so the count
      # reflects the scoped set (2), not all 3 runners (the old in-memory
      # post-pagination filter left this metadata at 3).
      assert meta.count == 2
    end

    test "runner-id scope additively unions with group scope", %{
      account: account,
      subject: subject,
      membership: membership
    } do
      _dba = Fixtures.Runners.create_runner(account_id: account.id, name: "dba1", group: "dba")
      edge = Fixtures.Runners.create_runner(account_id: account.id, name: "edge1", group: "edge")

      _other =
        Fixtures.Runners.create_runner(account_id: account.id, name: "other", group: "misc")

      {:ok, :ok} =
        Runners.replace_runner_scopes(
          membership,
          [
            {"group", "dba"},
            {"runner", edge.id}
          ],
          subject
        )

      {:ok, runners, _} = Runners.list_runners_for_account(subject)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["dba1", "edge1"]
    end

    test "single-runner reads treat an out-of-scope runner as not found", %{
      account: account,
      subject: subject,
      membership: membership
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "app1", group: "app")
      {:ok, :ok} = Runners.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      assert Runners.fetch_runner_by_id(runner.id, subject) == {:error, :not_found}
      assert Runners.fetch_runner_by_name(runner.name, subject) == {:error, :not_found}
    end
  end

  describe "Runners.replace_runner_scopes/2 + runner_scopes_for_membership/1" do
    setup do
      {account, _user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(subject.actor, nil)
      %{account: account, subject: subject, membership: membership}
    end

    test "empty list = all-runners default", %{subject: subject, membership: membership} do
      assert {:ok, :ok} = Runners.replace_runner_scopes(membership, [], subject)
      assert Runners.runner_scopes_for_membership(membership.id) == []
    end

    test "replaces the full set atomically", %{subject: subject, membership: membership} do
      assert {:ok, :ok} =
               Runners.replace_runner_scopes(
                 membership,
                 [
                   {"group", "dba"},
                   {"group", "edge"}
                 ],
                 subject
               )

      assert [
               %{scope_type: :group, scope_value: "dba"},
               %{scope_type: :group, scope_value: "edge"}
             ] = Runners.runner_scopes_for_membership(membership.id)

      # Second call replaces the set entirely.
      assert {:ok, :ok} =
               Runners.replace_runner_scopes(membership, [{"group", "app"}], subject)

      assert [%{scope_type: :group, scope_value: "app"}] =
               Runners.runner_scopes_for_membership(membership.id)
    end

    test "rejects invalid scope_type via the changeset", %{
      subject: subject,
      membership: membership
    } do
      assert {:error, changeset} =
               Runners.replace_runner_scopes(membership, [{"bogus", "x"}], subject)

      assert "is invalid" in errors_on(changeset).scope_type
    end

    test "an operator (no manage_team permission) cannot widen scope → :unauthorized", %{
      account: account,
      membership: membership
    } do
      # Runner ACLs are a team-management privilege: a non-admin must not
      # be able to broaden their own (or anyone's) scope.
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               Runners.replace_runner_scopes(membership, [{"group", "dba"}], operator_subject)
    end

    test "cross-account: can't replace scopes for a membership in another account" do
      {_account_a, _user_a, subject_a} = account_with_owner()
      {_account_b, user_b, _subject_b} = account_with_owner()
      {:ok, membership_b} = Accounts.fetch_membership_for_session(user_b, nil)

      assert {:error, :unauthorized} = Runners.replace_runner_scopes(membership_b, [], subject_a)
    end
  end

  describe "Runs.dispatch_run/2 with :requested_by_membership_id" do
    setup do
      {account, user, subject} = account_with_owner()
      %{account: account, user: user, subject: subject}
    end

    test "rejects out-of-scope runner", %{account: account, user: user, subject: subject} do
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)

      _runner_in =
        Fixtures.Runners.create_runner(account_id: account.id, name: "in", group: "dba")

      runner_out =
        Fixtures.Runners.create_runner(account_id: account.id, name: "out", group: "app")

      {:ok, :ok} =
        Runners.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run(
                 %{
                   runner_id: runner_out.id,
                   action_id: "x.y",
                   reason: "test",
                   requested_by_id: user.id,
                   requested_by_membership_id: membership.id
                 },
                 subject
               )
    end

    test "derives the runner-scope membership from the authenticated subject", %{
      account: account,
      user: user,
      subject: subject
    } do
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      {:ok, :ok} =
        Runners.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run(
                 %{
                   runner_id: runner.id,
                   action_id: "x.y",
                   reason: "test"
                 },
                 subject
               )
    end

    test "ignores a forged attrs membership when applying runner scopes", %{
      account: account,
      user: user,
      subject: subject
    } do
      {:ok, subject_membership} = Accounts.fetch_membership_for_session(user, nil)
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "app")
      other_user = Fixtures.Users.create_user()

      forged_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other_user.id,
          role: "operator"
        )

      {:ok, :ok} =
        Runners.replace_runner_scopes(subject_membership, [{"group", "dba"}], subject)

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run(
                 %{
                   runner_id: runner.id,
                   action_id: "x.y",
                   reason: "test",
                   requested_by_membership_id: forged_membership.id
                 },
                 subject
               )
    end
  end

  describe "runner_scopes_for_membership_ids/1" do
    test "groups scopes by membership_id for batch rendering" do
      {_account, user_a, subject} = account_with_owner()
      {:ok, m_a} = Accounts.fetch_membership_for_session(user_a, nil)

      email_b = "b-#{System.unique_integer()}@example.com"

      {:ok, %{membership: m_b}} =
        Accounts.invite_user_to_account(email_b, "admin", subject)

      {:ok, :ok} = Runners.replace_runner_scopes(m_a, [{"group", "dba"}], subject)
      {:ok, :ok} = Runners.replace_runner_scopes(m_b, [{"group", "app"}], subject)

      grouped = Runners.runner_scopes_for_membership_ids([m_a.id, m_b.id])

      assert [%{scope_value: "dba"}] = Map.get(grouped, m_a.id)
      assert [%{scope_value: "app"}] = Map.get(grouped, m_b.id)
    end
  end

  describe "runner_in_scope?/2 (the per-user runner ACL check)" do
    test "nil fails closed while empty scopes mean unrestricted" do
      runner = %{id: "runner-1", group: "db"}
      refute Runners.runner_in_scope?(runner, nil)
      assert Runners.runner_in_scope?(runner, [])
    end

    test "an explicit scope list passes on a runner-id or group match, denies otherwise" do
      runner = %{id: "runner-1", group: "db"}

      assert Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :runner, scope_value: "runner-1"}
             ])

      assert Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :group, scope_value: "db"}
             ])

      refute Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :runner, scope_value: "other"},
               %Runners.UserRunnerScope{scope_type: :group, scope_value: "web"}
             ])

      # A malformed scopes value (not nil, a list, or a membership) is denied.
      refute Runners.runner_in_scope?(runner, :nonsense)
    end

    test "given a %Membership{}, it resolves that membership's scopes from the DB" do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      in_group = Fixtures.Runners.create_runner(account_id: account.id, group: "dba")
      out_group = Fixtures.Runners.create_runner(account_id: account.id, group: "app")

      {:ok, :ok} = Runners.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      assert Runners.runner_in_scope?(in_group, membership)
      refute Runners.runner_in_scope?(out_group, membership)
    end
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
