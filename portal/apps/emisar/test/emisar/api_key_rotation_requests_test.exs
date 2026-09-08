defmodule Emisar.ApiKeyRotationRequestsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{ApiKeys, Audit, Crypto, Fixtures, Repo}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Auth.Subject

  describe "request_api_key_rotation/2" do
    test "requested early rotation survives lost acknowledgment and completes on first use" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      {old_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      key = Fixtures.ApiKeys.mark_rotation_supported(key)
      ApiKeys.subscribe_account_api_keys(account.id)

      assert {:ok, requested} = ApiKeys.request_api_key_rotation(key, subject)
      assert requested.expires_at == key.expires_at
      assert_receive {:list_changed, :api_key, "api_key.rotation_requested", _}
      assert {:ok, repeated} = ApiKeys.request_api_key_rotation(key, subject)
      assert repeated.rotation_requested_at == requested.rotation_requested_at
      refute_receive {:list_changed, :api_key, "api_key.rotation_requested", _}

      events =
        Enum.filter(Repo.all(Audit.Event), &(&1.event_type == "api_key.rotation_requested"))

      assert [event] = events
      assert event.actor_id == user.id

      {new_raw, prefix, hash} = Crypto.mint("emk-", 12)
      key_subject = Subject.for_api_key(key, account)
      assert {:ok, successor} = ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)
      assert {:ok, retried} = ApiKeys.install_auto_rotation_successor(prefix, hash, key_subject)
      assert retried.id == successor.id
      assert_receive {:list_changed, :api_key, "api_key.created", _}
      assert Repo.reload!(key).rotation_requested_at == nil
      assert ApiKeys.peek_api_key_by_secret(old_raw).id == key.id
      assert_receive {:list_changed, :api_key, "api_key.first_used", _}
      assert ApiKeys.peek_api_key_by_secret(new_raw).id == successor.id
      assert_receive {:list_changed, :api_key, "api_key.revoked", _}
      assert_receive {:list_changed, :api_key, "api_key.first_used", _}
      assert ApiKeys.peek_api_key_by_secret(old_raw) == nil
    end

    test "losing support keeps a pending request until explicit manual fallback" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      key = Fixtures.ApiKeys.mark_rotation_supported(key)
      assert {:ok, requested} = ApiKeys.request_api_key_rotation(key, subject)

      assert {:ok, _} =
               ApiKeys.record_auto_rotation_support(nil, nil, Subject.for_api_key(key, account))

      assert {:ok, repeated} = ApiKeys.request_api_key_rotation(key, subject)
      assert repeated.rotation_requested_at == requested.rotation_requested_at
      assert Repo.aggregate(ApiKey, :count) == 1

      assert {:ok, _raw, successor} = ApiKeys.rotate_api_key(key, subject)
      loaded = Repo.reload!(key)
      assert loaded.rotation_requested_at == nil
      assert loaded.rotated_to_id == successor.id
      assert ApiKeys.rotate_api_key(key, subject) == {:error, :already_rotated}
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert ApiKeys.install_auto_rotation_successor(
               prefix,
               hash,
               Subject.for_api_key(key, account)
             ) ==
               {:error, :already_rotated}

      assert Repo.aggregate(ApiKey, :count) == 2
    end

    test "automatic installation wins over a later manual fallback without a second successor" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      key = Fixtures.ApiKeys.mark_rotation_supported(key)
      assert {:ok, _} = ApiKeys.request_api_key_rotation(key, subject)
      {_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert {:ok, _} =
               ApiKeys.install_auto_rotation_successor(
                 prefix,
                 hash,
                 Subject.for_api_key(key, account)
               )

      assert ApiKeys.rotate_api_key(key, subject) == {:error, :already_rotated}
      assert ApiKeys.request_api_key_rotation(key, subject) == {:error, :already_rotated}
      assert Repo.aggregate(ApiKey, :count) == 2
    end

    test "unsupported, expired and over-age keys require manual setup" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      assert ApiKeys.request_api_key_rotation(key, subject) == {:error, :manual_required}

      key = Fixtures.ApiKeys.mark_rotation_supported(key)

      key =
        Fixtures.ApiKeys.backdate_api_key_inserted_at(
          key,
          DateTime.add(DateTime.utc_now(), -91, :day)
        )

      assert ApiKeys.request_api_key_rotation(key, subject) == {:error, :manual_required}

      key = Fixtures.ApiKeys.backdate_api_key_expiry(key)
      assert ApiKeys.request_api_key_rotation(key, subject) == {:error, :manual_required}
      assert Repo.reload!(key).rotation_requested_at == nil
    end

    test "viewer, foreign account, and a demoted owner cannot request rotation" do
      {user, account, owner} = Fixtures.Subjects.owner_subject()

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      key = Fixtures.ApiKeys.mark_rotation_supported(key)
      viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert ApiKeys.request_api_key_rotation(key, Fixtures.Subjects.membership_subject(viewer)) ==
               {:error, :unauthorized}

      foreign = Fixtures.Memberships.create_membership(role: "owner")

      assert ApiKeys.request_api_key_rotation(key, Fixtures.Subjects.membership_subject(foreign)) ==
               {:error, :not_found}

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "viewer")
      assert ApiKeys.request_api_key_rotation(key, owner) == {:error, :unauthorized}
      assert Repo.reload!(key).rotation_requested_at == nil
    end
  end

  describe "record_auto_rotation_support/3" do
    test "support is observed from a valid proposal without changing expiry or minting a key" do
      account = Fixtures.Accounts.create_account()
      {raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      subject = Subject.for_api_key(key, account)
      {_next_raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert {:ok, supported} = ApiKeys.record_auto_rotation_support(prefix, hash, subject)
      assert supported.auto_rotation_supported
      assert supported.expires_at == key.expires_at

      assert ApiKeys.install_auto_rotation_successor(prefix, hash, subject) ==
               {:error, :not_eligible}

      assert Repo.aggregate(ApiKey, :count) == 1
      assert ApiKeys.peek_api_key_by_secret(raw).id == key.id

      assert {:ok, unsupported} = ApiKeys.record_auto_rotation_support(nil, nil, subject)
      refute unsupported.auto_rotation_supported
    end
  end
end
