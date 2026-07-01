defmodule Emisar.ApiKeysTest do
  use Emisar.DataCase, async: true
  alias Emisar.{ApiKeys, Audit, Repo}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures

  defp owner_subject_pair do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    _ =
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
        ApiKeys.create_key(%{name: "agent", scopes: ["actions:read"]}, subject)

      {:ok, _raw, _export_key} =
        ApiKeys.create_key(%{name: "siem", scopes: ["audit:read"]}, subject)

      assert {:ok, [visible], _} = ApiKeys.list_api_keys_for_account(subject)
      assert visible.id == agent_key.id
    end

    test ":created_by is preloaded only when asked for via :preload" do
      {user, _account, subject} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "agent", scopes: ["actions:read"]}, subject)

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
        ApiKeys.create_key(%{name: "a-key", scopes: ["actions:read"]}, subject_a)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:ok, [], _} = ApiKeys.list_api_keys_for_account(subject_b)
    end
  end

  describe "list_key_owner_options/1 + the owner filter" do
    test "returns the distinct creators of the account's visible (non-audit) keys" do
      {user, _account, subject} = owner_subject_pair()

      {:ok, _raw, _k1} = ApiKeys.create_key(%{name: "a", scopes: ["actions:read"]}, subject)
      {:ok, _raw, _k2} = ApiKeys.create_key(%{name: "b", scopes: ["actions:read"]}, subject)
      # An audit-export key is on the audit list, not agents — its creator isn't
      # an agents "owner".
      {:ok, _raw, _siem} = ApiKeys.create_key(%{name: "siem", scopes: ["audit:read"]}, subject)

      assert {:ok, [{owner_id, owner_email}]} = ApiKeys.list_key_owner_options(subject)
      assert owner_id == user.id
      assert owner_email == user.email
    end

    test "the owner filter narrows to a creator's keys; another account sees none" do
      {user, _account, subject} = owner_subject_pair()
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "mine", scopes: ["actions:read"]}, subject)

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
  end

  describe "list_audit_export_keys_for_account/2" do
    test "audit-export tokens land on the audit list, never the agents list" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, agent_key} =
        ApiKeys.create_key(%{name: "agent", scopes: ["actions:read"]}, subject)

      {:ok, _raw, export_key} =
        ApiKeys.create_key(%{name: "siem", scopes: ["audit:read"]}, subject)

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
      {:ok, _raw, _key} = ApiKeys.create_key(%{name: "a-siem", scopes: ["audit:read"]}, subject_a)

      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert {:ok, [], _} = ApiKeys.list_audit_export_keys_for_account(subject_b)
    end
  end

  describe "list filters" do
    test "status filter separates live from revoked keys" do
      {_u, _a, subject} = owner_subject_pair()

      {:ok, _raw, _live} =
        ApiKeys.create_key(%{name: "live-one", scopes: ["actions:read"]}, subject)

      {:ok, _raw, revoked} =
        ApiKeys.create_key(%{name: "dead-one", scopes: ["actions:read"]}, subject)

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
        ApiKeys.create_key(%{name: "Claude Desktop", scopes: ["actions:read"]}, subject)

      {:ok, _raw, _} = ApiKeys.create_key(%{name: "Cursor", scopes: ["actions:read"]}, subject)

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

    test "persists action_scope and confines the key via action_allowed?/2" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{} = key} =
               ApiKeys.create_key(
                 %{name: "scoped", scopes: ["actions:execute"], action_scope: ["linux.uptime"]},
                 subject
               )

      assert key.action_scope == ["linux.uptime"]
      assert ApiKey.action_allowed?(key, "linux.uptime")
      refute ApiKey.action_allowed?(key, "linux.reboot")
    end

    test "an empty action_scope allows any action (the default, so existing keys are unaffected)" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{action_scope: []} = key} =
               ApiKeys.create_key(%{name: "open", scopes: ["actions:execute"]}, subject)

      assert ApiKey.action_allowed?(key, "linux.reboot")
    end

    test "runner_allowed?/3 confines a key to its runner_filter + runner_group_filter" do
      # Empty filters → any runner (the default). A pure predicate the domain
      # dispatch path gates on, by the runner's id + group.
      assert ApiKey.runner_allowed?(%ApiKey{runner_filter: [], runner_group_filter: []}, "r", "g")

      by_id = %ApiKey{runner_filter: ["r-1"], runner_group_filter: []}
      assert ApiKey.runner_allowed?(by_id, "r-1", "prod")
      refute ApiKey.runner_allowed?(by_id, "r-2", "prod")

      by_group = %ApiKey{runner_filter: [], runner_group_filter: ["prod"]}
      assert ApiKey.runner_allowed?(by_group, "r-9", "prod")
      refute ApiKey.runner_allowed?(by_group, "r-9", "staging")
    end

    test "rejects a malformed action_scope entry" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:error, cs} =
               ApiKeys.create_key(
                 %{name: "bad", scopes: ["actions:execute"], action_scope: ["not a valid id"]},
                 subject
               )

      assert ~s(must be a list of action ids like "pack.action") in errors_on(cs).action_scope
    end

    test "accepts hyphenated pack ids (cloud-init.*, aws-ec2.*) in action_scope" do
      {_user, _account, subject} = owner_subject_pair()

      # The pack segment carries a hyphen for several real packs; the scope
      # validation must not reject them.
      assert {:ok, _raw, %ApiKey{} = key} =
               ApiKeys.create_key(
                 %{
                   name: "hyphenated",
                   scopes: ["actions:execute"],
                   action_scope: ["cloud-init.analyze_show", "aws-ec2.describe_instances"]
                 },
                 subject
               )

      assert ApiKey.action_allowed?(key, "cloud-init.analyze_show")
      refute ApiKey.action_allowed?(key, "cloud-init.clean_logs")
    end

    test "MCP keys default to a 30-day expiry when none is given (a leak self-heals)" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{expires_at: exp} = key} =
               ApiKeys.create_key(%{name: "mcp", scopes: ["actions:execute"]}, subject)

      assert exp
      assert ApiKey.usable?(key)

      expected = DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      assert_in_delta DateTime.to_unix(exp), DateTime.to_unix(expected), 120
    end

    test "an explicit expiry is honoured, never overridden by the default" do
      {_user, _account, subject} = owner_subject_pair()
      explicit = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, _raw, %ApiKey{expires_at: exp}} =
               ApiKeys.create_key(
                 %{name: "short", scopes: ["actions:execute"], expires_at: explicit},
                 subject
               )

      assert DateTime.to_unix(exp) == DateTime.to_unix(explicit)
    end

    test "audit-export tokens (audit:read) never get a default expiry — it would break log shipping" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, %ApiKey{expires_at: nil}} =
               ApiKeys.create_key(%{name: "SIEM", scopes: ["audit:read"]}, subject)
    end

    test "rejects an explicit audit_export kind that lacks the audit:read scope" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:error, cs} =
               ApiKeys.create_key(
                 %{name: "mismatch", kind: :audit_export, scopes: ["actions:execute"]},
                 subject
               )

      assert errors_on(cs).scopes != []
    end

    test "an operator (no manage_api_keys permission) is refused with :unauthorized" do
      # A custom key mints an execute-capable MCP credential, so it gates
      # on `manage_api_keys` — which operators lack (they may only mint
      # the pre-scoped quick key via `mint_quick_key/1`).
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               ApiKeys.create_key(%{name: "ci", scopes: ["actions:read"]}, subject)
    end

    # (audit half), (audit half) — minting a SIEM
    # export token (the audit:read bucket) writes an `api_key.created` audit row
    # in the SAME transaction (create_key's Multi.insert(:audit, …)), stamped with
    # the new key as subject + its scopes in the payload. The mint of a
    # log-shipping credential is itself part of the log it ships.
    test "minting an audit:read export token writes an api_key.created audit row" do
      {_user, _account, subject} = owner_subject_pair()

      assert {:ok, _raw, key} =
               ApiKeys.create_key(%{name: "SIEM export", scopes: ["audit:read"]}, subject)

      {:ok, events, _meta} =
        Audit.list_events(subject, filter: [event_type: ["api_key.created"]])

      assert [event] = Enum.filter(events, &(&1.subject_id == key.id))
      assert event.subject_kind == "api_key"
      assert event.subject_label == "SIEM export"
      # Persisted payload is string-keyed (reloaded through JSON); the minted
      # scopes are recorded so an auditor sees exactly what the token can do.
      assert event.payload["scopes"] == ["audit:read"]
    end
  end

  describe "rotate_api_key/2" do
    test "mints a successor inheriting scope; the old key stays usable (overlap)" do
      {_user, _account, subject} = owner_subject_pair()

      {:ok, _raw, original} =
        ApiKeys.create_key(
          %{
            name: "claude",
            scopes: ["actions:read", "actions:execute"],
            action_scope: ["linux.uptime"]
          },
          subject
        )

      assert {:ok, new_raw, successor} = ApiKeys.rotate_api_key(original, subject)

      assert String.starts_with?(new_raw, "emk-")
      assert successor.id != original.id
      # Scope carried forward verbatim.
      assert successor.name == original.name
      assert successor.kind == original.kind
      assert Enum.sort(successor.scopes) == Enum.sort(original.scopes)
      assert successor.action_scope == original.action_scope

      # The old key isn't revoked — it overlaps until the operator revokes it.
      {:ok, reloaded} = ApiKeys.fetch_api_key_by_id(original.id, subject)
      assert is_nil(reloaded.revoked_at)
      assert ApiKey.usable?(reloaded)
    end

    test "an operator without manage_api_keys is refused with :unauthorized" do
      {_owner, account, owner_subject} = owner_subject_pair()

      {:ok, _raw, key} =
        ApiKeys.create_key(%{name: "k", scopes: ["actions:execute"]}, owner_subject)

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

    test "an owner of account B cannot rotate account A's key (cross-account → :not_found)" do
      {_owner_a, _account_a, subject_a} = owner_subject_pair()

      {:ok, _raw, key_a} =
        ApiKeys.create_key(%{name: "a", scopes: ["actions:execute"]}, subject_a)

      {_owner_b, _account_b, subject_b} = owner_subject_pair()

      assert {:error, :not_found} = ApiKeys.rotate_api_key(key_a, subject_b)
    end
  end

  describe "subscribe_account_api_keys/1" do
    test "the subscriber receives the account's api-key list broadcasts" do
      {_user, account, subject} = owner_subject_pair()

      assert :ok = ApiKeys.subscribe_account_api_keys(account.id)

      # Minting a key publishes `api_key.created` on the topic just joined.
      {:ok, _raw, key} = ApiKeys.create_key(%{name: "agent", scopes: ["actions:read"]}, subject)

      assert_receive {:list_changed, :api_key, "api_key.created", key_id}
      assert key_id == key.id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {_user_a, account_a, _subject_a} = owner_subject_pair()
      {_user_b, _account_b, subject_b} = owner_subject_pair()

      assert :ok = ApiKeys.subscribe_account_api_keys(account_a.id)

      # The mint happens on B's topic — A's subscriber must hear nothing.
      {:ok, _raw, _key} =
        ApiKeys.create_key(%{name: "b-agent", scopes: ["actions:read"]}, subject_b)

      refute_receive {:list_changed, :api_key, _event, _key_id}
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

    test "a viewer (no issue_quick_key permission) is refused with :unauthorized" do
      # Operators CAN mint the quick key; only viewers are below the
      # `issue_quick` line, so the denial subject must be a viewer.
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      _ =
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

    test "returns nil for an expired key" do
      yesterday = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      {raw, _key} = Fixtures.ApiKeys.create_api_key(expires_at: yesterday)

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
      assert Enum.sort(key.scopes) == ["actions:execute", "actions:read"]
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
    test "is true when the account has no non-revoked key, false once one exists" do
      {_user, account, subject} = owner_subject_pair()

      # No keys yet → nudge the operator to connect an agent.
      assert ApiKeys.no_agents?(subject)

      {_raw, _key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
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

  describe "subject_can_manage_api_keys?/1" do
    test "is true for an owner and an admin (they hold manage_api_keys)" do
      {_owner, account, owner_subject} = owner_subject_pair()
      admin = Fixtures.Users.create_user()

      _ =
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

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      _ =
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

  describe "ApiKey.has_scope?/2 — the scope gate the MCP + audit-export controllers share" do
    test "true when the scope is in the grant-list" do
      assert ApiKey.has_scope?(%ApiKey{scopes: ["actions:read", "audit:read"]}, "audit:read")
    end

    test "false when the scope is absent" do
      refute ApiKey.has_scope?(%ApiKey{scopes: ["actions:read"]}, "audit:read")
    end

    test "false (not a crash) when scopes is nil" do
      refute ApiKey.has_scope?(%ApiKey{scopes: nil}, "actions:read")
    end
  end
end
