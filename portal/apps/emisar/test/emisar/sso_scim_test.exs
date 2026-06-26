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

  import Emisar.Fixtures

  alias Emisar.{Accounts, ApiKeys, Crypto, Repo, SSO, Users}
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  defp enterprise_owner do
    owner_subject_fixture(%{plan: "enterprise"})
  end

  defp provider_fixture(account, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
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

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
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

  # -- Token auth ------------------------------------------------------

  describe "authenticate_scim_token/1" do
    test "resolves the right provider by prefix + hash" do
      %{provider: provider, token: token} = scim_provider()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token)
      assert resolved.id == provider.id
      assert resolved.account_id == provider.account_id
    end

    test "a garbage / too-short / wrong token is :unauthorized" do
      %{token: token} = scim_provider()

      assert {:error, :unauthorized} = SSO.authenticate_scim_token("")
      assert {:error, :unauthorized} = SSO.authenticate_scim_token("ems-")
      assert {:error, :unauthorized} = SSO.authenticate_scim_token("ems-totally-wrong-secret")
      # A correct prefix but a tampered tail must still fail the hash compare.
      assert {:error, :unauthorized} = SSO.authenticate_scim_token(token <> "x")
    end

    test "a token whose provider has scim disabled is :unauthorized" do
      %{provider: provider, token: token, subject: subject} = scim_provider()

      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert {:error, :unauthorized} = SSO.authenticate_scim_token(token)
    end

    test "token A resolves to provider A only — never account B's provider" do
      %{provider: provider_a, token: token_a} = scim_provider()
      %{provider: provider_b} = scim_provider()

      assert {:ok, resolved} = SSO.authenticate_scim_token(token_a)
      assert resolved.id == provider_a.id
      refute resolved.id == provider_b.id
      assert resolved.account_id != provider_b.account_id
    end

    test "a soft-deleted provider sharing the prefix doesn't crash the lookup" do
      %{provider: provider, token: token} = scim_provider()

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

    test "a no-email directory user provisions with nil email (identified by externalId)" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|nomail"})

      assert {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)
      refute user.email
      assert identity.scim_external_id == "okta|nomail"
    end

    test "a repeated provision for the same externalId reconciles — no duplicate" do
      %{provider: provider} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|stable", email: "stable@acme.test"})

      assert {:ok, %{user: first, identity: id1}} = SSO.scim_provision_user(provider, attrs)
      assert {:ok, %{user: second, identity: id2}} = SSO.scim_provision_user(provider, attrs)

      assert first.id == second.id
      assert id1.id == id2.id

      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_provider_id(provider.id)
             |> Repo.aggregate(:count) == 1
    end

    test "a re-POST of a deprovisioned (suspended) user reactivates them (#4)" do
      %{provider: provider, account: account} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|readd", email: "readd@acme.test"})

      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|readd")
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # Some IdPs re-POST rather than PATCH active:true — the re-POST restores
      # access (reinstate the membership + scim_active), never staying suspended.
      assert {:ok, %{identity: identity, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      refute membership.disabled_at
      assert identity.scim_active
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a re-POST after the membership was removed re-creates it (#10)" do
      %{provider: provider, account: account} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|removed", email: "removed@acme.test"})

      assert {:ok, %{user: user, membership: membership}} =
               SSO.scim_provision_user(provider, attrs)

      # An operator removed them from the team (membership soft-deleted) while
      # the identity lived on.
      {:ok, _} =
        membership |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      refute Accounts.peek_sync_membership(account.id, user.id)

      # The re-POST re-provisions a fresh membership rather than 404ing.
      assert {:ok, %{membership: new_membership}} = SSO.scim_provision_user(provider, attrs)
      refute new_membership.disabled_at
      assert Accounts.peek_sync_membership(account.id, user.id)
    end

    test "a colliding email fails :email_taken — never merges onto the existing user" do
      %{provider: provider} = scim_provider()
      existing = user_fixture(%{email: "taken@acme.test"})
      attrs = scim_attrs(%{external_id: "okta|collide", email: "taken@acme.test"})

      assert {:error, :email_taken} = SSO.scim_provision_user(provider, attrs)

      # The pre-existing user is untouched + no identity was bound to it.
      assert UserIdentity.Query.not_deleted()
             |> UserIdentity.Query.by_user_id(existing.id)
             |> Repo.all() == []
    end

    test "a provider-A-scoped provision never lands in account B (cross-account)" do
      %{provider: provider_a, account: account_a} = scim_provider()
      %{account: account_b} = scim_provider()
      attrs = scim_attrs(%{external_id: "okta|scoped", email: "scoped@acme.test"})

      assert {:ok, %{user: user}} = SSO.scim_provision_user(provider_a, attrs)

      assert fetch_membership(account_a.id, user.id)
      refute fetch_membership(account_b.id, user.id)
    end
  end

  # -- Deprovision / reprovision ---------------------------------------

  describe "scim_deactivate_user/2" do
    test "suspends the membership (disabled_at) + revokes the user's API keys + does NOT delete the user" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :admin})
      attrs = scim_attrs(%{external_id: "okta|deprov", email: "deprov@acme.test"})

      {:ok, %{user: user, identity: identity}} = SSO.scim_provision_user(provider, attrs)
      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      assert {:ok, %{membership: membership, identity: deactivated}} =
               SSO.scim_deactivate_user(provider, "okta|deprov")

      # Membership suspended, the SCIM lifecycle flag flipped.
      assert membership.disabled_at
      refute deactivated.scim_active

      # The membership row was disabled, not deleted.
      reloaded_membership = fetch_membership(account.id, user.id)
      assert reloaded_membership.disabled_at

      # The user + identity survive (audit preservation) — only access is cut.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
      assert {:ok, _identity} = SSO.scim_fetch_user(provider, identity.scim_external_id)

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
      membership = fetch_membership(account.id, user.id)
      force_membership_role(membership, "owner")
      # Demote the original bootstrap owner so the provisioned user is the
      # single remaining active owner.
      demote_other_owners(account.id, except: user.id)

      assert {:error, :last_owner} = SSO.scim_deactivate_user(provider, "okta|owner")

      # The membership stays active and the SCIM flag is left untouched.
      refute fetch_membership(account.id, user.id).disabled_at
      assert {:ok, unchanged} = SSO.scim_fetch_user(provider, identity.scim_external_id)
      assert unchanged.scim_active
    end

    test "returns :not_found when no identity matches the externalId" do
      %{provider: provider} = scim_provider()
      assert {:error, :not_found} = SSO.scim_deactivate_user(provider, "okta|nobody")
    end
  end

  describe "scim_reactivate_user/2" do
    test "clears disabled_at on a suspended membership" do
      %{provider: provider, account: account} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|react", email: "react@acme.test"})

      {:ok, %{user: user}} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|react")
      assert fetch_membership(account.id, user.id).disabled_at

      assert {:ok, %{membership: membership, identity: identity}} =
               SSO.scim_reactivate_user(provider, "okta|react")

      refute membership.disabled_at
      assert identity.scim_active
      refute fetch_membership(account.id, user.id).disabled_at
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

      assert {:error, :unauthorized} = SSO.authenticate_scim_token(old_token)
      assert {:ok, _provider} = SSO.authenticate_scim_token(new_token)
    end

    test "a Team account cannot enable SCIM — directory sync is Enterprise-only" do
      {_user, _account, subject} = owner_subject_fixture(%{plan: "team"})
      provider = %IdentityProvider{id: Ecto.UUID.generate()}

      assert {:error, :directory_sync_not_available} = SSO.enable_scim(provider, subject)
    end

    test "a non-admin (no manage_sso) cannot enable SCIM" do
      {_owner, account, _owner_subject} = enterprise_owner()
      provider = provider_fixture(account)
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: :viewer)
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = SSO.enable_scim(provider, viewer_subject)
    end

    test "account B's subject cannot enable SCIM on account A's provider (cross-account)" do
      {_ua, account_a, _sa} = enterprise_owner()
      {_ub, _account_b, sb} = enterprise_owner()
      provider = provider_fixture(account_a)

      assert {:error, :not_found} = SSO.enable_scim(provider, sb)
    end

    test "disable clears the token so a stale bearer can't authenticate" do
      %{provider: provider, token: token, subject: subject} = scim_provider()

      assert {:ok, disabled} = SSO.disable_scim(provider, subject)
      refute disabled.scim_enabled
      refute disabled.scim_token_prefix
      refute disabled.scim_token_hash

      assert {:error, :unauthorized} = SSO.authenticate_scim_token(token)
    end
  end

  # -- Audit -----------------------------------------------------------

  describe "directory-sync audit" do
    test "provision + deprovision write directory_sync audit rows attributed to the provider" do
      %{provider: provider} = scim_provider(%{default_role: :operator})
      attrs = scim_attrs(%{external_id: "okta|audit", email: "audit@acme.test"})

      {:ok, _} = SSO.scim_provision_user(provider, attrs)
      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|audit")

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
    |> Enum.each(&force_membership_role(&1, "admin"))
  end

  defp audit_events_for(account_id) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account_id)
    |> Repo.all()
  end
end
