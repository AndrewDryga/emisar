defmodule Emisar.SSOSCIMTest do
  @moduledoc """
  The SCIM 2.0 directory-sync domain (Slice 2a — provision / deprovision):
  the per-provider bearer auth, reconcile-by-`(provider, externalId)`
  provisioning, and deprovision = SUSPEND-the-membership (never delete the
  user), with the last-active-owner lockout guard holding under a SCIM
  deprovision. The token's provider-scope is the authorization — these
  functions take a provider explicitly and carry no `%Subject{}`.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Crypto, Repo, SSO, Users}
  alias Emisar.Fixtures
  alias Emisar.SSO.{IdentityProvider, SCIMUserUpdate, UserIdentity}

  defp enterprise_owner do
    Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
  end

  defp provider_fixture(account, attrs \\ %{}) do
    Fixtures.SSO.create_identity_provider(
      Map.merge(
        %{
          account_id: account.id,
          kind: :okta,
          name: "Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.new(attrs)
      )
    )
  end

  # Enterprise account + provider with directory sync enabled. Returns the
  # provider, the raw bearer (shown once), the owner subject, and the account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_user, account, subject} = enterprise_owner()
    provider = provider_fixture(account, provider_attrs)
    {:ok, provider, raw_token} = SSO.enable_scim(provider, subject)
    %{provider: provider, token: raw_token, subject: subject, account: account}
  end

  defp scim_attrs(attrs) do
    Map.merge(
      %{external_id: "okta|#{System.unique_integer([:positive])}", full_name: "Dir User"},
      Map.new(attrs)
    )
  end

  # A directory user under a known name, so a rename has something to move.
  defp provisioned(provider, external_id, full_name) do
    attrs = scim_attrs(%{external_id: external_id, full_name: full_name})
    {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)
    %{user: user, identity: identity}
  end

  # -- Token auth ------------------------------------------------------

  describe "authenticate_scim_token/1" do
    setup do
      scim_provider()
    end

    test "resolves the right provider by prefix + hash", %{provider: provider, token: token} do
      assert {:ok, resolved} = SSO.authenticate_scim_token(token)
      assert resolved.id == provider.id
      assert resolved.account_id == provider.account_id
    end

    test "a garbage / too-short / wrong token is :unauthorized", %{token: token} do
      assert SSO.authenticate_scim_token("") == {:error, :unauthorized}
      assert SSO.authenticate_scim_token("ems-") == {:error, :unauthorized}
      assert SSO.authenticate_scim_token("ems-totally-wrong-secret") == {:error, :unauthorized}
      # A correct prefix but a tampered tail must still fail the hash compare.
      assert SSO.authenticate_scim_token(token <> "x") == {:error, :unauthorized}
    end

    test "a token whose provider has scim disabled is :unauthorized", %{
      provider: provider,
      token: token,
      subject: subject
    } do
      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert SSO.authenticate_scim_token(token) == {:error, :unauthorized}
    end

    test "a disabled account's retained SCIM token is unauthorized until re-enabled", %{
      account: account,
      token: token,
      subject: subject
    } do
      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert SSO.authenticate_scim_token(token) == {:error, :unauthorized}

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 false,
                 "Hold resolved",
                 subject
               )

      assert {:ok, _provider} = SSO.authenticate_scim_token(token)
    end

    test "token A resolves to provider A only — never account B's provider", %{
      provider: provider_a,
      token: token_a
    } do
      %{provider: provider_b} = scim_provider()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token_a)
      assert resolved.id == provider_a.id
      refute resolved.id == provider_b.id
      assert resolved.account_id != provider_b.account_id
    end

    test "a soft-deleted provider sharing the prefix doesn't crash the lookup", %{
      provider: provider,
      token: token
    } do
      # The partial-unique prefix index only covers live rows, so a soft-deleted
      # provider may carry the same prefix. The lookup must scope to live rows
      # and resolve the live provider — not raise on two prefix matches.
      %{provider: ghost} = scim_provider()

      ghost
      |> Ecto.Changeset.change(
        scim_token_prefix: provider.scim_token_prefix,
        deleted_at: DateTime.utc_now()
      )
      |> Repo.update!()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token)
      assert resolved.id == provider.id
    end
  end

  # -- Provisioning ----------------------------------------------------

  describe "scim_provision_user/2" do
    setup do
      scim_provider()
    end

    test "creates a user_identity (created_by :provider, provisioned_via :scim) + membership at default_role" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|prov-1", email: "prov@acme.test"})

      assert {:ok, %{user: user, identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      assert user.email == "prov@acme.test"
      assert user.full_name == "Dir User"
      assert user.confirmed_at

      assert identity.created_by == :provider
      assert identity.provisioned_via == :scim
      # The externalId is stored as BOTH the binding identifier and the
      # scim_external_id (decision 4) so OIDC + SCIM converge on one identity.
      assert identity.provider_identifier == "okta|prov-1"
      assert identity.scim_external_id == "okta|prov-1"
      assert identity.scim_active

      assert membership.account_id == account.id
      assert membership.user_id == user.id
      assert membership.role == :operator
      refute membership.disabled_at
    end

    test "a no-email directory user provisions with nil email (identified by externalId)", %{
      provider: provider
    } do
      attrs = scim_attrs(%{external_id: "okta|nomail"})

      assert {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)
      refute user.email
      assert identity.scim_external_id == "okta|nomail"
    end

    test "a repeated provision for the same externalId reconciles — no duplicate", %{
      provider: provider
    } do
      attrs = scim_attrs(%{external_id: "okta|stable", email: "stable@acme.test"})

      assert {:ok, %{user: first, identity: id1}} = SSO.scim_provision_user(provider, attrs)
      assert {:ok, %{user: second, identity: id2}} = SSO.scim_provision_user(provider, attrs)

      assert first.id == second.id
      assert id1.id == id2.id

      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_provider_id(provider.id)
             |> Repo.aggregate(:count) == 1
    end

    test "a re-POST of a deprovisioned (suspended) user reactivates them (#4)", %{
      provider: provider,
      account: account
    } do
      attrs = scim_attrs(%{external_id: "okta|readd", email: "readd@acme.test"})

      assert {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      {:ok, _} =
        SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # Some IdPs re-POST rather than PATCH active:true — the re-POST restores
      # access (reinstate the membership + scim_active), never staying suspended.
      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      refute membership.disabled_at
      assert identity.scim_active
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a re-POST after the membership was removed re-creates it (#10)", %{
      provider: provider,
      account: account
    } do
      attrs = scim_attrs(%{external_id: "okta|removed", email: "removed@acme.test"})

      assert {:ok, %{user: user, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      # An operator removed them from the team (membership soft-deleted) while
      # the identity lived on.
      Fixtures.Memberships.mark_membership_as_deleted(membership)

      refute Accounts.peek_sync_membership(account.id, user.id)

      # The re-POST re-provisions a fresh membership rather than 404ing.
      assert {:ok, %{membership: new_membership}} = SSO.scim_provision_user(provider, attrs)
      refute new_membership.disabled_at
      assert Accounts.peek_sync_membership(account.id, user.id)
    end

    test "a colliding email fails :email_taken — never merges onto the existing user", %{
      provider: provider
    } do
      existing = Fixtures.Users.create_user(%{email: "taken@acme.test"})
      attrs = scim_attrs(%{external_id: "okta|collide", email: "taken@acme.test"})

      assert SSO.scim_provision_user(provider, attrs) == {:error, :email_taken}

      # The pre-existing user is untouched + no identity was bound to it.
      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_user_id(existing.id)
             |> Repo.all() == []
    end

    test "a provider-A-scoped provision never lands in account B (cross-account)", %{
      provider: provider_a,
      account: account_a
    } do
      %{account: account_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", email: "scoped@acme.test"})

      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider_a, attrs)

      assert Fixtures.Memberships.fetch_membership(account_a.id, user.id)
      refute Fixtures.Memberships.fetch_membership(account_b.id, user.id)
    end
  end

  # -- PATCH reduction -------------------------------------------------

  describe "scim_patch_user/3" do
    setup do
      scim_provider()
    end

    test "the LAST operation to touch an attribute decides, name and lifecycle alike", %{
      provider: provider,
      account: account
    } do
      %{user: user, identity: identity} = provisioned(provider, "okta|ordered", "Old Name")

      operations = [
        %{"op" => "replace", "path" => "active", "value" => true},
        %{"op" => "replace", "path" => "displayName", "value" => "Interim"},
        %{"op" => "replace", "path" => "displayName", "value" => "Final Name"},
        %{"op" => "replace", "path" => "active", "value" => false}
      ]

      assert {:ok, %{membership: membership}} =
               SSO.scim_patch_user(provider, identity.id, operations)

      assert membership.disabled_at
      assert Repo.reload!(user).full_name == "Final Name"
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end

    test "a case-insensitive verb and Entra's pathless value map are both recognized", %{
      provider: provider,
      account: account
    } do
      %{user: user, identity: identity} = provisioned(provider, "okta|pathless", "Old Name")

      operations = [
        %{"op" => "Add", "value" => %{"active" => "False", "displayName" => "Pathless Name"}}
      ]

      assert {:ok, _result} = SSO.scim_patch_user(provider, identity.id, operations)

      assert Repo.reload!(user).full_name == "Pathless Name"
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end

    test "a whole name wins over the components batched around it", %{provider: provider} do
      %{user: user, identity: identity} = provisioned(provider, "okta|whole", "Old Name")

      operations = [
        %{"op" => "add", "path" => "name.givenName", "value" => "Given"},
        %{"op" => "replace", "path" => "displayName", "value" => "Whole Name"},
        %{"op" => "add", "path" => "name.familyName", "value" => "Family"}
      ]

      assert {:ok, _result} = SSO.scim_patch_user(provider, identity.id, operations)
      assert Repo.reload!(user).full_name == "Whole Name"
    end

    test "a component-only rename keeps the half the batch does not name", %{provider: provider} do
      %{user: user, identity: identity} = provisioned(provider, "okta|component", "Ada Lovelace")

      operations = [%{"op" => "Add", "path" => "name.givenName", "value" => "Augusta"}]

      assert {:ok, _result} = SSO.scim_patch_user(provider, identity.id, operations)
      assert Repo.reload!(user).full_name == "Augusta Lovelace"
    end

    test "a batch past the operation cap is refused before any of it is applied", %{
      provider: provider,
      account: account
    } do
      %{user: user, identity: identity} = provisioned(provider, "okta|flood", "Old Name")
      operation = %{"op" => "replace", "path" => "active", "value" => false}

      assert SSO.scim_patch_user(provider, identity.id, List.duplicate(operation, 101)) ==
               {:error, :too_many_scim_operations}

      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
      assert Repo.reload!(user).full_name == "Old Name"
    end

    test "an unparseable `active` takes the rename batched with it", %{provider: provider} do
      %{user: user, identity: identity} = provisioned(provider, "okta|badactive", "Old Name")

      operations = [
        %{"op" => "replace", "path" => "displayName", "value" => "New Name"},
        %{"op" => "replace", "path" => "active", "value" => "maybe"}
      ]

      assert SSO.scim_patch_user(provider, identity.id, operations) ==
               {:error, :invalid_scim_active}

      assert Repo.reload!(user).full_name == "Old Name"
    end

    test "a batch asking for nothing we model is refused, not silently accepted", %{
      provider: provider
    } do
      %{identity: identity} = provisioned(provider, "okta|nothing", "Old Name")

      operations = [%{"op" => "add", "path" => "nickName", "value" => "nick"}]

      assert SSO.scim_patch_user(provider, identity.id, operations) ==
               {:error, :unsupported_scim_patch}
    end

    test "a supported operation cannot hide an unsupported one", %{provider: provider} do
      %{user: user, identity: identity} = provisioned(provider, "okta|mixed", "Old Name")

      operations = [
        %{"op" => "replace", "path" => "displayName", "value" => "New Name"},
        %{"op" => "replace", "path" => "title", "value" => "Administrator"}
      ]

      assert SSO.scim_patch_user(provider, identity.id, operations) ==
               {:error, :unsupported_scim_patch}

      assert Repo.reload!(user).full_name == "Old Name"
    end

    test "another provider's resource id is not found (the provider scopes the write)", %{
      provider: provider_a
    } do
      %{provider: provider_b, account: account_b} = scim_provider()

      %{user: user, identity: identity_b} =
        provisioned(provider_b, "okta|elsewhere", "B Person")

      operations = [%{"op" => "replace", "path" => "active", "value" => false}]

      assert SSO.scim_patch_user(provider_a, identity_b.id, operations) ==
               {:error, :not_found}

      refute Fixtures.Memberships.fetch_membership(account_b.id, user.id).disabled_at
    end
  end

  # -- Deprovision / reprovision ---------------------------------------

  describe "scim_update_user/3 deactivate" do
    test "suspends the membership (disabled_at) + revokes the user's API keys + does NOT delete the user" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :admin})
      attrs = scim_attrs(%{external_id: "okta|deprov", email: "deprov@acme.test"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      assert {:ok, %{membership: membership, identity: deactivated}} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      # Membership suspended, the SCIM lifecycle flag flipped.
      assert membership.disabled_at
      refute deactivated.scim_active

      # The membership row was disabled, not deleted.
      reloaded_membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      assert reloaded_membership.disabled_at

      # The user + identity survive (audit preservation) — only access is cut.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
      assert {:ok, _scim_user} = SSO.scim_fetch_user(provider, identity.id)

      # Their delegated execute access (API keys) is revoked — a revoked key
      # is no longer usable, so the credential-resolution path returns nil.
      assert ApiKeys.peek_api_key_by_id(key.id) == nil
    end

    test "deactivating the last active owner is refused (:last_owner)" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :viewer})
      attrs = scim_attrs(%{external_id: "okta|owner"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)

      # Promote the lone provisioned member to the account's only owner (the
      # bootstrap owner is a separate account in this fixture, so this user is
      # the last active owner of their membership's account once promoted).
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      # Demote the original bootstrap owner so the provisioned user is the
      # single remaining active owner.
      demote_other_owners(account.id, except: user.id)

      assert SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false}) ==
               {:error, :last_owner}

      # The membership stays active and the SCIM flag is left untouched, so the
      # projection still answers active.
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
      assert {:ok, unchanged} = SSO.scim_fetch_user(provider, identity.id)
      assert unchanged.active
    end

    test "returns :not_found when no identity matches the resource id" do
      %{provider: provider} = scim_provider()

      assert SSO.scim_update_user(provider, Ecto.UUID.generate(), %SCIMUserUpdate{active: false}) ==
               {:error, :not_found}
    end
  end

  describe "scim_update_user/3 reactivate" do
    test "clears disabled_at on a suspended membership" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|react", email: "react@acme.test"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})
      assert Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: true})

      refute membership.disabled_at
      assert identity.scim_active
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end
  end

  # -- Config (Subject-gated) ------------------------------------------

  describe "enable_scim / rotate_scim_token / disable_scim" do
    test "enable returns the raw token once and persists only the hash" do
      {_user, account, subject} = enterprise_owner()
      provider = provider_fixture(account)

      assert {:ok, enabled, raw} = SSO.enable_scim(provider, subject)
      assert String.starts_with?(raw, "ems-")
      assert enabled.scim_enabled

      stored =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.by_id(provider.id)
        |> Repo.fetch!(IdentityProvider.Query)

      # The raw token is never stored; only its prefix + hash are.
      assert stored.scim_token_prefix == String.slice(raw, 0, 12)
      assert stored.scim_token_hash == Crypto.hash(raw)
      refute stored.scim_token_hash == raw
    end

    test "rotate mints a NEW token and invalidates the old one" do
      %{provider: provider, token: old_token, subject: subject} = scim_provider()

      assert {:ok, _provider, new_token} = SSO.rotate_scim_token(provider, subject)
      refute new_token == old_token

      assert SSO.authenticate_scim_token(old_token) == {:error, :unauthorized}
      assert {:ok, _provider} = SSO.authenticate_scim_token(new_token)
    end

    test "a Team account cannot enable SCIM — directory sync is Enterprise-only" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = %IdentityProvider{id: Ecto.UUID.generate()}

      assert SSO.enable_scim(provider, subject) == {:error, :directory_sync_not_available}
    end

    test "a non-admin (no manage_sso) cannot enable SCIM" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: :viewer
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert SSO.enable_scim(provider, viewer_subject) == {:error, :unauthorized}
    end

    test "account B's subject cannot enable SCIM on account A's provider (cross-account)" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert SSO.enable_scim(provider, sb) == {:error, :not_found}
    end

    test "disable clears the token so a stale bearer can't authenticate" do
      %{provider: provider, token: token, subject: subject} = scim_provider()

      assert {:ok, disabled} = SSO.disable_scim(provider, subject)
      refute disabled.scim_enabled
      refute disabled.scim_token_prefix
      refute disabled.scim_token_hash

      assert SSO.authenticate_scim_token(token) == {:error, :unauthorized}
    end
  end

  # -- Audit -----------------------------------------------------------

  describe "directory-sync audit" do
    test "provision + deprovision write directory_sync audit rows attributed to the provider" do
      %{provider: provider} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|audit", email: "audit@acme.test"})

      {:ok, %{identity: identity}} = SSO.scim_provision_user(provider, attrs)

      {:ok, _} =
        SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{active: false})

      events = audit_events_for(provider.account_id)

      provisioned = Enum.find(events, &(&1.event_type == "user.provisioned_via_scim"))
      assert provisioned.actor_kind == "directory_sync"
      assert provisioned.actor_id == provider.id

      deprovisioned = Enum.find(events, &(&1.event_type == "membership.deprovisioned_via_scim"))
      assert deprovisioned.actor_kind == "directory_sync"
      assert deprovisioned.actor_id == provider.id
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp demote_other_owners(account_id, except: keep_user_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.user_id == keep_user_id))
    |> Enum.each(&Fixtures.Memberships.force_role(&1, "admin"))
  end

  defp audit_events_for(account_id) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Repo.all()
  end
end
