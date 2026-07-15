defmodule Emisar.MCPOperationsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.{ApiKeys, Auth, MCPOperations, Repo}
  alias Emisar.Fixtures

  @operation_id "op_724NN9NMDZ1T76NARWCKM5A0D6"
  @fingerprint String.duplicate("a", 64)
  @pack_ref "linux-core@1.0.0/sha256:" <> String.duplicate("b", 64)

  setup do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    owner_subject = Auth.Subject.for_user(user, account, membership)
    {:ok, _raw, key} = ApiKeys.create_key(%{name: "MCP"}, owner_subject)
    key_subject = Auth.Subject.for_api_key(key, account)

    %{
      account: account,
      key: key,
      key_subject: key_subject,
      owner_subject: owner_subject
    }
  end

  describe "reserve_in_multi/3" do
    test "reserves once and returns the winner for an exact replay", %{
      key_subject: key_subject
    } do
      attrs = action_operation_attrs()

      assert {:ok, first_multi} =
               MCPOperations.reserve_in_multi(Multi.new(), attrs, key_subject)

      assert {:ok, %{mcp_operation: %{operation: first, fresh?: true}}} =
               Repo.commit_multi(first_multi)

      assert {:ok, replay_multi} =
               MCPOperations.reserve_in_multi(Multi.new(), attrs, key_subject)

      assert {:ok, %{mcp_operation: %{operation: replay, fresh?: false}}} =
               Repo.commit_multi(replay_multi)

      assert replay.id == first.id
      assert replay.operation_id == @operation_id
      assert replay.action_id == "linux.uptime"
      assert replay.pack_ref == @pack_ref
    end

    test "rejects different facts or a different tool under the same identity", %{
      key_subject: key_subject
    } do
      reserve!(action_operation_attrs(), key_subject)

      changed = Map.put(action_operation_attrs(), :fingerprint, String.duplicate("c", 64))
      assert_operation_conflict(changed, key_subject)

      cross_tool = %{
        operation_id: @operation_id,
        tool: :create_runbook_draft,
        fingerprint: @fingerprint,
        resource_id: Ecto.UUID.generate(),
        resource_ref: "draft"
      }

      assert_operation_conflict(cross_tool, key_subject)
    end

    test "requires an API-client subject with the reserve permission", %{
      owner_subject: owner_subject
    } do
      assert {:error, :unauthorized} =
               MCPOperations.reserve_in_multi(
                 Multi.new(),
                 action_operation_attrs(),
                 owner_subject
               )
    end
  end

  describe "operation_id/2" do
    test "is stable across retries and key rotation but isolated by request and lineage", %{
      account: account,
      key_subject: key_subject,
      owner_subject: owner_subject
    } do
      request = ~s({"jsonrpc":"2.0","id":7,"method":"tools/call"})
      operation_id = MCPOperations.operation_id(request, key_subject)

      assert operation_id =~ ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/
      assert MCPOperations.operation_id(request, key_subject) == operation_id
      refute MCPOperations.operation_id(request <> " ", key_subject) == operation_id

      {:ok, _raw, successor} = ApiKeys.rotate_api_key(key_subject.actor, owner_subject)
      successor_subject = Auth.Subject.for_api_key(successor, account)
      assert MCPOperations.operation_id(request, successor_subject) == operation_id

      {:ok, _raw, other_key} = ApiKeys.create_key(%{name: "Other MCP"}, owner_subject)
      other_subject = Auth.Subject.for_api_key(other_key, account)
      refute MCPOperations.operation_id(request, other_subject) == operation_id

      foreign_user = Fixtures.Users.create_user()
      foreign_account = Fixtures.Accounts.create_account()

      foreign_membership =
        Fixtures.Memberships.create_membership(
          account_id: foreign_account.id,
          user_id: foreign_user.id,
          role: "owner"
        )

      foreign_owner = Auth.Subject.for_user(foreign_user, foreign_account, foreign_membership)
      {:ok, _raw, foreign_key} = ApiKeys.create_key(%{name: "Foreign MCP"}, foreign_owner)
      foreign_subject = Auth.Subject.for_api_key(foreign_key, foreign_account)
      refute MCPOperations.operation_id(request, foreign_subject) == operation_id
    end
  end

  describe "fetch_recovery/2" do
    test "survives key rotation but hides other lineages and accounts", %{
      account: account,
      key_subject: key_subject,
      owner_subject: owner_subject
    } do
      operation = reserve!(action_operation_attrs(), key_subject)

      assert {:ok, fetched} = MCPOperations.fetch_recovery(@operation_id, key_subject)
      assert fetched.id == operation.id

      assert {:ok, _raw, successor} = ApiKeys.rotate_api_key(key_subject.actor, owner_subject)
      successor_subject = Auth.Subject.for_api_key(successor, account)

      assert {:ok, rotated} = MCPOperations.fetch_recovery(@operation_id, successor_subject)
      assert rotated.id == operation.id

      {:ok, _raw, other_key} = ApiKeys.create_key(%{name: "Other MCP"}, owner_subject)
      other_lineage_subject = Auth.Subject.for_api_key(other_key, account)

      assert {:error, :not_found} =
               MCPOperations.fetch_recovery(@operation_id, other_lineage_subject)

      other_user = Fixtures.Users.create_user()
      other_account = Fixtures.Accounts.create_account()

      other_membership =
        Fixtures.Memberships.create_membership(
          account_id: other_account.id,
          user_id: other_user.id,
          role: "owner"
        )

      other_owner = Auth.Subject.for_user(other_user, other_account, other_membership)
      {:ok, _raw, foreign_key} = ApiKeys.create_key(%{name: "Foreign MCP"}, other_owner)
      foreign_subject = Auth.Subject.for_api_key(foreign_key, other_account)

      assert {:error, :not_found} =
               MCPOperations.fetch_recovery(@operation_id, foreign_subject)
    end

    test "requires the view permission", %{owner_subject: owner_subject} do
      assert {:error, :unauthorized} =
               MCPOperations.fetch_recovery(@operation_id, owner_subject)
    end
  end

  describe "resource_id/3" do
    test "is stable within one lineage and distinct across tools and lineages", %{
      account: account,
      key_subject: key_subject,
      owner_subject: owner_subject
    } do
      draft_id =
        MCPOperations.resource_id(@operation_id, :create_runbook_draft, key_subject)

      assert Ecto.UUID.cast(draft_id) == {:ok, draft_id}

      assert MCPOperations.resource_id(
               @operation_id,
               :create_runbook_draft,
               key_subject
             ) == draft_id

      refute MCPOperations.resource_id(@operation_id, :execute_runbook, key_subject) == draft_id

      {:ok, _raw, successor} = ApiKeys.rotate_api_key(key_subject.actor, owner_subject)
      successor_subject = Auth.Subject.for_api_key(successor, account)

      assert MCPOperations.resource_id(
               @operation_id,
               :create_runbook_draft,
               successor_subject
             ) == draft_id

      {:ok, _raw, other_key} = ApiKeys.create_key(%{name: "Other MCP"}, owner_subject)
      other_subject = Auth.Subject.for_api_key(other_key, account)

      refute MCPOperations.resource_id(
               @operation_id,
               :create_runbook_draft,
               other_subject
             ) == draft_id
    end
  end

  defp action_operation_attrs do
    %{
      operation_id: @operation_id,
      tool: :run_action,
      fingerprint: @fingerprint,
      action_id: "linux.uptime",
      pack_ref: @pack_ref
    }
  end

  defp reserve!(attrs, subject) do
    {:ok, multi} = MCPOperations.reserve_in_multi(Multi.new(), attrs, subject)
    {:ok, %{mcp_operation: %{operation: operation}}} = Repo.commit_multi(multi)
    operation
  end

  defp assert_operation_conflict(attrs, subject) do
    assert {:ok, multi} = MCPOperations.reserve_in_multi(Multi.new(), attrs, subject)
    assert {:error, :operation_conflict} = Repo.commit_multi(multi)
  end
end
