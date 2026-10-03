defmodule Emisar.SSOMembershipBindingTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Crypto, Fixtures, Repo, RequestContext, SSO}
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

    email = Fixtures.Random.unique_email()

    assert {:ok, %{identity: identity, membership: member}} =
             SSO.scim_provision_user(provider, %{
               external_id: "directory-person",
               email: email,
               full_name: "Original Member"
             })

    %{
      account: account,
      subject: subject,
      provider: provider,
      identity: identity,
      member: member
    }
  end

  defp replace_member(member, subject) do
    assert {:ok, _removed} = Accounts.delete_membership(member, subject)

    # The same address joins again as a new Member.
    Fixtures.Memberships.create_membership(
      account_id: member.account_id,
      email: member.email,
      display_name: "Replacement Member"
    )
  end

  test "ordinary OIDC proof cannot adopt a replacement membership", %{
    member: member,
    subject: subject,
    identity: identity,
    provider: provider
  } do
    replacement = replace_member(member, subject)

    claims = %{
      "sub" => identity.provider_identifier,
      "email" => member.email,
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
    provider: provider
  } do
    replace_member(member, subject)

    assert Auth.complete_sso_sign_in(
             member,
             identity,
             provider,
             Crypto.random_secret(),
             %RequestContext{}
           ) == {:error, :membership_unavailable}
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

  test "inactive directory writes leave a replacement seat alone; a reprovision is refused while it holds the address",
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

    # One address is one live Member: the directory cannot re-seat the person
    # onto the replacement, nor beside it, while the replacement holds it.
    assert SSO.scim_provision_user(provider, %{
             external_id: "directory-person",
             active: true
           }) == {:error, :member_email_taken}

    assert Repo.reload!(identity).membership_id == member.id
    assert Repo.reload!(replacement).display_name == "Replacement Member"
    refute Repo.reload!(replacement).disabled_at
  end

  test "a stale link approval cannot target a replacement; a fresh request can", %{
    member: member,
    subject: subject,
    identity: identity,
    provider: provider
  } do
    claims = %{
      "sub" => "fresh-oidc-subject",
      "email" => member.email,
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

    # The replacement gets its own identity for the subject it proved; the
    # identity left on the removed seat is never adopted.
    assert linked.membership_id == replacement.id
    assert linked.provider_identifier == "fresh-oidc-subject"
    refute linked.id == identity.id
    assert Repo.reload!(identity).membership_id == member.id
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

  test "a removed Member is never re-found through its address", %{
    account: account,
    subject: subject,
    provider: provider
  } do
    email = Fixtures.Random.unique_email()

    assert {:ok, %{identity: identity, membership: member}} =
             SSO.scim_provision_user(provider, %{
               external_id: "unlinked-person",
               email: email,
               full_name: "Unlinked Member"
             })

    assert {:ok, _removed} = Accounts.delete_membership(member, subject)

    namesake =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        email: email
      )

    claims = %{"sub" => identity.provider_identifier, "email" => email, "email_verified" => true}

    assert {:error, :membership_unavailable} =
             SSO.complete_auth(provider, %{"claims" => claims}, %{})

    # One address is one live Member: the directory's re-POST is refused while
    # the namesake holds it, and re-seats the person once the address is free.
    assert SSO.scim_provision_user(provider, %{external_id: "unlinked-person", active: true}) ==
             {:error, :member_email_taken}

    assert Repo.reload!(identity).membership_id == member.id

    assert {:ok, _removed} = Accounts.delete_membership(namesake, subject)

    assert {:ok, %{membership: reseated, identity: rebound}} =
             SSO.scim_provision_user(provider, %{external_id: "unlinked-person", active: true})

    refute reseated.id in [member.id, namesake.id]
    assert reseated.email == email
    assert rebound.membership_id == reseated.id
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
