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

    # the catalog hands risk as an Ecto.Enum atom (:high),
    # but the rules key their tiers by string ("high"). evaluate_with_policy
    # bridges via to_string, so the atom and the string must reach the SAME tier.
    test "an atom risk and its string form select the same tier decision" do
      {_user, account, subject} = owner_subject_fixture()

      # Distinct per-tier decisions so a mis-bridged risk would land on the wrong one.
      tiered = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => []
      }

      {:ok, _} = Policies.save_rules(tiered, subject)

      atom_attrs = %{action_id: "linux.uptime", risk: :high, runner_id: "r1"}
      string_attrs = %{action_id: "linux.uptime", risk: "high", runner_id: "r1"}

      assert {:require_approval, _, _, _} =
               Policies.evaluate_with_policy(account.id, atom_attrs, nil)

      assert {:require_approval, _, _, _} =
               Policies.evaluate_with_policy(account.id, string_attrs, nil)
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

  describe "scope uniqueness — at most one live policy per (account, scope)" do
    test "saving the same runner scope twice replaces in place, never duplicates" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, first} = Policies.save_scoped_rules(@allow_all, :runner, "runner-1", subject)
      {:ok, second} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject)

      # Same row updated — the partial unique index + the upsert make a second
      # live policy for the same scope impossible (no undefined "which wins").
      assert first.id == second.id
      assert second.rules["defaults"]["low"] == "deny"

      {:ok, scoped} = Policies.list_scoped_policies(subject)
      assert Enum.count(scoped, &(&1.scope_type == :runner and &1.scope_value == "runner-1")) == 1
    end

    test "a runner and a group with the same name are distinct policies" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, runner_policy} = Policies.save_scoped_rules(@allow_all, :runner, "db", subject)
      {:ok, group_policy} = Policies.save_scoped_rules(@deny_all, :group, "db", subject)

      refute runner_policy.id == group_policy.id
      {:ok, scoped} = Policies.list_scoped_policies(subject)
      assert length(scoped) == 2
    end

    test "different runners get independent policies" do
      {_user, _account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_scoped_rules(@allow_all, :runner, "runner-a", subject)
      {:ok, _} = Policies.save_scoped_rules(@deny_all, :runner, "runner-b", subject)

      {:ok, scoped} = Policies.list_scoped_policies(subject)
      assert length(scoped) == 2
    end

    # deleting a runner ruleset SOFT-deletes it (`deleted_at`
    # set), and the unique index is partial (`WHERE deleted_at IS NULL`). So the
    # same scope can be claimed again by a fresh save: the upsert's conflict target
    # repeats that predicate, the tombstoned row is invisible to it, and a NEW live
    # row is created — never a unique violation, and `list_scoped_policies` (which
    # filters `not_deleted`) shows exactly the new one.
    test "soft-deleting a runner ruleset lets the same scope be saved again (new live row)" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, original} = Policies.save_scoped_rules(@allow_all, :runner, "runner-1", subject)
      {:ok, _deleted} = Policies.delete_scoped_policy(original, subject)

      # The tombstoned row no longer lists.
      {:ok, after_delete} = Policies.list_scoped_policies(subject)
      refute Enum.any?(after_delete, &(&1.id == original.id))

      # Re-claiming the freed scope succeeds (partial unique index ignores the
      # tombstone) and produces a DISTINCT live row.
      {:ok, reclaimed} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject)
      refute reclaimed.id == original.id
      assert reclaimed.rules["defaults"]["low"] == "deny"

      {:ok, live} = Policies.list_scoped_policies(subject)
      runner_1 = Enum.filter(live, &(&1.scope_type == :runner and &1.scope_value == "runner-1"))
      assert [%{id: id}] = runner_1
      assert id == reclaimed.id
    end
  end

  describe "cross-account write isolation (a subject only ever writes its OWN account)" do
    # the account/default policy WRITE derives account_id
    # from the subject, so account B's owner saving rules lands on B's policy and
    # can NEVER touch account A's. (Cross-account READ/DELETE return :not_found —
    # see fetch/delete tests above; the WRITE path's isolation is the row scoping.)
    test "account B's save_rules never mutates account A's default policy" do
      {_user_a, account_a, subject_a} = owner_subject_fixture()
      {:ok, policy_a} = Policies.save_rules(@deny_all, subject_a)

      {_user_b, account_b, subject_b} = owner_subject_fixture()
      {:ok, policy_b} = Policies.save_rules(@allow_all, subject_b)

      # B's write created/updated B's own row, not A's.
      assert policy_b.account_id == account_b.id
      refute policy_b.id == policy_a.id

      # A's policy is byte-for-byte unchanged — same row, same rules, same vsn.
      reloaded_a = Policies.peek_policy_for_account(account_a.id)
      assert reloaded_a.id == policy_a.id
      assert reloaded_a.rules == policy_a.rules
      assert reloaded_a.vsn == policy_a.vsn
      assert reloaded_a.account_id == account_a.id
    end

    # a SCOPED (runner/group) ruleset WRITE is
    # likewise account-bound. B saving a "runner-1" / "prod" override creates B's
    # own scoped row; A's same-named override is untouched, even though the
    # scope_value strings collide.
    test "account B's save_scoped_rules never mutates account A's same-named override" do
      {_user_a, _account_a, subject_a} = owner_subject_fixture()
      {:ok, runner_a} = Policies.save_scoped_rules(@deny_all, :runner, "runner-1", subject_a)
      {:ok, group_a} = Policies.save_scoped_rules(@deny_all, :group, "prod", subject_a)

      {_user_b, account_b, subject_b} = owner_subject_fixture()
      {:ok, runner_b} = Policies.save_scoped_rules(@allow_all, :runner, "runner-1", subject_b)
      {:ok, group_b} = Policies.save_scoped_rules(@allow_all, :group, "prod", subject_b)

      # B's scoped writes are distinct rows in B's account.
      assert runner_b.account_id == account_b.id
      assert group_b.account_id == account_b.id
      refute runner_b.id == runner_a.id
      refute group_b.id == group_a.id

      # A still resolves its OWN (deny) overrides for the colliding scope names.
      assert {:ok, fetched_runner_a} =
               Policies.fetch_scoped_policy(:runner, "runner-1", subject_a)

      assert fetched_runner_a.id == runner_a.id
      assert fetched_runner_a.rules["defaults"]["low"] == "deny"
      assert fetched_runner_a.vsn == runner_a.vsn

      assert {:ok, fetched_group_a} = Policies.fetch_scoped_policy(:group, "prod", subject_a)
      assert fetched_group_a.id == group_a.id
      assert fetched_group_a.rules["defaults"]["low"] == "deny"

      # Sanity: A sees exactly its two overrides, none of B's leaked in.
      {:ok, a_scoped} = Policies.list_scoped_policies(subject_a)
      assert Enum.map(a_scoped, & &1.id) |> Enum.sort() == Enum.sort([runner_a.id, group_a.id])
    end

    # A viewer of the account can't save the default OR a scoped ruleset — the
    # denial (manage_policies) shape on the write path is :unauthorized, distinct
    # from the cross-account :not_found above.
    test "a viewer is denied both the default and the scoped write (:unauthorized)" do
      {_user, account, _owner} = owner_subject_fixture()
      viewer = subject_for(user_fixture(), account, role: :viewer)

      assert {:error, :unauthorized} = Policies.save_rules(@deny_all, viewer)

      assert {:error, :unauthorized} =
               Policies.save_scoped_rules(@deny_all, :runner, "runner-1", viewer)
    end
  end

  defp account_scope?(%Policies.Policy{scope_type: :account}), do: true
  defp account_scope?(_), do: false
end
