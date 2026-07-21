defmodule Emisar.ApiKeysTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Audit, Crypto, Repo, RequestContext}
  alias Emisar.ApiKeys.{ApiKey, DeviceGrant}
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures

  defp owner_subject_pair do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    {user, account, Fixtures.Subjects.subject_for(user, account, role: :owner)}
  end

  describe "list_api_keys_for_account/2" do
    test "lists the account's :mcp keys, hiding audit-export tokens" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, agent_key} =
        ApiKeys.create_key(%{name: "agent"}, subject)

      {:ok, _raw, _export_key} =
        ApiKeys.create_key(%{name: "siem", kind: :audit_export}, subject)

      assert {:ok, [visible], _} = ApiKeys.list_api_keys_for_account(subject)
      assert visible.id == agent_key.id
    end

    test ":created_by is preloaded only when asked for via :preload" do
      {user, _account, subject} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "agent"}, subject)

      assert {:ok, [preloaded], _} =
               ApiKeys.list_api_keys_for_account(subject, preload: [:created_by])

      assert preloaded.created_by.id == user.id
    end

    test "a runner subject (no view_api_keys permission) is refused with :unauthorized" do
      # Operators + viewers both hold view_api_keys, so the genuine
      # no-permission caller is the runner (websocket) subject.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = ApiKeys.list_api_keys_for_account(subject)
    end

    test "an owner of account B never sees account A's keys (cross-account isolation)" do
      {_user_a, _account_a, subject_a} = owner_subject_pair()

      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "a-key"}, subject_a)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(subject_b)
    end
  end

  describe "list_key_owner_options/1 + the owner filter" do
    test "returns the distinct creators of the account's visible (non-audit) keys" do
      {user, _account, subject} = owner_subject_pair()

      {:ok, _raw, _k1} = ApiKeys.create_key(%{name: "a"}, subject)
      {:ok, _raw, _k2} = ApiKeys.create_key(%{name: "b"}, subject)
      # An audit-export key is on the audit list, not agents — its creator isn't
      # an agents "owner".
      {:ok, _raw, _siem} = ApiKeys.create_key(%{name: "siem", kind: :audit_export}, subject)

      assert {:ok, [{owner_id, owner_email}]} = ApiKeys.list_key_owner_options(subject)
      assert owner_id == user.id
      assert owner_email == user.email
    end

    test "the owner filter narrows to a creator's keys; another account sees none" do
      {user, _account, subject} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "mine"}, subject)

      assert {:ok, [key], _} =
               ApiKeys.list_api_keys_for_account(subject, filter: [owner: [user.id]])

      assert key.name == "mine"

      # A different creator id → nothing.
      assert {:ok, [], _} =
               ApiKeys.list_api_keys_for_account(subject, filter: [owner: [Ecto.UUID.generate()]])

      # Cross-account: B's owner options never include A's creator.
      {_user_b, _account_b, subject_b} = owner_subject_pair()
      assert {:ok, []} = ApiKeys.list_key_owner_options(subject_b)
    end

    test "a runner subject without view_api_keys permission is refused" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = ApiKeys.list_key_owner_options(subject)
    end
  end

  describe "list_key_options/1" do
    test "returns {id, name} for the account's agent keys, revoked included" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, live_key} =
        ApiKeys.create_key(%{name: "live"}, subject)

      {:ok, _raw, retired_key} =
        ApiKeys.create_key(%{name: "retired"}, subject)

      # Revoked keys stay pickable — their run history is exactly what an
      # operator filters for. Audit-export tokens never create runs, so they
      # are not an Agent option.
      {:ok, _} = ApiKeys.revoke_api_key(retired_key, subject)
      {:ok, _raw, _siem} = ApiKeys.create_key(%{name: "siem", kind: :audit_export}, subject)

      assert {:ok, options} = ApiKeys.list_key_options(subject)

      assert Enum.sort(options) ==
               Enum.sort([{live_key.id, "live"}, {retired_key.id, "retired"}])
    end

    test "cross-account — B's options never include A's keys; a viewer can read" do
      {_user, account, subject} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "mine"}, subject)

      {_user_b, _account_b, subject_b} = owner_subject_pair()
      assert {:ok, []} = ApiKeys.list_key_options(subject_b)

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)
      assert {:ok, [{_id, "mine"}]} = ApiKeys.list_key_options(viewer_subject)
    end

    test "a runner subject without view_api_keys permission is refused" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = ApiKeys.list_key_options(subject)
    end
  end

  describe "list_audit_export_keys_for_account/2" do
    test "audit-export tokens land on the audit list, never the agents list" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, agent_key} =
        ApiKeys.create_key(%{name: "agent"}, subject)

      {:ok, _raw, export_key} =
        ApiKeys.create_key(%{name: "siem", kind: :audit_export}, subject)

      # The split is the explicit `kind`, no longer inferred from scope.
      assert agent_key.kind == :mcp
      assert export_key.kind == :audit_export

      assert {:ok, [agents_visible], _} = ApiKeys.list_api_keys_for_account(subject)
      assert agents_visible.id == agent_key.id

      assert {:ok, [export_visible], _} = ApiKeys.list_audit_export_keys_for_account(subject)
      assert export_visible.id == export_key.id
    end

    test "a runner subject (no view_api_keys permission) is refused with :unauthorized" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      assert {:error, :unauthorized} = ApiKeys.list_audit_export_keys_for_account(subject)
    end

    test "an owner of account B never sees account A's export tokens (cross-account isolation)" do
      {_user_a, _account_a, subject_a} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "a-siem", kind: :audit_export}, subject_a)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:ok, [], _} = ApiKeys.list_audit_export_keys_for_account(subject_b)
    end
  end

  describe "list filters" do
    test "status filter separates live from revoked keys" do
      {_u, _a, subject} = owner_subject_pair()

      {:ok, _raw, _live} =
        ApiKeys.create_key(%{name: "live-one"}, subject)

      {:ok, _raw, revoked} =
        ApiKeys.create_key(%{name: "dead-one"}, subject)

      {:ok, _} = ApiKeys.revoke_api_key(revoked, subject)

      {:ok, live_only, _} =
        ApiKeys.list_api_keys_for_account(subject, filter: [status: ["live"]])

      assert Enum.map(live_only, & &1.name) == ["live-one"]

      {:ok, revoked_only, _} =
        ApiKeys.list_api_keys_for_account(subject, filter: [status: ["revoked"]])

      assert Enum.map(revoked_only, & &1.name) == ["dead-one"]
    end

    test "name filter searches by case-insensitive substring" do
      {_u, _a, subject} = owner_subject_pair()

      {:ok, _raw, _} =
        ApiKeys.create_key(%{name: "Claude Desktop"}, subject)

      {:ok, _raw, _} = ApiKeys.create_key(%{name: "Cursor"}, subject)

      {:ok, matched, _} = ApiKeys.list_api_keys_for_account(subject, filter: [name: "claude"])
      assert Enum.map(matched, & &1.name) == ["Claude Desktop"]
    end
  end

  describe "fetch_api_key_by_id/3" do
    test "returns the key inside the subject's account" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert {:ok, fetched} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert fetched.id == key.id
    end

    test "rejects a subject without view_api_keys permission" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert ApiKeys.fetch_api_key_by_id(key.id, subject) == {:error, :unauthorized}
    end

    test "an owner of account B cannot fetch account A's key (cross-account → :not_found)" do
      account_a = Fixtures.Accounts.create_account()
      {_raw, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account_a.id)

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
                   name: "ci"
                 },
                 subject
               )

      assert String.starts_with?(raw, "emk-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert is_binary(key.key_prefix)
    end

    test "MCP keys default to a 30-day expiry when none is given (a leak self-heals)" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{expires_at: exp} = key} =
               ApiKeys.create_key(%{name: "mcp"}, subject)

      assert exp
      assert ApiKey.usable?(key)

      expected = DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      assert_in_delta DateTime.to_unix(exp), DateTime.to_unix(expected), 120
    end

    test "an explicit expiry is honoured, never overridden by the default" do
      {_user, _account, subject} = owner_subject_pair()
      explicit = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, _raw, %ApiKey{expires_at: exp}} =
               ApiKeys.create_key(%{name: "short", expires_at: explicit}, subject)

      assert DateTime.to_unix(exp) == DateTime.to_unix(explicit)
    end

    test "audit-export tokens never get a default expiry — it would break log shipping" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{expires_at: nil}} =
               ApiKeys.create_key(%{name: "SIEM", kind: :audit_export}, subject)
    end

    test "an operator (no manage_api_keys permission) is refused with :unauthorized" do
      # A custom key mints an execute-capable MCP credential, so it gates
      # on `manage_api_keys` — which operators lack (they may only mint
      # the pre-scoped quick key via `mint_quick_key/1`).
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               ApiKeys.create_key(%{name: "ci"}, subject)
    end

    test "a stale subject cannot create a key after the account is disabled" do
      {_user, account, subject} = owner_subject_pair()

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :not_found} = ApiKeys.create_key(%{name: "late"}, subject)
    end

    # Minting a SIEM export token writes an `api_key.created` audit row in the
    # SAME transaction (create_key's Multi.insert(:audit, …)), stamped with the
    # new key as target + its kind in the payload. The mint of a log-shipping
    # credential is itself part of the log it ships.
    test "minting an audit-export token writes an api_key.created audit row" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, key} =
               ApiKeys.create_key(%{name: "SIEM export", kind: :audit_export}, subject)

      {:ok, events, _meta} =
        Audit.list_events(subject, filter: [event_type: ["api_key.created"]])

      assert [event] = Enum.filter(events, &(&1.target_id == key.id))
      assert event.target_kind == "api_key"
      assert event.target_label == "SIEM export"
      # Persisted payload is string-keyed (reloaded through JSON); the key kind
      # is recorded so an auditor sees what kind of credential was minted.
      assert event.payload["kind"] == "audit_export"
    end
  end

  describe "rotate_api_key/2" do
    test "mints a successor inheriting name + kind; the old key stays usable (overlap)" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, original} = ApiKeys.create_key(%{name: "claude"}, subject)

      assert {:ok, new_raw, successor} = ApiKeys.rotate_api_key(original, subject)

      assert String.starts_with?(new_raw, "emk-")
      assert successor.id != original.id
      # Identity + kind carried forward, plus the rotation back-link.
      assert successor.name == original.name
      assert successor.kind == original.kind
      assert successor.replaces_id == original.id
      assert successor.credential_lineage_id == original.credential_lineage_id

      # The old key isn't revoked — it overlaps until the successor's first
      # use (or a manual revoke).
      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(original.id, subject)
      assert is_nil(reloaded.revoked_at)
      assert ApiKey.usable?(reloaded)
    end

    test "an operator without manage_api_keys is refused with :unauthorized" do
      {_owner, account, owner_subject} = owner_subject_pair()

      {:ok, _raw, key} =
        ApiKeys.create_key(%{name: "k"}, owner_subject)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = ApiKeys.rotate_api_key(key, operator_subject)
    end

    test "a revoked key cannot mint a late successor" do
      {_owner, _account, subject} = owner_subject_pair()
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "revoked"}, subject)

      assert {:ok, %ApiKey{}} = ApiKeys.revoke_api_key(key, subject)
      assert {:error, :revoked} = ApiKeys.rotate_api_key(key, subject)
    end

    test "a stale subject cannot rotate a key after the account is disabled" do
      {_owner, account, subject} = owner_subject_pair()
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "paused"}, subject)

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :not_found} = ApiKeys.rotate_api_key(key, subject)
    end

    test "an owner of account B cannot rotate account A's key (cross-account → :not_found)" do
      {_owner_a, _account_a, subject_a} = owner_subject_pair()

      {:ok, _raw, key_a} =
        ApiKeys.create_key(%{name: "a"}, subject_a)

      {_owner_b, _account_b, subject_b} = owner_subject_pair()

      assert {:error, :not_found} = ApiKeys.rotate_api_key(key_a, subject_b)
    end
  end

  describe "install_auto_rotation_successor/3" do
    test "installs the exact client proposal once and acknowledges an idempotent retry" do
      {_user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)

      {:ok, _raw, key} =
        ApiKeys.create_key(%{name: "claude", expires_at: soon}, subject)

      key_subject = Subject.for_api_key(key, account)
      {successor_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert {:ok, successor} =
               ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)

      assert successor.name == key.name
      assert successor.kind == :mcp
      assert successor.created_by_id == key.created_by_id
      assert successor.created_by_membership_id == key.created_by_membership_id
      assert successor.replaces_id == key.id
      assert successor.credential_lineage_id == key.credential_lineage_id
      assert successor.key_prefix == prefix
      assert Crypto.secure_compare(successor.key_hash, hash)
      assert DateTime.compare(successor.expires_at, soon) == :gt

      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(key.id, subject)
      assert reloaded.rotated_to_id == successor.id
      assert is_nil(reloaded.revoked_at)

      assert {:ok, retried} =
               ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)

      assert retried.id == successor.id
      assert length(Repo.all(ApiKey)) == 2

      rotations = Enum.filter(Repo.all(Audit.Event), &(&1.event_type == "api_key.auto_rotated"))
      assert [rotation] = rotations

      assert rotation.target_id == key.id
      assert rotation.payload["successor_prefix"] == successor.key_prefix

      assert %ApiKey{id: successor_id} = ApiKeys.peek_api_key_by_secret(successor_raw)
      assert successor_id == successor.id
    end

    test "a stale key subject cannot install a successor after the account is disabled" do
      {_user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "paused", expires_at: soon}, subject)
      key_subject = Subject.for_api_key(key, account)
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :not_found} =
               ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)
    end

    test "a different proposal cannot replace an already-installed successor" do
      {_user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "claude", expires_at: soon}, subject)
      key_subject = Subject.for_api_key(key, account)
      {_raw_one, prefix_one, hash_one} = Crypto.mint("emk-", 12)
      {_raw_two, prefix_two, hash_two} = Crypto.mint("emk-", 12)

      assert {:ok, _successor} =
               ApiKeys.install_auto_rotation_successor(prefix_one, hash_one, key_subject)

      assert {:error, :already_rotated} =
               ApiKeys.install_auto_rotation_successor(prefix_two, hash_two, key_subject)
    end

    test "concurrent retries converge on one installed successor" do
      {_user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "claude", expires_at: soon}, subject)
      key_subject = Subject.for_api_key(key, account)
      {_successor_raw, prefix, hash} = Crypto.mint("emk-", 12)

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, %ApiKey{}}, &1))

      assert results
             |> Enum.map(fn {:ok, successor} -> successor.id end)
             |> Enum.uniq()
             |> length() == 1

      assert length(Repo.all(ApiKey)) == 2
    end

    test "a quick key and a far-from-expiry key are not eligible" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)

      {:ok, _raw, quick} = ApiKeys.mint_quick_key(subject)

      far = DateTime.add(DateTime.utc_now(), 30, :day)

      {:ok, _raw, far_key} =
        ApiKeys.create_key(%{name: "far", expires_at: far}, subject)

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(quick, account)
               )

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(far_key, account)
               )
    end

    test "a revoked or expired key and an audit-export token are not eligible" do
      {_user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)

      {:ok, _raw, key} =
        ApiKeys.create_key(%{name: "r", expires_at: soon}, subject)

      {:ok, revoked} = ApiKeys.revoke_api_key(key, subject)

      expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

      {:ok, _raw, expired} =
        ApiKeys.create_key(%{name: "expired", expires_at: expired_at}, subject)

      {:ok, _raw, export} =
        ApiKeys.create_key(%{name: "siem", kind: :audit_export, expires_at: soon}, subject)

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(revoked, account)
               )

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(expired, account)
               )

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(export, account)
               )
    end

    test "invalid material and a user subject are refused" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)
      soon = DateTime.add(DateTime.utc_now(), 3, :day)
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "expiring", expires_at: soon}, subject)

      assert {:error, :not_eligible} =
               ApiKeys.install_auto_rotation_successor(prefix, hash, subject)

      assert {:error, :invalid_successor} =
               ApiKeys.install_auto_rotation_successor(
                 "emk-short",
                 hash,
                 Subject.for_api_key(key, account)
               )

      assert {:error, :invalid_successor} =
               ApiKeys.install_auto_rotation_successor(
                 <<"emk-", 0xFF, "abcdefg">>,
                 hash,
                 Subject.for_api_key(key, account)
               )
    end

    test "an API key cannot install a successor in another account" do
      {_user_a, _account_a, subject_a} = owner_subject_pair()
      {:ok, _raw, key_a} = ApiKeys.create_key(%{name: "a"}, subject_a)
      {_user_b, account_b, _subject_b} = owner_subject_pair()
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)
      forged_subject = Subject.for_api_key(key_a, account_b)

      assert {:error, :not_found} =
               ApiKeys.install_auto_rotation_successor(prefix, hash, forged_subject)
    end
  end

  describe "subscribe_account_api_keys/1" do
    test "the subscriber receives the account's api-key list broadcasts" do
      {_user, account, subject} = owner_subject_pair()

      assert :ok = ApiKeys.subscribe_account_api_keys(account.id)

      # Minting a key publishes `api_key.created` on the topic just joined.
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "agent"}, subject)

      assert_receive {:list_changed, :api_key, "api_key.created", key_id}, 500
      assert key_id == key.id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {_user_a, account_a, _subject_a} = owner_subject_pair()
      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert :ok = ApiKeys.subscribe_account_api_keys(account_a.id)

      # The mint happens on B's topic — A's subscriber must hear nothing.
      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "b-agent"}, subject_b)

      refute_receive {:list_changed, :api_key, _event, _key_id}
    end
  end

  describe "mint_quick_key/2" do
    test "mints a pre-scoped auto key, hidden until first use" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, raw, %ApiKey{} = key} = ApiKeys.mint_quick_key(subject)
      assert String.starts_with?(raw, "emk-")
      assert %DateTime{} = key.auto_generated_at
      assert key.kind == :mcp

      # Quick keys carry the same 30-day default expiry as custom MCP keys.
      expected = DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      assert_in_delta DateTime.to_unix(key.expires_at), DateTime.to_unix(expected), 120

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

    test "rotated_to_id carries a covering index so the eviction DELETE never seq-scans" do
      # Index existence has no domain-observable behavior (the DELETE above
      # succeeds either way), so §7's catalog-inspection carve-out applies:
      # this is the only assertion that proves the FK's covering index exists.
      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT count(*) FROM pg_indexes WHERE tablename = 'api_keys' AND indexname = 'api_keys_rotated_to_id_index'",
          []
        )

      assert count == 1
    end

    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      # Operators CAN mint the quick key; only viewers are below the
      # `issue_quick` line, so the denial subject must be a viewer.
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = ApiKeys.mint_quick_key(subject)
    end
  end

  describe "revoke_api_key/2" do
    test "marks revoked_at" do
      {user, account, subject} = owner_subject_pair()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert {:ok, %ApiKey{revoked_at: %DateTime{}, revoked_by_id: id}} =
               ApiKeys.revoke_api_key(key, subject)

      assert id == user.id
      assert Repo.reload!(key).revoked_at
    end

    test "revokes every pending rotation descendant without touching unrelated keys" do
      {user, account, subject} = owner_subject_pair()
      soon = DateTime.add(DateTime.utc_now(), 3, :day)

      {:ok, source_raw, source} =
        ApiKeys.create_key(%{name: "source", expires_at: soon}, subject)

      {pending_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert {:ok, pending} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(source, account)
               )

      # The forward link alone still declares the pending successor. A partial
      # back-link must not let that credential escape an explicit revocation.
      pending = pending |> Ecto.Changeset.change(replaces_id: nil) |> Repo.update!()

      assert {:ok, leaf_raw, leaf} = ApiKeys.rotate_api_key(pending, subject)
      assert {:ok, branch_raw, branch} = ApiKeys.rotate_api_key(source, subject)
      assert {:ok, unrelated_raw, unrelated} = ApiKeys.create_key(%{name: "unrelated"}, subject)

      assert {:ok, %ApiKey{id: source_id}} = ApiKeys.revoke_api_key(source, subject)
      assert source_id == source.id

      for key <- [source, pending, leaf, branch] do
        revoked = Repo.reload!(key)
        assert %DateTime{} = revoked.revoked_at
        assert revoked.revoked_by_id == user.id
      end

      for raw <- [source_raw, pending_raw, leaf_raw, branch_raw] do
        refute ApiKeys.peek_api_key_by_secret(raw)
      end

      assert %ApiKey{id: unrelated_id} = ApiKeys.peek_api_key_by_secret(unrelated_raw)
      assert unrelated_id == unrelated.id
      assert is_nil(Repo.reload!(unrelated).revoked_at)

      {:ok, events, _meta} =
        Audit.list_events(subject, filter: [event_type: ["api_key.revoked"]])

      events_by_target = Map.new(events, &{&1.target_id, &1})

      assert Map.keys(events_by_target) |> MapSet.new() ==
               MapSet.new([source.id, pending.id, leaf.id, branch.id])

      refute Map.has_key?(events_by_target[source.id].payload, "cascade_source_id")

      for key <- [pending, leaf, branch] do
        assert events_by_target[key.id].payload["cascade_source_id"] == source.id
      end
    end

    test "an operator (no manage_api_keys permission) is refused with :unauthorized" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = ApiKeys.revoke_api_key(key, subject)
      refute Repo.reload!(key).revoked_at
    end

    test "an owner of account B cannot revoke account A's key (cross-account → :not_found)" do
      account_a = Fixtures.Accounts.create_account()
      {_raw, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account_a.id)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:error, :not_found} = ApiKeys.revoke_api_key(key_a, subject_b)
      refute Repo.reload!(key_a).revoked_at
    end

    # (context half) — revoking an already-revoked key
    # succeeds again rather than erroring: the fetch_and_update re-reads the
    # (still not_deleted) row and re-stamps revoked_at. The affordance is gated
    # in the UI (the Revoke button only renders for non-revoked keys), but a
    # double-fire (race / stale page) is a safe idempotent no-op, never a crash.
    test "revoking an already-revoked key is idempotent (re-revoke succeeds)" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert {:ok, %ApiKey{revoked_at: %DateTime{} = first}} =
               ApiKeys.revoke_api_key(key, subject)

      # Fire again on the now-revoked key — still {:ok, …}, still revoked.
      assert {:ok, %ApiKey{revoked_at: %DateTime{} = second}} =
               ApiKeys.revoke_api_key(Repo.reload!(key), subject)

      assert DateTime.compare(second, first) in [:eq, :gt]
      assert Repo.reload!(key).revoked_at
    end
  end

  describe "revoke_keys_for_membership/1" do
    test "revokes that membership's active keys only, idempotently" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      {_r1, key1} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      {_r2, key2} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      # A key minted by a different member must be left alone.
      other = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: other.id,
          role: "owner"
        )

      {_r3, other_key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: other.id)

      assert {:ok, 2} = ApiKeys.revoke_keys_for_membership(membership.id)

      refute is_nil(Repo.reload!(key1).revoked_at)
      refute is_nil(Repo.reload!(key2).revoked_at)
      assert is_nil(Repo.reload!(other_key).revoked_at)

      # Already-revoked keys aren't re-counted.
      assert {:ok, 0} = ApiKeys.revoke_keys_for_membership(membership.id)
    end
  end

  describe "peek_api_key_by_secret/1" do
    test "returns the key for a valid raw secret + bumps last_used_at" do
      {raw, key} = Fixtures.ApiKeys.create_api_key()
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
      {raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, _} = ApiKeys.revoke_api_key(key, subject)

      refute ApiKeys.peek_api_key_by_secret(raw)
    end

    test "disabling one account rejects its key without affecting another account's key" do
      {_user_a, account_a, subject_a} = owner_subject_pair()
      {_user_b, account_b, _subject_b} = owner_subject_pair()
      {raw_a, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account_a.id)
      {raw_b, key_b} = Fixtures.ApiKeys.create_api_key(account_id: account_b.id)

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account_a.id,
                 true,
                 "Temporary hold",
                 subject_a
               )

      refute ApiKeys.peek_api_key_by_secret(raw_a)
      assert is_nil(Repo.reload!(key_a).last_used_at)
      assert %ApiKey{id: id} = ApiKeys.peek_api_key_by_secret(raw_b)
      assert id == key_b.id
    end

    test "returns nil for an expired key" do
      yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      {raw, _key} = Fixtures.ApiKeys.create_api_key(expires_at: yesterday)

      refute ApiKeys.peek_api_key_by_secret(raw)
    end

    test "returns nil for a membership-unbound key without recording usage" do
      {raw, key} = Fixtures.ApiKeys.create_api_key()
      key = Fixtures.ApiKeys.force_membership_unbound(key)

      refute ApiKeys.peek_api_key_by_secret(raw)
      refute Repo.reload!(key).last_used_at
    end

    test "resolves a reissued live key when a soft-deleted key shares its prefix" do
      {raw, stale} = Fixtures.ApiKeys.create_api_key()

      stale
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      duplicate =
        Emisar.ApiKeys.ApiKey.Changeset.create(
          stale.account_id,
          stale.created_by_id,
          stale.created_by_membership_id,
          stale.key_prefix,
          stale.key_hash,
          %{name: "reissued"}
        )
        |> Repo.insert!()

      assert %ApiKey{id: id} = ApiKeys.peek_api_key_by_secret(raw)
      assert id == duplicate.id
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

      assert event.target_id == bound.id
    end

    test "the first call broadcasts api_key.first_used once; later calls don't" do
      {_user, account, subject} = owner_subject_pair()
      {:ok, raw, key} = ApiKeys.create_key(%{name: "agent"}, subject)
      ApiKeys.subscribe_account_api_keys(account.id)

      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(raw)
      assert_receive {:list_changed, :api_key, "api_key.first_used", id}, 500
      assert id == key.id

      # A later call bumps last_used_at but is no longer a first call — no storm.
      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(raw)
      refute_receive {:list_changed, :api_key, "api_key.first_used", _}
    end

    test "first use of a rotation successor retires the replaced key and audits it" do
      {_user, account, subject} = owner_subject_pair()
      {_old_raw, original} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, new_raw, successor} = ApiKeys.rotate_api_key(original, subject)

      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(new_raw)

      {:ok, retired} = ApiKeys.fetch_api_key_by_id(original.id, subject)
      assert %DateTime{} = retired.revoked_at
      refute ApiKey.usable?(retired)

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject,
          filter: [event_type: ["api_key.retired_by_rotation"]]
        )

      assert event.target_id == original.id
      assert event.actor_kind == "api_key"
      assert event.actor_id == successor.id
      assert event.payload["successor_id"] == successor.id
    end

    test "later uses of the successor never re-run the retirement sweep" do
      {_user, account, subject} = owner_subject_pair()
      {_old_raw, original} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, new_raw, _successor} = ApiKeys.rotate_api_key(original, subject)

      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(new_raw)
      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(new_raw)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject,
          filter: [event_type: ["api_key.retired_by_rotation"]]
        )

      assert length(events) == 1
    end

    test "a hand-revoked replaced key denies its successor without a retirement audit" do
      {_user, account, subject} = owner_subject_pair()
      {_old_raw, original} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, new_raw, _successor} = ApiKeys.rotate_api_key(original, subject)
      {:ok, _revoked} = ApiKeys.revoke_api_key(original, subject)

      refute ApiKeys.peek_api_key_by_secret(new_raw)

      {:ok, events, _} =
        Emisar.Audit.list_events(subject,
          filter: [event_type: ["api_key.retired_by_rotation"]]
        )

      assert events == []
    end

    test "first use retires the whole abandoned chain, walking through dead middles" do
      # Rotate twice without ever using the middle key (the lost-secret case):
      # the last successor's first use retires BOTH ancestors.
      {_user, account, subject} = owner_subject_pair()
      {_raw, original} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      {:ok, _middle_raw, middle} = ApiKeys.rotate_api_key(original, subject)
      {:ok, last_raw, _last} = ApiKeys.rotate_api_key(middle, subject)

      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(last_raw)

      {:ok, retired_middle} = ApiKeys.fetch_api_key_by_id(middle.id, subject)
      {:ok, retired_original} = ApiKeys.fetch_api_key_by_id(original.id, subject)
      assert %DateTime{} = retired_middle.revoked_at
      assert %DateTime{} = retired_original.revoked_at

      {:ok, events, _} =
        Emisar.Audit.list_events(subject,
          filter: [event_type: ["api_key.retired_by_rotation"]]
        )

      assert Enum.map(events, & &1.target_id) |> Enum.sort() ==
               Enum.sort([middle.id, original.id])
    end

    test "the retirement sweep never crosses accounts, even on a forged link" do
      {_user_a, account_a, subject_a} = owner_subject_pair()
      {_user_b, account_b, subject_b} = owner_subject_pair()
      {_raw_b, key_b} = Fixtures.ApiKeys.create_api_key(account_id: account_b.id)

      {raw_a, key_a} = Fixtures.ApiKeys.create_api_key(account_id: account_a.id)
      Fixtures.ApiKeys.force_replaces(key_a, key_b.id)

      # The forged successor still authenticates; the foreign key is untouched.
      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(raw_a)

      {:ok, untouched} = ApiKeys.fetch_api_key_by_id(key_b.id, subject_b)
      assert is_nil(untouched.revoked_at)

      {:ok, events_a, _} =
        Emisar.Audit.list_events(subject_a,
          filter: [event_type: ["api_key.retired_by_rotation"]]
        )

      assert events_a == []
    end
  end

  describe "create_backing_key/4" do
    test "inserts a non-expiring MCP key scoped read+execute, owned by the membership" do
      {user, account, _subject} = owner_subject_pair()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      assert {:ok, %ApiKey{} = key} =
               ApiKeys.create_backing_key(account.id, user.id, membership.id, "OAuth: Claude")

      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert key.created_by_membership_id == membership.id
      assert key.name == "OAuth: Claude"
      assert key.kind == :mcp
      # OAuth governs the lifecycle, so the backing key opts out of the 30-day
      # default expiry — it must not self-expire mid-refresh.
      assert is_nil(key.expires_at)
      assert ApiKey.usable?(key)
    end

    test "the backing key resolves via the bearer auth boundary" do
      # create_backing_key DISCARDS the raw secret (the OAuth client never sees
      # it), so the resolution path under test is peek_api_key_by_id — the same
      # one the MCP auth plug uses for an OAuth access token.
      {user, account, _subject} = owner_subject_pair()
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      {:ok, key} =
        ApiKeys.create_backing_key(account.id, user.id, membership.id, "OAuth: Cursor")

      assert %ApiKey{id: id} = ApiKeys.peek_api_key_by_id(key.id)
      assert id == key.id
    end
  end

  describe "peek_api_key_by_id/1" do
    test "returns a usable key, nil for revoked or unknown" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert %ApiKey{id: id} = ApiKeys.peek_api_key_by_id(key.id)
      assert id == key.id

      {:ok, _} = ApiKeys.revoke_api_key(key, subject)
      refute ApiKeys.peek_api_key_by_id(key.id)
      refute ApiKeys.peek_api_key_by_id(Ecto.UUID.generate())
    end

    test "returns nil for a membership-unbound OAuth backing key" do
      {_raw, key} = Fixtures.ApiKeys.create_api_key()
      key = Fixtures.ApiKeys.force_membership_unbound(key)

      refute ApiKeys.peek_api_key_by_id(key.id)
    end
  end

  describe "api_key_usable_in_account?/3" do
    test "locks and accepts only a live key in its own account" do
      {_user, account, subject} = owner_subject_pair()
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "delayed run"}, subject)

      assert ApiKeys.api_key_usable_in_account?(Repo, key.id, account.id)
      refute ApiKeys.api_key_usable_in_account?(Repo, key.id, Ecto.UUID.generate())

      assert {:ok, _revoked} = ApiKeys.revoke_api_key(key, subject)
      refute ApiKeys.api_key_usable_in_account?(Repo, key.id, account.id)
    end
  end

  describe "record_client_info/2" do
    setup do
      {_raw, key} = Fixtures.ApiKeys.create_api_key()
      %{key: key}
    end

    test "persists the sanitized clientInfo map", %{key: key} do
      assert {:ok, updated} =
               ApiKeys.record_client_info(key, %{"name" => "Claude Code", "version" => "1.0"})

      assert updated.last_client_info == %{"name" => "Claude Code", "version" => "1.0"}
    end

    test "rejects a non-map payload", %{key: key} do
      assert {:error, :invalid} = ApiKeys.record_client_info(key, "junk")
    end
  end

  describe "fetch_owner_user_id/1" do
    test "returns the user id that minted the key" do
      {user, account, _subject} = owner_subject_pair()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      assert ApiKeys.fetch_owner_user_id(key.id) == user.id
    end

    test "returns nil for an unknown id and for a non-binary arg" do
      assert is_nil(ApiKeys.fetch_owner_user_id(Ecto.UUID.generate()))
      assert is_nil(ApiKeys.fetch_owner_user_id(nil))
    end
  end

  describe "no_agents?/1" do
    test "is true when the account has no live MCP key, false once one exists" do
      {_user, account, subject} = owner_subject_pair()

      # No keys yet → nudge the operator to connect an agent.
      assert ApiKeys.no_agents?(subject)

      {_raw, _key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      refute ApiKeys.no_agents?(subject)
    end

    test "ignores audit-export and unused auto-generated keys until an MCP client connects" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, _export_key} =
        ApiKeys.create_key(%{name: "SIEM", kind: :audit_export}, subject)

      assert ApiKeys.no_agents?(subject)

      {:ok, quick_raw, _quick_key} = ApiKeys.mint_quick_key(subject)
      assert ApiKeys.no_agents?(subject)

      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(quick_raw)
      refute ApiKeys.no_agents?(subject)
    end

    test "a fully-revoked account reads as no agents again (the nudge returns)" do
      {_user, account, subject} = owner_subject_pair()
      {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      refute ApiKeys.no_agents?(subject)

      {:ok, _} = ApiKeys.revoke_api_key(key, subject)
      assert ApiKeys.no_agents?(subject)
    end

    test "is account-scoped — another account's key doesn't clear this account's nudge" do
      {_user_a, _account_a, subject_a} = owner_subject_pair()
      account_b = Fixtures.Accounts.create_account()
      {_raw, _key_b} = Fixtures.ApiKeys.create_api_key(account_id: account_b.id)

      # B has a key, but A still has none → A's nudge stays on.
      assert ApiKeys.no_agents?(subject_a)
    end

    test "returns false (no nudge) for a subject that can't view keys" do
      # The runner (websocket) subject holds no view_api_keys permission, so the
      # nudge is suppressed (false) rather than leaking an existence signal —
      # even though this account genuinely has no agents.
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Subject.for_runner(runner, account)

      refute ApiKeys.no_agents?(subject)
    end
  end

  describe "device_grant_ttl_s/0" do
    test "reports the grant lifetime the API layer advertises as expires_in" do
      assert ApiKeys.device_grant_ttl_s() == 15 * 60
    end
  end

  describe "open_device_grant/2" do
    test "opens a pending, account-less grant and returns the raw codes exactly once" do
      context = %RequestContext{ip_address: "203.0.113.9"}

      assert {:ok, device_code, user_code, grant} =
               ApiKeys.open_device_grant(["claude-code", "cursor"], context)

      assert String.starts_with?(device_code, "emdg-")
      assert user_code =~ ~r/^[2-9ABCDEFGHJKMNPQRSTVWXYZ]{4}-[2-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$/
      assert grant.status == :pending
      assert grant.requested_clients == ["claude-code", "cursor"]
      assert grant.requester_ip == "203.0.113.9"
      assert is_nil(grant.account_id)

      # Only digests persist — the row can never reproduce the codes.
      assert grant.device_code_digest == Crypto.mcp_device_code_digest(device_code)
      assert grant.user_code_digest == Crypto.mcp_device_user_code_digest(user_code)
      assert DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt
    end

    test "rejects unknown clients and an empty client list" do
      assert {:error, changeset} = ApiKeys.open_device_grant(["netscape"], %RequestContext{})
      assert "has an invalid entry" in errors_on(changeset).requested_clients

      assert {:error, changeset} = ApiKeys.open_device_grant([], %RequestContext{})
      assert "can't be blank" in errors_on(changeset).requested_clients
    end

    test "duplicate client entries collapse to one" do
      assert {:ok, _device_code, _user_code, grant} =
               ApiKeys.open_device_grant(["codex", "codex"], %RequestContext{})

      assert grant.requested_clients == ["codex"]
    end
  end

  describe "fetch_pending_device_grant_by_user_code/2" do
    test "finds the pending grant, normalizing case and separators" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      typed = user_code |> String.replace("-", " ") |> String.downcase()
      grant_id = grant.id

      assert {:ok, %DeviceGrant{id: ^grant_id}} =
               ApiKeys.fetch_pending_device_grant_by_user_code(typed, subject)
    end

    test "an expired or unknown code is :not_found" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      Fixtures.ApiKeys.backdate_device_grant_expiry(grant)

      assert ApiKeys.fetch_pending_device_grant_by_user_code(user_code, subject) ==
               {:error, :not_found}

      assert ApiKeys.fetch_pending_device_grant_by_user_code("XXXX-XXXX", subject) ==
               {:error, :not_found}
    end

    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert ApiKeys.fetch_pending_device_grant_by_user_code("XXXX-XXXX", subject) ==
               {:error, :unauthorized}
    end
  end

  describe "approve_device_grant/2" do
    test "binds the approver's account + identity and writes the audit event" do
      {user, account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      assert {:ok, approved} = ApiKeys.approve_device_grant(user_code, subject)
      assert approved.status == :approved
      assert approved.account_id == account.id
      assert approved.approved_by_id == user.id
      assert approved.approved_by_membership_id == subject.membership_id

      {:ok, events, _meta} =
        Audit.list_events(subject, filter: [event_type: ["api_key.device_grant_approved"]])

      assert [event] = events
      assert event.target_kind == "device_grant"
      assert event.target_id == approved.id
      assert event.target_label == "Claude Code"
      assert event.payload["requested_clients"] == ["claude-code"]
    end

    test "a grant approves exactly once — a second approve (or after deny) is :not_found" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      assert {:ok, _approved} = ApiKeys.approve_device_grant(user_code, subject)
      assert ApiKeys.approve_device_grant(user_code, subject) == {:error, :not_found}
    end

    test "an expired grant cannot be approved" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      Fixtures.ApiKeys.backdate_device_grant_expiry(grant)

      assert ApiKeys.approve_device_grant(user_code, subject) == {:error, :not_found}
    end

    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert ApiKeys.approve_device_grant("XXXX-XXXX", subject) == {:error, :unauthorized}
    end
  end

  describe "deny_device_grant/2" do
    test "records the denier and writes the audit event" do
      {user, account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["cursor"], %RequestContext{})

      assert {:ok, denied} = ApiKeys.deny_device_grant(user_code, subject)
      assert denied.status == :denied
      assert denied.account_id == account.id
      assert denied.approved_by_id == user.id

      {:ok, events, _meta} =
        Audit.list_events(subject, filter: [event_type: ["api_key.device_grant_denied"]])

      assert [event] = events
      assert event.target_id == denied.id
      assert event.target_label == "Cursor"
    end

    test "a denied grant cannot then be approved" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["cursor"], %RequestContext{})

      assert {:ok, _denied} = ApiKeys.deny_device_grant(user_code, subject)
      assert ApiKeys.approve_device_grant(user_code, subject) == {:error, :not_found}
    end

    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert ApiKeys.deny_device_grant("XXXX-XXXX", subject) == {:error, :unauthorized}
    end
  end

  describe "claim_device_grant/1" do
    test "an approved grant mints one auto key per client in the approver's account — once" do
      {_user, account, subject} = owner_subject_pair()
      # A second tenant proves account scoping: nothing may land there.
      other_account = Fixtures.Accounts.create_account()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code", "cursor"], %RequestContext{})

      {:ok, _approved} = ApiKeys.approve_device_grant(user_code, subject)

      assert {:ok, client_keys} = ApiKeys.claim_device_grant(device_code)
      assert client_keys |> Map.keys() |> Enum.sort() == ["claude-code", "cursor"]

      keys = Repo.all(ApiKey)
      assert length(keys) == 2
      assert Enum.all?(keys, &(&1.account_id == account.id))
      refute Enum.any?(keys, &(&1.account_id == other_account.id))
      assert Enum.all?(keys, &ApiKey.auto_unused?/1)
      assert keys |> Enum.map(& &1.name) |> Enum.sort() == ["Claude Code", "Cursor"]

      # The delivered secrets authenticate (first use promotes the key).
      assert %ApiKey{} = ApiKeys.peek_api_key_by_secret(client_keys["claude-code"])

      # Delivery is single-shot — a second poll never re-issues secrets.
      assert ApiKeys.claim_device_grant(device_code) == {:error, :invalid_grant}
    end

    test "a pending grant polls as :authorization_pending; unknown codes as :invalid_grant" do
      {:ok, device_code, _user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      assert ApiKeys.claim_device_grant(device_code) == {:error, :authorization_pending}
      assert ApiKeys.claim_device_grant("emdg-unknown") == {:error, :invalid_grant}
    end

    test "a denied grant polls as :access_denied" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, _denied} = ApiKeys.deny_device_grant(user_code, subject)

      assert ApiKeys.claim_device_grant(device_code) == {:error, :access_denied}
    end

    test "an expired grant polls as :expired_token — even after approval" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, approved} = ApiKeys.approve_device_grant(user_code, subject)
      Fixtures.ApiKeys.backdate_device_grant_expiry(approved)

      assert ApiKeys.claim_device_grant(device_code) == {:error, :expired_token}
      # No keys minted for the dead grant.
      assert Repo.all(ApiKey) == []
    end

    test "a removed approver membership kills the claim" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(membership)

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, _approved} = ApiKeys.approve_device_grant(user_code, subject)
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      assert ApiKeys.claim_device_grant(device_code) == {:error, :access_denied}
      assert Repo.all(ApiKey) == []
    end

    test "a disabled account cannot claim, and re-enable preserves the approved grant" do
      {_user, account, subject} = owner_subject_pair()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      assert {:ok, _approved} = ApiKeys.approve_device_grant(user_code, subject)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert ApiKeys.claim_device_grant(device_code) == {:error, :access_denied}
      assert Repo.all(ApiKey) == []

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 false,
                 "Hold resolved",
                 subject
               )

      assert {:ok, %{"claude-code" => _raw_key}} = ApiKeys.claim_device_grant(device_code)
    end
  end

  describe "cleanup_device_grants/1" do
    test "expires overdue pending grants and deletes rows past retention" do
      {:ok, _device_code, _user_code, overdue} =
        ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, _device_code, _user_code, fresh} =
        ApiKeys.open_device_grant(["cursor"], %RequestContext{})

      {:ok, _device_code, _user_code, ancient} =
        ApiKeys.open_device_grant(["codex"], %RequestContext{})

      Fixtures.ApiKeys.backdate_device_grant_expiry(overdue)

      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 24 * 3_600, :second)
      Fixtures.ApiKeys.backdate_device_grant_inserted_at(ancient, two_days_ago)

      assert ApiKeys.cleanup_device_grants() == {1, 1}

      assert Repo.reload(overdue).status == :expired
      assert Repo.reload(fresh).status == :pending
      refute Repo.reload(ancient)
    end

    test "an idle sweep is a no-op" do
      assert ApiKeys.cleanup_device_grants() == {0, 0}
    end
  end

  describe "subject_can_view_api_keys?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert ApiKeys.subject_can_view_api_keys?(viewer_subject)
      refute ApiKeys.subject_can_view_api_keys?(billing_manager_subject)
    end
  end

  describe "subject_can_issue_quick_key?/1" do
    test "operators and above can quick-mint; viewers cannot" do
      account = Fixtures.Accounts.create_account()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert ApiKeys.subject_can_issue_quick_key?(operator)
      refute ApiKeys.subject_can_issue_quick_key?(viewer)
    end
  end

  describe "subject_can_manage_api_keys?/1" do
    test "is true for an owner and an admin (they hold manage_api_keys)" do
      {_owner, account, owner_subject} = owner_subject_pair()
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert ApiKeys.subject_can_manage_api_keys?(owner_subject)
      assert ApiKeys.subject_can_manage_api_keys?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      {_owner, account, _owner_subject} = owner_subject_pair()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute ApiKeys.subject_can_manage_api_keys?(operator_subject)
      refute ApiKeys.subject_can_manage_api_keys?(viewer_subject)
    end
  end
end
