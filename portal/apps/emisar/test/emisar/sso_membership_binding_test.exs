defmodule Emisar.SSOMembershipBindingTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, Repo, RequestContext, SSO, Users}
  alias Emisar.SSO.SCIMUserUpdate

  defmodule VerifiedOIDC do
    @behaviour Emisar.SSO.OIDC
    @impl true
    def begin_authorization(_provider, _opts), do: {:error, :unused}
    @impl true
    def discover(_provider), do: {:error, :unused}
    @impl true
    def verify_callback(_provider, %{"claims" => claims}, _stash),
      do: {:ok, %{identifier: claims["sub"], claims: claims}}
  end

  setup do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, VerifiedOIDC)
    {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      |> Fixtures.SSO.enable_scim()

    assert {:ok, %{identity: identity, membership: member, user: user}} =
             SSO.scim_provision_user(provider, %{
               external_id: "directory-person",
               email: "directory-person@example.com",
               full_name: "Original Member"
             })

    %{
      account: account,
      subject: subject,
      provider: provider,
      identity: identity,
      member: member,
      user: user
    }
  end

  defp replace_member(member, subject) do
    assert {:ok, _removed} = Accounts.delete_membership(member, subject)

    Fixtures.Memberships.create_membership(
      account_id: member.account_id,
      user_id: member.user_id,
      display_name: "Replacement Member"
    )
  end

  defp oidc_member(account) do
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :keycloak)
    user = Fixtures.Users.create_user()
    member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id,
        membership: member
      })

    %{provider: provider, user: user, member: member, identity: identity}
  end

  defp verified_claims(identity, user) do
    %{"sub" => identity.provider_identifier, "email" => user.email, "email_verified" => true}
  end

  test "OIDC proof for a replacement seat waits for an admin, whose approval binds it", %{
    member: member,
    subject: subject,
    identity: identity,
    user: user,
    provider: provider
  } do
    replacement = replace_member(member, subject)
    claims = verified_claims(identity, user)

    assert {:pending, request} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert request.matched_membership_id == replacement.id
    assert Repo.reload!(identity).membership_id == member.id
    assert Repo.reload!(replacement).display_name == "Replacement Member"

    assert {:ok, %{identity: linked}} =
             SSO.approve_link_request(request, Accounts.RunnerAccess.none(), subject)

    assert linked.id == identity.id
    assert linked.membership_id == replacement.id

    assert {:ok, %{identity: signed_in}} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert signed_in.membership_id == replacement.id
  end

  test "an OIDC member invited back is held until they accept, then approval binds the new seat",
       %{account: account, subject: subject} do
    %{provider: provider, user: user, member: member, identity: identity} = oidc_member(account)
    assert {:ok, _removed} = Accounts.delete_membership(member, subject)
    invitation_attrs = Fixtures.Accounts.invitation_attrs(email: user.email)

    assert {:ok, %{membership: invitation, invitation_token: token}} =
             Accounts.invite_user_to_account(invitation_attrs, subject)

    claims = verified_claims(identity, user)
    assert {:pending, request} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert request.matched_membership_id == invitation.id

    assert SSO.approve_link_request(request, Accounts.RunnerAccess.none(), subject) ==
             {:error, :invitation_pending}

    assert {:ok, _accepted} = Accounts.mark_invitation_accepted(invitation, token, user)

    assert {:ok, %{identity: linked}} =
             SSO.approve_link_request(request, Accounts.RunnerAccess.none(), subject)

    assert linked.id == identity.id
    assert linked.membership_id == invitation.id

    assert {:ok, %{identity: signed_in}} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert signed_in.membership_id == invitation.id
  end

  test "a removed member who was not invited back stays refused and is never re-provisioned", %{
    account: account,
    subject: subject
  } do
    %{provider: provider, user: user, member: member, identity: identity} = oidc_member(account)
    assert {:ok, _removed} = Accounts.delete_membership(member, subject)
    users_before = Repo.aggregate(Users.User, :count)
    memberships_before = Repo.aggregate(Accounts.Membership, :count)
    verified = verified_claims(identity, user)
    unverified = Map.delete(verified, "email_verified")

    assert SSO.complete_auth(provider, %{"claims" => verified}, %{}) ==
             {:error, :membership_unavailable}

    assert SSO.complete_auth(provider, %{"claims" => unverified}, %{}) ==
             {:error, :membership_unavailable}

    refute Repo.one(SSO.LinkRequest)
    assert Repo.aggregate(Users.User, :count) == users_before
    assert Repo.aggregate(Accounts.Membership, :count) == memberships_before
    assert Repo.reload!(identity).membership_id == member.id
  end

  test "a returning member whose token has no verified email is refused, never held", %{
    account: account,
    subject: subject
  } do
    %{provider: provider, user: user, member: member, identity: identity} = oidc_member(account)
    _replacement = replace_member(member, subject)
    claims = Map.delete(verified_claims(identity, user), "email_verified")

    assert SSO.complete_auth(provider, %{"claims" => claims}, %{}) ==
             {:error, :membership_unavailable}

    refute Repo.one(SSO.LinkRequest)
    assert Repo.reload!(identity).membership_id == member.id
  end

  test "a live seat in another workspace never holds a sign-in here", %{
    account: account,
    subject: subject
  } do
    %{provider: provider, user: user, member: member, identity: identity} = oidc_member(account)
    assert {:ok, _removed} = Accounts.delete_membership(member, subject)
    other_account = Fixtures.Accounts.create_account()
    Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: user.id)

    assert SSO.complete_auth(provider, %{"claims" => verified_claims(identity, user)}, %{}) ==
             {:error, :membership_unavailable}

    refute Repo.one(SSO.LinkRequest)
    assert Repo.reload!(identity).membership_id == member.id
  end

  test "a suspended seat stays refused, never held", %{account: account} do
    %{provider: provider, user: user, member: member, identity: identity} = oidc_member(account)
    Fixtures.Memberships.suspend_membership(member)

    assert SSO.complete_auth(provider, %{"claims" => verified_claims(identity, user)}, %{}) ==
             {:error, :membership_unavailable}

    refute Repo.one(SSO.LinkRequest)
    assert Repo.reload!(identity).membership_id == member.id
  end

  test "session mint rechecks the exact membership after callback completion", %{
    member: member,
    subject: subject,
    identity: identity,
    user: user,
    account: account
  } do
    replace_member(member, subject)

    assert {:error, :membership_unavailable} =
             Auth.complete_sso_account_sign_in(
               user,
               account.id,
               %RequestContext{},
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             )
  end

  test "an old SCIM resource neither reads nor renames the replacement member", %{
    member: member,
    subject: subject,
    identity: identity,
    provider: provider
  } do
    replacement = replace_member(member, subject)

    assert {:ok, resource} = SSO.scim_fetch_user(provider, identity.id)
    refute resource.active
    assert resource.display_name == "Original Member"

    assert {:error, :not_found} =
             SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
               name: {:replace, "Directory Rename"}
             })

    assert Repo.reload!(replacement).display_name == "Replacement Member"
  end

  test "inactive directory writes leave a replacement seat alone; explicit reprovision binds it",
       %{member: member, subject: subject, identity: identity, provider: provider} do
    replacement = replace_member(member, subject)

    assert {:ok, %{membership: nil}} =
             SSO.scim_update_user(provider, identity.id, %SCIMUserUpdate{
               active: false
             })

    assert {:ok, %{membership: nil}} =
             SSO.scim_provision_user(provider, %{
               external_id: "directory-person",
               active: false
             })

    refute Repo.reload!(replacement).disabled_at

    assert {:ok, %{membership: rebound, identity: identity}} =
             SSO.scim_provision_user(provider, %{
               external_id: "directory-person",
               active: true
             })

    assert rebound.id == replacement.id
    assert identity.membership_id == replacement.id
    assert {:ok, resource} = SSO.scim_fetch_user(provider, identity.id)
    assert resource.active
    assert resource.display_name == "Replacement Member"
  end

  test "a stale link approval cannot target a replacement; a fresh request can", %{
    member: member,
    subject: subject,
    user: user,
    identity: identity,
    provider: provider
  } do
    claims = %{
      "sub" => "fresh-oidc-subject",
      "email" => user.email,
      "email_verified" => true
    }

    assert {:pending, request} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert request.matched_membership_id == member.id
    replacement = replace_member(member, subject)

    assert SSO.approve_link_request(request, Accounts.RunnerAccess.none(), subject) ==
             {:error, :matched_user_unavailable}

    assert Repo.reload!(identity).membership_id == member.id
    assert Repo.reload!(request)

    assert {:pending, fresh} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert fresh.id == request.id
    assert {:ok, persisted} = SSO.fetch_pending_link_request(fresh.id)
    assert persisted.matched_membership_id == replacement.id
    assert fresh.matched_membership_id == replacement.id

    assert {:ok, %{identity: linked}} =
             SSO.approve_link_request(fresh, Accounts.RunnerAccess.none(), subject)

    assert linked.membership_id == replacement.id
    assert linked.id == identity.id
  end

  test "directory attribution and policy changes do not adopt a replacement seat", %{
    member: member,
    subject: subject,
    account: account,
    user: user,
    provider: provider
  } do
    replacement = replace_member(member, subject)
    refute SSO.member_profile_directory_managed?(account.id, replacement.id)
    assert SSO.member_directory_facts([user.id], subject) == {:ok, %{}}

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, _provider} =
                      SSO.update_provider(
                        provider,
                        %{default_role: :admin},
                        subject
                      )
           end) == ""

    unchanged = Repo.reload!(replacement)
    assert unchanged.role == replacement.role
    refute unchanged.directory_authorization_pending_version
    refute unchanged.directory_managed
  end

  test "an identity cannot bind a membership from a different account", %{
    account: account,
    provider: provider
  } do
    foreign = Fixtures.Memberships.create_membership()

    assert {:error, changeset} =
             account.id
             |> SSO.UserIdentity.Changeset.create(provider.id, foreign, %{
               provider_identifier: "foreign-seat",
               created_by: :provider,
               provisioned_via: :oidc_jit
             })
             |> Repo.insert()

    assert "does not exist" in errors_on(changeset).membership_id
  end
end
