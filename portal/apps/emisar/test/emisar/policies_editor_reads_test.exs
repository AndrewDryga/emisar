defmodule Emisar.PoliciesEditorReadsTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Catalog, Fixtures, Policies, Repo, Runners}

  setup do
    {user, account, subject} = Fixtures.Subjects.owner_subject()

    %{
      user: user,
      account: account,
      subject: subject,
      denied: Fixtures.Subjects.permissionless_subject(account)
    }
  end

  describe "list_scoped_policy_summaries/2" do
    test "preserves runner type and current label, with a UUID fallback after deletion", %{
      account: account,
      subject: subject,
      user: user
    } do
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "database",
          connected?: false
        )

      scoped(account, user, :runner, runner.id)

      assert {:ok, [%{scope_type: :runner, target_label: "database"}], _} =
               Policies.list_scoped_policy_summaries(subject)

      Fixtures.Runners.mark_deleted(runner)

      assert {:ok, [%{scope_type: :runner, target_label: label}], _} =
               Policies.list_scoped_policy_summaries(subject)

      assert label == runner.id
    end

    test "a group named like a runner UUID does not borrow the runner label", %{
      account: account,
      subject: subject,
      user: user
    } do
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "database",
          connected?: false
        )

      scoped(account, user, :runner, runner.id)
      scoped(account, user, :group, runner.id)

      assert {:ok,
              [
                %{scope_type: :group, target_label: group},
                %{scope_type: :runner, target_label: "database"}
              ], _} = Policies.list_scoped_policy_summaries(subject)

      assert group == runner.id
    end

    test "pages summaries without loading rules, including empty configured groups", %{
      subject: subject,
      account: account,
      user: user
    } do
      policies =
        for i <- 1..27,
            do: scoped(account, user, :group, "group-#{String.pad_leading(to_string(i), 2, "0")}")

      assert {:ok, first, meta} = Policies.list_scoped_policy_summaries(subject)
      assert length(first) == 25
      assert meta.next_page_cursor
      refute Enum.any?(first, &Map.has_key?(&1, :rules))

      assert {:ok, last, _} =
               Policies.list_scoped_policy_summaries(subject,
                 page: [cursor: meta.next_page_cursor]
               )

      assert Enum.map(first ++ last, & &1.id) == Enum.map(policies, & &1.id)
    end

    test "denies permissionless and isolates accounts", %{
      denied: denied,
      account: account,
      user: user
    } do
      scoped(account, user, :group, "db")
      assert {:error, :unauthorized} = Policies.list_scoped_policy_summaries(denied)
      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:ok, [], _} = Policies.list_scoped_policy_summaries(other)
    end

    test "reads fresh restricted reach, including explicitly granted empty groups", %{
      account: account,
      user: user
    } do
      empty = scoped(account, user, :group, "empty")
      scoped(account, user, :group, "hidden")
      member = member(account, ["empty"])

      assert {:ok, [%{id: id}], _} =
               Policies.list_scoped_policy_summaries(Fixtures.Subjects.membership_subject(member))

      assert id == empty.id
      Fixtures.Memberships.force_runner_access(member, RunnerAccess.none())

      assert {:ok, [], _} =
               Policies.list_scoped_policy_summaries(Fixtures.Subjects.membership_subject(member))
    end
  end

  describe "fetch_scoped_policy_by_id/2" do
    test "loads exactly one full policy and refuses foreign, hidden, malformed and unauthorized ids",
         %{subject: subject, account: account, denied: denied, user: user} do
      policy = scoped(account, user, :group, "db")
      assert {:ok, loaded} = Policies.fetch_scoped_policy_by_id(policy.id, subject)
      assert loaded.rules == policy.rules
      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Policies.fetch_scoped_policy_by_id(policy.id, other)
      restricted = account |> member(["elsewhere"]) |> Fixtures.Subjects.membership_subject()
      assert {:error, :not_found} = Policies.fetch_scoped_policy_by_id(policy.id, restricted)
      assert {:error, :not_found} = Policies.fetch_scoped_policy_by_id("bad", subject)
      assert {:error, :unauthorized} = Policies.fetch_scoped_policy_by_id(policy.id, denied)
    end
  end

  describe "list_scope_target_options/3" do
    test "rejects malformed and oversized searches", %{
      subject: subject,
      denied: denied
    } do
      for search <- ["db\0", <<255>>, String.duplicate("a", 513), nil, []] do
        assert {:error, :invalid_search} = Policies.list_scope_target_options(search, subject)
        assert {:error, :unauthorized} = Policies.list_scope_target_options(search, denied)
      end

      assert {:ok, [], _} =
               Policies.list_scope_target_options(String.duplicate("é", 256), subject)
    end

    test "bounds pages and marks a taken target outside the first page", %{
      account: account,
      subject: subject,
      denied: denied,
      user: user
    } do
      for i <- 1..27 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "runner-#{i}",
          group: "fleet",
          connected?: false
        )
      end

      assert {:ok, first, meta} = Policies.list_scope_target_options("", subject)
      assert length(first) == 25

      assert {:ok, last, _} =
               Policies.list_scope_target_options("", subject,
                 page: [cursor: meta.next_page_cursor]
               )

      target = List.last(last)
      policy = scoped(account, user, :runner, target.scope_value)

      assert {:ok, [%{taken?: true, policy_id: id}], _} =
               Policies.list_scope_target_options(target.scope_value, subject)

      assert id == policy.id
      assert {:error, :unauthorized} = Policies.list_scope_target_options("", denied)
    end

    test "search escapes SQL wildcards and never includes another account", %{
      account: account,
      subject: subject
    } do
      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "db_1",
        group: "db",
        connected?: false
      )

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "dbx1",
        group: "db",
        connected?: false
      )

      Fixtures.Runners.create_runner(name: "db_1", connected?: false)

      assert {:ok, [%{label: "db_1"}], _} =
               Policies.list_scope_target_options("db_1", subject)
    end
  end

  describe "fetch_scope_target_option/3" do
    test "resolves an off-page selected identity with current reach", %{
      account: account,
      subject: subject,
      denied: denied
    } do
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "database",
          connected?: false
        )

      assert {:ok, %{label: "database", taken?: false}} =
               Policies.fetch_scope_target_option(:runner, runner.id, subject)

      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Policies.fetch_scope_target_option(:runner, runner.id, other)

      assert {:error, :unauthorized} =
               Policies.fetch_scope_target_option(:runner, runner.id, denied)

      restricted = account |> member(["empty"]) |> Fixtures.Subjects.membership_subject()

      assert {:ok, %{label: "empty"}} =
               Policies.fetch_scope_target_option(:group, "empty", restricted)

      assert {:error, :not_found} =
               Policies.fetch_scope_target_option(:runner, runner.id, restricted)
    end
  end

  describe "scope_target_available?/2" do
    test "accounts for every saved and reserved target, not just a page", %{
      account: account,
      subject: subject,
      denied: denied,
      user: user
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      assert {:ok, true} = Policies.scope_target_available?([], subject)
      scoped(account, user, :group, "db")
      assert {:ok, false} = Policies.scope_target_available?([{:runner, runner.id}], subject)
      assert {:error, :unauthorized} = Policies.scope_target_available?([], denied)
      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:ok, false} = Policies.scope_target_available?([], other)
    end
  end

  describe "current_runner_labels_for_ids/2" do
    test "includes only current account runners", %{account: account, subject: subject} do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "db", connected?: false)

      other = Fixtures.Runners.create_runner(connected?: false)

      assert Runners.current_runner_labels_for_ids(account.id, [runner.id, other.id]) == %{
               runner.id => "db"
             }

      assert {:ok, _} = Runners.delete_runner(runner, subject)
      assert Runners.current_runner_labels_for_ids(account.id, [runner.id]) == %{}
    end
  end

  describe "scope_targets_query/2" do
    test "none is empty; restricted includes an empty granted group and is account scoped", %{
      account: account
    } do
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: "hidden",
        connected?: false
      )

      Fixtures.Runners.create_runner(group: "empty", connected?: false)
      {:ok, access} = RunnerAccess.restricted(["empty"], [])
      query = Runners.scope_targets_query(account.id, access)
      assert [%{scope_type: "group", scope_value: "empty"}] = Repo.all(query)
      assert Repo.all(Runners.scope_targets_query(account.id, RunnerAccess.none())) == []
    end
  end

  describe "list_action_risks/3" do
    test "groups worst semantic risks and keyset-pages more than 100 actions", %{
      account: account,
      subject: subject
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      for i <- 1..103,
          do: action(runner, "db.action-#{String.pad_leading(to_string(i), 3, "0")}", "medium")

      second =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      action(second, "db.action-001", "critical")
      action(second, "db.action-002", "high")
      action(second, "db.action-003", "low")

      assert {:ok, first, meta} =
               Catalog.list_action_risks({:group, "db"}, subject, page: [limit: 100])

      assert length(first) == 100

      assert Enum.take(first, 3) == [
               %{action_id: "db.action-001", risk: "critical"},
               %{action_id: "db.action-002", risk: "high"},
               %{action_id: "db.action-003", risk: "medium"}
             ]

      assert meta.count == nil

      assert {:ok, last, _} =
               Catalog.list_action_risks(:account, subject,
                 page: [limit: 100, cursor: meta.next_page_cursor]
               )

      assert length(last) == 3
    end

    test "enforces current runner and pack access and account isolation", %{
      account: account,
      denied: denied
    } do
      db =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      hidden =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "hidden",
          connected?: false
        )

      action(db, "db.allowed", "low")
      Fixtures.Catalog.create_action(runner: db, action_id: "db.wrong-pack", pack_id: "other")
      action(hidden, "db.hidden", "critical")
      member = member(account, ["db"])
      {:ok, access} = RunnerAccess.new(:restricted, ["db"], [], :restricted, ["test"])
      Fixtures.Memberships.force_runner_access(member, access)
      subject = Fixtures.Subjects.membership_subject(member)
      assert {:ok, [%{action_id: "db.allowed"}], _} = Catalog.list_action_risks(:account, subject)
      Fixtures.Memberships.force_runner_access(member, RunnerAccess.none())
      assert {:ok, [], _} = Catalog.list_action_risks(:account, subject)
      assert {:error, :unauthorized} = Catalog.list_action_risks(:account, denied)
      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:ok, [], _} = Catalog.list_action_risks(:account, other)
    end
  end

  describe "preview_policy/4" do
    test "cooperatively stops before a query and retains a usable caller connection", %{
      subject: subject
    } do
      input = Policies.editor_input(Policies.default_rules())

      assert {:error, :cancelled} =
               Policies.preview_policy(input, :account, subject, cancelled?: fn -> true end)

      assert {:ok, _policy} = Policies.fetch_policy(subject)
    end

    test "pre-enrollment groups are a valid empty target for an unrestricted author", %{
      subject: subject
    } do
      input = Policies.editor_input(Policies.default_rules())
      assert {:ok, %{total: 0}} = Policies.preview_policy(input, {:group, "future"}, subject)
    end

    test "folds batches with first-match outcomes and original unmatched row indexes", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      for i <- 1..103,
          do: action(runner, "db.action#{String.pad_leading(to_string(i), 3, "0")}", "low")

      input = Policies.editor_input(Policies.default_rules())

      input = %{
        input
        | overrides: [
            Policies.empty_override(),
            %{"name" => "all", "action" => "DB.*", "decision" => "deny"},
            %{"name" => "later", "action" => "db.action001", "decision" => "allow"},
            %{"name" => "missing", "action" => "db\\.*", "decision" => "deny"}
          ]
      }

      assert {:ok, preview} = Policies.preview_policy(input, :account, subject)
      assert preview.total == 103

      assert preview.outcome["deny"] == %{
               count: 103,
               examples: ["db.action001", "db.action002", "db.action003"]
             }

      assert preview.breakdown == %{"low" => 103, "medium" => 0, "high" => 0, "critical" => 0}
      assert preview.unmatched_override_indexes == MapSet.new([3])
    end

    test "distinguishes an empty catalog from no access, and rejects hidden saved references", %{
      subject: subject,
      denied: denied,
      account: account,
      user: user
    } do
      input = Policies.editor_input(Policies.default_rules())

      assert {:ok, %{total: 0, unmatched_override_indexes: unmatched}} =
               Policies.preview_policy(input, :account, subject)

      assert unmatched == MapSet.new()
      assert {:error, :unauthorized} = Policies.preview_policy(input, :account, denied)
      policy = scoped(account, user, :group, "hidden")
      {_, _, other} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Policies.preview_policy(input, policy.id, other)
      member = member(account, ["db"])
      Fixtures.Memberships.force_runner_access(member, RunnerAccess.none())

      assert {:error, :no_access} =
               Policies.preview_policy(
                 input,
                 :account,
                 Fixtures.Subjects.membership_subject(member)
               )
    end

    test "refuses oversized override work before compiling globs", %{subject: subject} do
      input = Policies.editor_input(Policies.default_rules())

      assert {:error, :invalid_rules} =
               Policies.preview_policy(
                 %{input | overrides: List.duplicate(Policies.empty_override(), 201)},
                 :account,
                 subject
               )
    end
  end

  describe "preview_current?/2" do
    test "refuses publication after access changes or the subject loses permissions", %{
      account: account,
      denied: denied,
      subject: owner
    } do
      input = Policies.editor_input(Policies.default_rules())
      member = member(account, ["db"])
      subject = Fixtures.Subjects.membership_subject(member)
      assert {:ok, preview} = Policies.preview_policy(input, :account, subject)
      assert Policies.preview_current?(preview, subject)
      refute Policies.preview_current?(preview, denied)
      {_, _, other} = Fixtures.Subjects.owner_subject()
      refute Policies.preview_current?(preview, other)
      assert {:ok, account_preview} = Policies.preview_policy(input, :account, owner)
      refute Policies.preview_current?(account_preview, other)
      Fixtures.Memberships.force_runner_access(member, RunnerAccess.none())
      refute Policies.preview_current?(preview, subject)
    end

    test "refuses a runner moved outside a granted group even when the grant itself is unchanged",
         %{account: account, user: user} do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      policy = scoped(account, user, :runner, runner.id)
      subject = account |> member(["db"]) |> Fixtures.Subjects.membership_subject()
      input = Policies.editor_input(Policies.default_rules())
      assert {:ok, preview} = Policies.preview_policy(input, policy.id, subject)
      assert Policies.preview_current?(preview, subject)
      Fixtures.Runners.move_to_group(runner, "hidden")
      refute Policies.preview_current?(preview, subject)
    end

    test "refuses a removed saved policy", %{subject: subject, account: account, user: user} do
      policy = scoped(account, user, :group, "db")
      input = Policies.editor_input(Policies.default_rules())
      assert {:ok, preview} = Policies.preview_policy(input, policy.id, subject)
      assert {:ok, _} = Policies.delete_scoped_policy(policy, subject)
      refute Policies.preview_current?(preview, subject)
    end
  end

  defp scoped(account, user, type, value) do
    Fixtures.Policies.create_policy(
      account_id: account.id,
      created_by_id: user.id,
      scope_type: type,
      scope_value: value
    )
  end

  defp member(account, groups) do
    member = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    {:ok, access} = RunnerAccess.restricted(groups, [])
    Fixtures.Memberships.force_runner_access(member, access)
  end

  defp action(runner, id, risk),
    do: Fixtures.Catalog.create_action(runner: runner, action_id: id, risk: risk, pack_id: "test")
end
