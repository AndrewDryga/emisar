defmodule Emisar.PoliciesScopesTest do
  @moduledoc """
  Per-runner / per-group policy overrides: resolution precedence
  (runner > group > account), scoped CRUD, and the scoped evaluation the
  dispatch path drives.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Policies

  @allow_all %{
    "schema_version" => 2,
    "defaults" => %{
      "low" => "allow",
      "medium" => "allow",
      "high" => "allow",
      "critical" => "allow"
    },
    "overrides" => []
  }

  @deny_all %{
    "schema_version" => 2,
    "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
    "overrides" => []
  }

  describe "resolve_policy/3 precedence (runner > group > account)" do
    test "a runner-scoped policy wins over group and account" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(@allow_all, subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :group, "db", subject)
      {:ok, runner_policy} = Policies.save_scoped_rules(@allow_all, :runner, "runner-1", subject)

      resolved = Policies.resolve_policy(account.id, "runner-1", "db")
      assert resolved.id == runner_policy.id
      assert resolved.scope_type == :runner
    end

    test "a group-scoped policy wins over the account default when no runner override" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(@allow_all, subject)
      {:ok, group_policy} = Policies.save_scoped_rules(@deny_all, :group, "db", subject)

      resolved = Policies.resolve_policy(account.id, "runner-x", "db")
      assert resolved.id == group_policy.id
      assert resolved.scope_type == :group
    end

    test "falls through to the account default when no scope matches" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, account_policy} = Policies.save_rules(@allow_all, subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :group, "db", subject)

      # A runner in a different group with no runner override → account default.
      resolved = Policies.resolve_policy(account.id, "runner-x", "web")
      assert resolved.id == account_policy.id
      assert resolved.scope_type == :account
    end

    test "no policy at all resolves to nil (default-deny)" do
      account = account_fixture()
      assert Policies.resolve_policy(account.id, "runner-x", "db") == nil
    end

    test "scoped policies never leak across accounts" do
      {_user, account_a, subject_a} = owner_subject_fixture()
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :runner, "shared-id", subject_a)

      {_user, account_b, _subject_b} = owner_subject_fixture()

      # Account B has the same runner-id string but no override of its own.
      assert Policies.resolve_policy(account_b.id, "shared-id", "db") |> account_scope?()
      assert Policies.resolve_policy(account_a.id, "shared-id", "db").scope_type == :runner
    end
  end

  describe "evaluate_with_policy/3 with a runner-scoped override" do
    test "the override governs its runner; other runners get the account default" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(@allow_all, subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject)

      governed = %{action_id: "linux.uptime", risk: :low, runner_id: "runner-1"}
      assert {:deny, _, _, policy} = Policies.evaluate_with_policy(account.id, governed, nil)
      assert policy.scope_type == :runner

      other = %{action_id: "linux.uptime", risk: :low, runner_id: "runner-2"}

      assert {:allow, _, _, account_policy} =
               Policies.evaluate_with_policy(account.id, other, nil)

      assert account_policy.scope_type == :account
    end

    test "a group override governs every runner in that group" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(@allow_all, subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :group, "prod", subject)

      attrs = %{action_id: "linux.uptime", risk: :low, runner_id: "any-runner"}
      assert {:deny, _, _, policy} = Policies.evaluate_with_policy(account.id, attrs, "prod")
      assert policy.scope_type == :group
    end

    test "a scoped decision's reason names the override it came from" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(@allow_all, subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :group, "prod", subject)

      runner = %{action_id: "linux.uptime", risk: :low, runner_id: "runner-1"}
      assert {:deny, _, reason, _} = Policies.evaluate_with_policy(account.id, runner, nil)
      assert reason =~ "this runner's policy override"

      group = %{action_id: "linux.uptime", risk: :low, runner_id: "any"}

      assert {:deny, _, group_reason, _} =
               Policies.evaluate_with_policy(account.id, group, "prod")

      assert group_reason =~ ~s(the "prod" group policy override)

      # An account-scoped decision keeps the plain reason — no scope annotation.
      other = %{action_id: "linux.uptime", risk: :low, runner_id: "elsewhere"}

      assert {:allow, _, account_reason, _} =
               Policies.evaluate_with_policy(account.id, other, nil)

      refute account_reason =~ "policy override"
    end
  end

  describe "scoped CRUD (save / fetch / list / delete)" do
    test "saves, fetches, lists (account default excluded), and deletes an override" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, policy} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject)
      assert policy.scope_type == :runner
      assert policy.scope_value == "runner-1"

      assert {:ok, fetched} = Policies.fetch_scoped_policy(:runner, "runner-1", subject)
      assert fetched.id == policy.id

      assert {:ok, [listed]} = Policies.list_scoped_policies(subject)
      assert listed.id == policy.id

      assert {:ok, _} = Policies.delete_scoped_policy(policy, subject)
      assert {:error, :not_found} = Policies.fetch_scoped_policy(:runner, "runner-1", subject)
      assert {:ok, []} = Policies.list_scoped_policies(subject)
    end

    test "editing a scope upserts the same row and bumps vsn" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, v1} = Policies.save_scoped_rules(@deny_all, :group, "db", subject)
      {:ok, v2} = Policies.save_scoped_rules(@allow_all, :group, "db", subject)

      assert v2.id == v1.id
      assert v2.vsn == v1.vsn + 1
    end

    test "a viewer can neither save nor delete a scoped policy" do
      {_user, account, owner} = owner_subject_fixture()
      viewer = subject_for(user_fixture(), account, role: :viewer)

      assert {:error, :unauthorized} =
               Policies.save_scoped_rules(@deny_all, :runner, "r1", viewer)

      {:ok, policy} = Policies.save_scoped_rules(@deny_all, :runner, "r1", owner)
      assert {:error, :unauthorized} = Policies.delete_scoped_policy(policy, viewer)
    end

    test "cross-account: can't fetch or delete another account's override" do
      {_user, _account_a, subject_a} = owner_subject_fixture()
      {:ok, policy_a} = Policies.save_scoped_rules(@deny_all, :runner, "r1", subject_a)

      {_user, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :not_found} = Policies.fetch_scoped_policy(:runner, "r1", subject_b)
      assert {:error, :not_found} = Policies.delete_scoped_policy(policy_a, subject_b)
    end

    test "a runner/group scope requires a non-empty scope_value" do
      {_user, _account, subject} = owner_subject_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Policies.save_scoped_rules(@deny_all, :runner, "", subject)

      assert %{scope_value: [_ | _]} = errors_on(changeset)
    end
  end

  defp account_scope?(%Policies.Policy{scope_type: :account}), do: true
  defp account_scope?(_), do: false
end
