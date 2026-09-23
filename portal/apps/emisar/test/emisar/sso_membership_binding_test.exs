defmodule Emisar.SSOMembershipBindingTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, Repo, RequestContext, SSO}
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

  test "ordinary OIDC proof cannot adopt a replacement membership", %{
    member: member,
    subject: subject,
    identity: identity,
    user: user,
    provider: provider
  } do
    replacement = replace_member(member, subject)

    claims = %{
      "sub" => identity.provider_identifier,
      "email" => user.email,
      "email_verified" => true
    }

    assert {:error, :membership_unavailable} =
             SSO.complete_auth(provider, %{"claims" => claims}, %{})

    assert Repo.reload!(replacement).display_name == "Replacement Member"
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
    provider: provider
  } do
    replacement = replace_member(member, subject)
    refute SSO.member_profile_directory_managed?(account.id, replacement.id)
    assert SSO.member_directory_facts([replacement.id], subject) == {:ok, %{}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _provider} =
                 SSO.update_provider(
                   provider,
                   %{default_role: :admin},
                   subject
                 )
      end)

    # The capture also collects other async tests' lines; a skipped recompute
    # names this connection.
    refute log =~ provider.id

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
