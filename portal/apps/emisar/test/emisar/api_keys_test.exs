defmodule Emisar.ApiKeysTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{ApiKeys, Repo}
  alias Emisar.ApiKeys.ApiKey

  defp owner_subject_pair do
    user = user_fixture()
    account = account_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    {user, account, subject_for(user, account, role: :owner)}
  end

  describe "list buckets" do
    test "audit-export tokens land on the audit list, never the agents list" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, agent_key} =
        ApiKeys.create_key(%{name: "agent", scopes: ["actions:read"]}, subject)

      {:ok, _raw, export_key} =
        ApiKeys.create_key(%{name: "siem", scopes: ["audit:read"]}, subject)

      assert {:ok, [agents_visible], _} = ApiKeys.list_api_keys_for_account(subject)
      assert agents_visible.id == agent_key.id

      assert {:ok, [export_visible], _} = ApiKeys.list_audit_export_keys_for_account(subject)
      assert export_visible.id == export_key.id
    end
  end

  describe "create_key/2" do
    test "returns raw + persisted key" do
      {user, account, subject} = owner_subject_pair()

      assert {:ok, raw, %ApiKey{} = key} =
               ApiKeys.create_key(
                 %{
                   name: "ci",
                   scopes: ["actions:read"]
                 },
                 subject
               )

      assert String.starts_with?(raw, "emk-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert is_binary(key.key_prefix)
    end

    test "rejects unknown scopes" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:error, cs} =
               ApiKeys.create_key(
                 %{
                   name: "bad",
                   scopes: ["actions:nuclear-launch"]
                 },
                 subject
               )

      assert "has an invalid entry" in errors_on(cs).scopes
    end

    test "an operator (no manage_api_keys permission) is refused with :unauthorized" do
      # A custom key mints an execute-capable MCP credential, so it gates
      # on `manage_api_keys` — which operators lack (they may only mint
      # the pre-scoped quick key via `mint_quick_key/1`).
      account = account_fixture()
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               ApiKeys.create_key(%{name: "ci", scopes: ["actions:read"]}, subject)
    end
  end

  describe "mint_quick_key/1" do
    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      # Operators CAN mint the quick key; only viewers are below the
      # `issue_quick` line, so the denial subject must be a viewer.
      account = account_fixture()
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = ApiKeys.mint_quick_key(subject)
    end
  end

  describe "peek_api_key_by_secret/1" do
    test "returns the key for a valid raw secret + bumps last_used_at" do
      {raw, key} = api_key_fixture()
      refute key.last_used_at

      assert %ApiKey{id: id, last_used_at: ts} = ApiKeys.peek_api_key_by_secret(raw)
      assert id == key.id
      assert %DateTime{} = ts
    end

    test "returns nil for garbage" do
      refute ApiKeys.peek_api_key_by_secret("not-a-key")
      refute ApiKeys.peek_api_key_by_secret("")
    end

    test "returns nil after the key is revoked" do
      {_user, account, subject} = owner_subject_pair()
      {raw, key} = api_key_fixture(account_id: account.id)
      {:ok, _} = ApiKeys.revoke_api_key(key, subject)

      refute ApiKeys.peek_api_key_by_secret(raw)
    end
  end

  describe "revoke_api_key/2" do
    test "marks revoked_at" do
      {user, account, subject} = owner_subject_pair()
      {_raw, key} = api_key_fixture(account_id: account.id)

      assert {:ok, %ApiKey{revoked_at: %DateTime{}, revoked_by_id: id}} =
               ApiKeys.revoke_api_key(key, subject)

      assert id == user.id
      assert Repo.reload!(key).revoked_at
    end

    test "an operator (no manage_api_keys permission) is refused with :unauthorized" do
      account = account_fixture()
      {_raw, key} = api_key_fixture(account_id: account.id)
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = ApiKeys.revoke_api_key(key, subject)
      refute Repo.reload!(key).revoked_at
    end

    test "an owner of account B cannot revoke account A's key (cross-account → :not_found)" do
      account_a = account_fixture()
      {_raw, key_a} = api_key_fixture(account_id: account_a.id)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:error, :not_found} = ApiKeys.revoke_api_key(key_a, subject_b)
      refute Repo.reload!(key_a).revoked_at
    end
  end
end
