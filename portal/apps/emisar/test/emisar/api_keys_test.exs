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

    test "an owner of account B never sees account A's keys (cross-account isolation)" do
      {_user_a, account_a, subject_a} = owner_subject_pair()

      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "a-key", scopes: ["actions:read"]}, subject_a)

      _ = account_a

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(subject_b)
      assert {:ok, [], _} = ApiKeys.list_audit_export_keys_for_account(subject_b)
    end
  end

  describe "fetch_api_key_by_id/3" do
    test "returns the key inside the subject's account" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = api_key_fixture(account_id: account.id)

      assert {:ok, fetched} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert fetched.id == key.id
    end

    test "an owner of account B cannot fetch account A's key (cross-account → :not_found)" do
      account_a = account_fixture()
      {_raw, key_a} = api_key_fixture(account_id: account_a.id)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:error, :not_found} = ApiKeys.fetch_api_key_by_id(key_a.id, subject_b)
    end

    test "a malformed id is a clean :not_found, not a cast crash" do
      {_user, _account, subject} = owner_subject_pair()
      assert {:error, :not_found} = ApiKeys.fetch_api_key_by_id("not-a-uuid", subject)
    end
  end

  describe "change_key/1" do
    test "validates the form fields without touching the DB" do
      assert %Ecto.Changeset{} = changeset = ApiKeys.change_key(%{name: "ci"})
      assert changeset.valid?

      # Scope validation belongs to create_key/2; the form only gates the
      # operator-typed fields.
      refute ApiKeys.change_key(%{}).valid?
      refute ApiKeys.change_key(%{name: String.duplicate("x", 81)}).valid?
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
    test "mints a pre-scoped auto key, hidden until first use" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, raw, %ApiKey{} = key} = ApiKeys.mint_quick_key(subject)
      assert String.starts_with?(raw, "emk-")
      assert %DateTime{} = key.auto_generated_at
      assert "actions:read" in key.scopes
      assert "actions:execute" in key.scopes

      # Auto-unused keys never show on the operator-facing list.
      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(subject)
    end

    test "ring eviction drops the oldest auto-unused key past the cap, never a used one" do
      {_user, _account, subject} = owner_subject_pair()
      opts = [ring_cap: 1, eviction_grace_seconds: 0]

      {:ok, used_raw, used_key} = ApiKeys.mint_quick_key(subject, opts)
      # First use clears the auto flag — eviction must not touch it.
      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(used_raw)

      {:ok, _raw, evictable} = ApiKeys.mint_quick_key(subject, opts)
      {:ok, _raw, survivor} = ApiKeys.mint_quick_key(subject, opts)

      refute Repo.reload(evictable)
      assert Repo.reload(survivor)
      assert Repo.reload(used_key)
    end

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

    test "returns nil for an expired key" do
      yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      {raw, _key} = api_key_fixture(expires_at: yesterday)

      refute ApiKeys.peek_api_key_by_secret(raw)
    end

    test "first use of an auto key clears the flag and audits api_key.bound" do
      {_user, _account, subject} = owner_subject_pair()
      {:ok, raw, _key} = ApiKeys.mint_quick_key(subject)

      assert %ApiKey{} = bound = ApiKeys.peek_api_key_by_secret(raw)
      refute bound.auto_generated_at

      # Bound keys surface on the operator list from here on.
      assert {:ok, [visible], _} = ApiKeys.list_api_keys_for_account(subject)
      assert visible.id == bound.id

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["api_key.bound"]])

      assert event.subject_id == bound.id
    end
  end

  describe "peek_api_key_by_id/1" do
    test "returns a usable key, nil for revoked or unknown" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = api_key_fixture(account_id: account.id)

      assert %ApiKey{id: id} = ApiKeys.peek_api_key_by_id(key.id)
      assert id == key.id

      {:ok, _} = ApiKeys.revoke_api_key(key, subject)
      refute ApiKeys.peek_api_key_by_id(key.id)
      refute ApiKeys.peek_api_key_by_id(Ecto.UUID.generate())
    end
  end

  describe "record_client_info/2" do
    test "persists the sanitized clientInfo map" do
      {_raw, key} = api_key_fixture()

      assert {:ok, updated} =
               ApiKeys.record_client_info(key, %{"name" => "Claude Code", "version" => "1.0"})

      assert updated.last_client_info == %{"name" => "Claude Code", "version" => "1.0"}
    end

    test "rejects a non-map payload" do
      {_raw, key} = api_key_fixture()
      assert {:error, :invalid} = ApiKeys.record_client_info(key, "junk")
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
