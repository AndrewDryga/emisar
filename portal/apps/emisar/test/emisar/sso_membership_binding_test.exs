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

  defp ambiguous_oidc_member do
    {owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    claims = %{"sub" => "oidc-without-email"}

    assert {:ok, %{user: user, identity: identity}} =
             SSO.complete_auth(provider, %{"claims" => claims}, %{})

    original = Accounts.peek_sync_membership_by_id(account.id, identity.membership_id)
    assert {:ok, _removed} = Accounts.delete_membership(original, subject)
    replacement = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
    # The forward migration deliberately leaves this multi-history case unbound.
    identity = Fixtures.SSO.clear_identity_membership(identity)

    owner_identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: owner.id
      )

    subject =
      Fixtures.Subjects.subject_for(owner, account,
        auth_method: :sso,
        user_identity_id: owner_identity.id
      )

    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

    %{
      subject: subject,
      provider: provider,
      identity: identity,
      member: replacement,
      claims: claims
    }
  end

  test "an ambiguous no-email OIDC binding requires exact admin recovery before login" do
    context = ambiguous_oidc_member()

    assert {:pending, request} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert request.matched_membership_id == context.member.id
    assert request.recovery_identity_id == context.identity.id
    assert is_nil(Repo.reload!(context.identity).membership_id)

    assert context.member.user_id
           |> Auth.UserToken.Query.by_user_id()
           |> Repo.aggregate(:count) == 0

    assert {:pending, repeated} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert repeated.id == request.id

    assert {:ok, %{identity: rebound}} =
             SSO.approve_link_request(
               request,
               Accounts.RunnerAccess.none(),
               context.provider.default_role,
               context.subject
             )

    assert rebound.id == context.identity.id
    assert rebound.membership_id == context.member.id
    assert rebound.created_by == :admin
    assert Repo.reload!(context.member).role == context.member.role

    assert {:ok, %{identity: returned}} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert returned.id == rebound.id
  end

  test "an ambiguous identity recovery cannot adopt another removed and rejoined seat" do
    context = ambiguous_oidc_member()

    assert {:pending, request} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert {:ok, _removed} = Accounts.delete_membership(context.member, context.subject)

    Fixtures.Memberships.create_membership(
      account_id: context.provider.account_id,
      user_id: context.member.user_id
    )

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             context.subject
           ) ==
             {:error, :matched_user_unavailable}

    assert is_nil(Repo.reload!(context.identity).membership_id)
  end

  test "recovery uses the established identity, never another person's asserted email" do
    context = ambiguous_oidc_member()
    other = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: context.provider.account_id,
      user_id: other.id
    )

    claims = Map.merge(context.claims, %{"email" => other.email, "email_verified" => true})

    assert {:pending, request} = SSO.complete_auth(context.provider, %{"claims" => claims}, %{})
    assert request.matched_user_id == context.member.user_id
    assert request.matched_membership_id == context.member.id
    assert request.email == context.member.contact_email
    refute request.email == other.email
  end

  test "a recaptured recovery cannot approve a different member than the reviewed request" do
    context = ambiguous_oidc_member()

    assert {:pending, reviewed} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert {:ok, _removed} = Accounts.delete_membership(context.member, context.subject)

    replacement =
      Fixtures.Memberships.create_membership(
        account_id: context.provider.account_id,
        user_id: context.member.user_id
      )

    assert {:pending, refreshed} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert refreshed.id == reviewed.id
    assert refreshed.matched_membership_id == replacement.id

    assert SSO.approve_link_request(
             reviewed,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             context.subject
           ) ==
             {:error, :link_request_changed}

    assert is_nil(Repo.reload!(context.identity).membership_id)
    assert Repo.reload!(refreshed).matched_membership_id == replacement.id

    assert {:ok, %{identity: restored}} =
             SSO.approve_link_request(
               refreshed,
               Accounts.RunnerAccess.none(),
               context.provider.default_role,
               context.subject
             )

    assert restored.membership_id == replacement.id
  end

  test "recovery keeps permission and cross-account approval denials" do
    context = ambiguous_oidc_member()

    assert {:pending, request} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    viewer =
      Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), context.subject.account,
        role: :viewer
      )

    {_foreign_user, _foreign_account, foreign_subject} =
      Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             viewer
           ) ==
             {:error, :unauthorized}

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             foreign_subject
           ) ==
             {:error, :not_found}

    assert is_nil(Repo.reload!(context.identity).membership_id)
  end

  test "recovery refuses a target suspended after the pending request" do
    context = ambiguous_oidc_member()

    assert {:pending, request} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert {:ok, _suspended} = Accounts.suspend_membership(context.member, context.subject)

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             context.subject
           ) ==
             {:error, :matched_user_unavailable}

    assert Repo.reload!(context.member).disabled_at
    assert is_nil(Repo.reload!(context.identity).membership_id)
  end

  test "recovery refuses an identity already rebound since capture" do
    context = ambiguous_oidc_member()

    assert {:pending, request} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    Fixtures.SSO.bind_identity_membership(context.identity, context.member)

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             context.provider.default_role,
             context.subject
           ) ==
             {:error, :matched_user_unavailable}
  end

  test "ordinary recapture clears the recovery proof instead of inheriting it" do
    context = ambiguous_oidc_member()

    assert {:pending, recovery} =
             SSO.complete_auth(context.provider, %{"claims" => context.claims}, %{})

    assert {:ok, ordinary} =
             SSO.Provisioning.capture_link_request(
               context.provider,
               context.identity.provider_identifier,
               nil,
               nil,
               context.claims,
               :oidc
             )

    assert ordinary.id == recovery.id
    assert is_nil(ordinary.recovery_identity_id)
    assert is_nil(Repo.reload!(ordinary).recovery_identity_id)
    assert is_nil(ordinary.matched_membership_id)
    assert is_nil(Repo.reload!(context.identity).membership_id)
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

    assert SSO.approve_link_request(
             request,
             Accounts.RunnerAccess.none(),
             provider.default_role,
             subject
           ) ==
             {:error, :matched_user_unavailable}

    assert Repo.reload!(identity).membership_id == member.id
    assert Repo.reload!(request)

    assert {:pending, fresh} = SSO.complete_auth(provider, %{"claims" => claims}, %{})
    assert fresh.id == request.id
    assert {:ok, persisted} = SSO.fetch_pending_link_request(fresh.id)
    assert persisted.matched_membership_id == replacement.id
    assert fresh.matched_membership_id == replacement.id

    assert {:ok, %{identity: linked}} =
             SSO.approve_link_request(
               fresh,
               Accounts.RunnerAccess.none(),
               provider.default_role,
               subject
             )

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
