defmodule Emisar.RunnerScopesTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, Runners, Runs}

  describe "Accounts.replace_runner_scopes/2 + runner_scopes_for_membership/1" do
    test "empty list = all-runners default" do
      {_account, _user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(subject.actor, nil)

      assert {:ok, :ok} = Accounts.replace_runner_scopes(membership, [], subject)
      assert Accounts.runner_scopes_for_membership(membership.id) == []
    end

    test "replaces the full set atomically" do
      {_account, _user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(subject.actor, nil)

      assert {:ok, :ok} =
               Accounts.replace_runner_scopes(membership, [
                 {"group", "dba"},
                 {"group", "edge"}
               ], subject)

      assert [
               %{scope_type: "group", scope_value: "dba"},
               %{scope_type: "group", scope_value: "edge"}
             ] = Accounts.runner_scopes_for_membership(membership.id)

      # Second call replaces the set entirely.
      assert {:ok, :ok} =
               Accounts.replace_runner_scopes(membership, [{"group", "app"}], subject)

      assert [%{scope_type: "group", scope_value: "app"}] =
               Accounts.runner_scopes_for_membership(membership.id)
    end

    test "rejects invalid scope_type via the changeset" do
      {_account, _user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(subject.actor, nil)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.replace_runner_scopes(membership, [{"bogus", "x"}], subject)
    end
  end

  describe "Runners.list_runners_for_account/2 with :membership_id" do
    test "no scopes = sees everything" do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      a = runner_fixture(account_id: account.id, name: "a", group: "dba")
      _b = runner_fixture(account_id: account.id, name: "b", group: "app")

      {:ok, runners, _} =
        Runners.list_runners_for_account(subject, membership_id: membership.id)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["a", "b"]
      _ = a
    end

    test "group scope restricts to only that group" do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      _a = runner_fixture(account_id: account.id, name: "dba1", group: "dba")
      _b = runner_fixture(account_id: account.id, name: "dba2", group: "dba")
      _c = runner_fixture(account_id: account.id, name: "app1", group: "app")

      {:ok, :ok} =
        Accounts.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      {:ok, runners, _} =
        Runners.list_runners_for_account(subject, membership_id: membership.id)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["dba1", "dba2"]
    end

    test "runner-id scope additively unions with group scope" do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      dba = runner_fixture(account_id: account.id, name: "dba1", group: "dba")
      edge = runner_fixture(account_id: account.id, name: "edge1", group: "edge")
      _other = runner_fixture(account_id: account.id, name: "other", group: "misc")

      {:ok, :ok} =
        Accounts.replace_runner_scopes(membership, [
          {"group", "dba"},
          {"runner", edge.id}
        ], subject)

      {:ok, runners, _} =
        Runners.list_runners_for_account(subject, membership_id: membership.id)

      names = runners |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["dba1", "edge1"]
      _ = dba
    end
  end

  describe "Runs.dispatch_run/2 with :requested_by_membership_id" do
    test "rejects out-of-scope runner" do
      {account, user, subject} = account_with_owner()
      {:ok, membership} = Accounts.fetch_membership_for_session(user, nil)
      _runner_in = runner_fixture(account_id: account.id, name: "in", group: "dba")
      runner_out = runner_fixture(account_id: account.id, name: "out", group: "app")

      {:ok, :ok} =
        Accounts.replace_runner_scopes(membership, [{"group", "dba"}], subject)

      assert {:error, :runner_out_of_scope} =
               Runs.dispatch_run(%{
                 runner_id: runner_out.id,
                 action_id: "x.y",
                 reason: "test",
                 requested_by_id: user.id,
                 requested_by_membership_id: membership.id
               }, Emisar.Auth.Subject.system(account))
    end

    test "no membership_id passed = bypasses the check (MCP/system path)" do
      {account, _user, _subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id, group: "dba")

      # No `requested_by_membership_id` → skips scope check entirely.
      # Falls through to `:action_not_found` because we haven't seeded
      # the catalog — that's the expected next error after the gate
      # passes.
      assert {:error, :action_not_found} =
               Runs.dispatch_run(%{
                 runner_id: runner.id,
                 action_id: "x.y",
                 reason: "test"
               }, Emisar.Auth.Subject.system(account))
    end
  end

  describe "runner_scopes_for_membership_ids/1" do
    test "groups scopes by membership_id for batch rendering" do
      {_account, user_a, subject} = account_with_owner()
      {:ok, m_a} = Accounts.fetch_membership_for_session(user_a, nil)

      email_b = "b-#{System.unique_integer()}@example.com"
      {:ok, %{membership: m_b}} =
        Accounts.invite_user_to_account(email_b, "admin", subject)

      {:ok, :ok} = Accounts.replace_runner_scopes(m_a, [{"group", "dba"}], subject)
      {:ok, :ok} = Accounts.replace_runner_scopes(m_b, [{"group", "app"}], subject)

      grouped = Accounts.runner_scopes_for_membership_ids([m_a.id, m_b.id])

      assert [%{scope_value: "dba"}] = Map.get(grouped, m_a.id)
      assert [%{scope_value: "app"}] = Map.get(grouped, m_b.id)
    end
  end

  defp account_with_owner do
    user = user_fixture()
    {:ok, account} = Accounts.create_account_with_owner(%{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"}, user)
    subject = subject_for(user, account, role: :owner)
    {account, user, subject}
  end
end
