defmodule Emisar.AuthMemberGrantsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, RequestContext, SSO}

  defp personal_session(user) do
    assert {:ok, %{token_id: id, nonce: nonce, delivery: {:ok, :sent}}} =
             Auth.request_magic_link(user, %RequestContext{})

    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)
    assert {:ok, verified_user} = Auth.verify_magic_link(id, code, nonce)

    assert {:ok, _user, raw, :no_target, false} =
             Auth.complete_magic_link_sign_in(verified_user.id, id, nil, %RequestContext{})

    assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)
    {raw, session}
  end

  describe "session_grant_account_ids/1" do
    test "fences include only persisted destinations, without acquiring a later membership" do
      {user, original_account, _subject} = Fixtures.Subjects.owner_subject()
      {_raw, session} = personal_session(user)

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(user, original_account.id, session)

      later_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: later_account.id, user_id: user.id)

      assert Accounts.fetch_membership_by_account_id_or_slug(user, later_account.id, session) ==
               {:error, :not_found}

      assert Auth.session_grant_account_ids(session.id) == [original_account.id]
      assert Auth.session_grant_account_ids(Ecto.UUID.generate()) == []
      assert Auth.session_grant_account_ids("invalid") == []
      assert Auth.session_grant_account_ids(nil) == []
    end
  end

  describe "session_membership_ids/2" do
    test "freezes both existing personal destinations and rejects absent or foreign proof" do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()
      sibling = Fixtures.Accounts.create_account()

      sibling_member =
        Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)

      original_member = Fixtures.Memberships.fetch_membership(account.id, user.id)
      outsider = Fixtures.Users.create_user()
      {raw, session} = personal_session(user)

      assert Enum.sort(Auth.session_membership_ids(user.id, session)) ==
               Enum.sort([original_member.id, sibling_member.id])

      assert Auth.session_membership_ids(user.id, nil) == []
      assert Auth.session_membership_ids(outsider.id, session) == []

      assert :ok = Auth.complete_session_sign_out(raw)
      assert Auth.session_membership_ids(user.id, session) == []
    end

    test "a new same-issuer identity never expands an existing SSO bearer" do
      user = Fixtures.Users.create_user()
      origin = Fixtures.Accounts.create_account(plan: "team")
      sibling = Fixtures.Accounts.create_account(plan: "team")
      Fixtures.Memberships.create_membership(account_id: origin.id, user_id: user.id)
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)
      provider = Fixtures.SSO.create_identity_provider(account_id: origin.id)

      sibling_provider =
        Fixtures.SSO.create_identity_provider(account_id: sibling.id, issuer: provider.issuer)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: origin.id,
          provider_id: provider.id,
          user_id: user.id
        )

      assert {:ok, raw, false} =
               Auth.complete_sso_account_sign_in(user, origin.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

      Fixtures.SSO.create_user_identity(
        account_id: sibling.id,
        provider_id: sibling_provider.id,
        user_id: user.id
      )

      assert Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, session) ==
               {:error, :not_found}
    end
  end

  describe "session_subject_options/2" do
    test "same-issuer destinations keep their own proof-time MFA policy after the origin is retired" do
      {_owner, origin, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      user = Fixtures.Users.create_user()
      sibling = Fixtures.Accounts.create_account(plan: "team")
      original = Fixtures.Memberships.create_membership(account_id: origin.id, user_id: user.id)
      target = Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)

      provider =
        Fixtures.SSO.create_identity_provider(account_id: origin.id, satisfies_mfa: false)

      sibling_provider =
        Fixtures.SSO.create_identity_provider(
          account_id: sibling.id,
          issuer: provider.issuer,
          satisfies_mfa: true
        )

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: origin.id,
          provider_id: provider.id,
          user_id: user.id
        )

      destination =
        Fixtures.SSO.create_user_identity(
          account_id: sibling.id,
          provider_id: sibling_provider.id,
          user_id: user.id
        )

      assert {:ok, raw, false} =
               Auth.complete_sso_account_sign_in(user, origin.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)
      refute Auth.session_subject_options(original, session)[:mfa]
      options = Auth.session_subject_options(target, session)
      assert options[:mfa]
      assert options[:user_identity_id] == destination.id
      assert options[:session_token_id] == session.id

      assert {:ok, _disabled} = SSO.update_provider(provider, %{enabled: false}, owner_subject)
      assert Auth.session_subject_options(original, session) == []
      assert Auth.session_subject_options(target, session) == options
    end

    test "a later trust increase does not retroactively count an old login as MFA" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      user = Fixtures.Users.create_user()
      member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      assert {:ok, raw, false} =
               Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, _provider} =
               SSO.update_provider(provider, %{satisfies_mfa: true}, owner_subject)

      refute Auth.session_subject_options(member, session)[:mfa]
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      held = Fixtures.Subjects.subject_for(user, account, session: session)
      assert Accounts.ensure_account_compliant(account, held) == {:error, :mfa_required}

      assert {:ok, fresh_raw, true} =
               Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, fresh} = Auth.fetch_user_and_token_by_session_token(fresh_raw)
      current = Fixtures.Subjects.subject_for(user, account, session: fresh)
      assert Accounts.ensure_account_compliant(account, current) == :ok
    end

    test "retiring a direct MFA route does not promote its surviving inferred alternative" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      user = Fixtures.Users.create_user()
      member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      direct = Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

      inferred =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :openid_connect,
          issuer: direct.issuer,
          satisfies_mfa: false
        )

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: direct.id,
          user_id: user.id
        )

      alternative =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: inferred.id,
          user_id: user.id
        )

      assert {:ok, raw, true} =
               Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)
      assert Auth.session_subject_options(member, session)[:mfa]
      assert {:ok, _disabled} = SSO.update_provider(direct, %{enabled: false}, owner_subject)

      assert {:ok, _trusted} =
               SSO.update_provider(inferred, %{satisfies_mfa: true}, owner_subject)

      options = Auth.session_subject_options(member, session)
      assert options[:auth_method] == :sso
      assert options[:user_identity_id] == alternative.id
      refute options[:mfa]
    end

    test "an unbound weaker destination provider prevents inferred MFA without expanding access" do
      user = Fixtures.Users.create_user()
      origin = Fixtures.Accounts.create_account(plan: "team")
      destination = Fixtures.Accounts.create_account(plan: "team")
      Fixtures.Memberships.create_membership(account_id: origin.id, user_id: user.id)

      member =
        Fixtures.Memberships.create_membership(account_id: destination.id, user_id: user.id)

      provider = Fixtures.SSO.create_identity_provider(account_id: origin.id, satisfies_mfa: true)

      target =
        Fixtures.SSO.create_identity_provider(
          account_id: destination.id,
          issuer: provider.issuer,
          satisfies_mfa: true
        )

      Fixtures.SSO.create_identity_provider(
        account_id: destination.id,
        kind: :openid_connect,
        issuer: provider.issuer,
        satisfies_mfa: false
      )

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: origin.id,
          provider_id: provider.id,
          user_id: user.id
        )

      Fixtures.SSO.create_user_identity(
        account_id: destination.id,
        provider_id: target.id,
        user_id: user.id
      )

      assert {:ok, raw, true} =
               Auth.complete_sso_account_sign_in(user, origin.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(user, destination.id, session)

      refute Auth.session_subject_options(member, session)[:mfa]
    end
  end

  describe "ensure_personal_session/1" do
    test "requires live independent proof, not a forged method or workspace role" do
      {user, account, _owner} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      {raw, session} = personal_session(user)
      personal = Fixtures.Subjects.subject_for(user, account, session: session)
      assert Auth.ensure_personal_session(personal) == :ok
      assert Auth.ensure_personal_session(%{personal | auth_method: :sso}) == :ok
      assert Auth.complete_session_sign_out(raw) == :ok
      assert Auth.ensure_personal_session(personal) == {:error, :unauthorized}

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      sso =
        Fixtures.Subjects.subject_for(user, account,
          auth_method: :sso,
          user_identity_id: identity.id
        )

      assert Auth.ensure_personal_session(sso) == {:error, :unauthorized}

      assert Auth.ensure_personal_session(%{sso | auth_method: :magic_link, mfa: true}) ==
               {:error, :unauthorized}
    end
  end

  describe "delete_membership_session_grants/2" do
    test "workspace session revocation preserves the bearer and its other workspace" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      {user, other_account, _subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      {raw, held_session} = personal_session(user)

      assert :ok = Accounts.end_all_sessions_for(member, owner_subject)
      assert {:ok, _user, live_session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, _other_member} =
               Accounts.fetch_membership_by_account_id_or_slug(
                 user,
                 other_account.id,
                 live_session
               )

      assert Accounts.fetch_membership_by_account_id_or_slug(user, account.id, held_session) ==
               {:error, :not_found}
    end

    test "suspending an SSO origin preserves a prequalified same-issuer sibling" do
      {_owner, origin, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      user = Fixtures.Users.create_user()

      origin_member =
        Fixtures.Memberships.create_membership(account_id: origin.id, user_id: user.id)

      sibling = Fixtures.Accounts.create_account(plan: "team")
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)
      provider = Fixtures.SSO.create_identity_provider(account_id: origin.id)

      sibling_provider =
        Fixtures.SSO.create_identity_provider(account_id: sibling.id, issuer: provider.issuer)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: origin.id,
          provider_id: provider.id,
          user_id: user.id
        )

      Fixtures.SSO.create_user_identity(
        account_id: sibling.id,
        provider_id: sibling_provider.id,
        user_id: user.id
      )

      assert {:ok, raw, false} =
               Auth.complete_sso_account_sign_in(user, origin.id, %RequestContext{},
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, session)

      assert {:ok, _suspended} = Accounts.suspend_membership(origin_member, owner_subject)
      assert {:ok, _user, remaining_session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(
                 user,
                 sibling.id,
                 remaining_session
               )

      assert Accounts.fetch_membership_by_account_id_or_slug(user, origin.id, session) ==
               {:error, :not_found}

      assert {:ok, _active} = Accounts.reinstate_membership(origin_member, owner_subject)

      assert Accounts.fetch_membership_by_account_id_or_slug(user, origin.id, session) ==
               {:error, :not_found}
    end
  end

  test "provider retirement removes only its frozen destination proof, without revoking the bearer" do
    {owner, origin, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
    user = Fixtures.Users.create_user()
    sibling = Fixtures.Accounts.create_account(plan: "team")
    Fixtures.Memberships.create_membership(account_id: origin.id, user_id: user.id)
    Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)
    provider = Fixtures.SSO.create_identity_provider(account_id: origin.id)

    sibling_provider =
      Fixtures.SSO.create_identity_provider(account_id: sibling.id, issuer: provider.issuer)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: origin.id,
        provider_id: provider.id,
        user_id: user.id
      )

    Fixtures.SSO.create_user_identity(
      account_id: sibling.id,
      provider_id: sibling_provider.id,
      user_id: user.id
    )

    assert {:ok, raw, false} =
             Auth.complete_sso_account_sign_in(user, origin.id, %RequestContext{},
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             )

    assert {:ok, disabled} = SSO.update_provider(provider, %{enabled: false}, owner_subject)
    assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

    assert {:ok, _member} =
             Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, session)

    assert Accounts.fetch_membership_by_account_id_or_slug(user, origin.id, session) ==
             {:error, :not_found}

    verified = Fixtures.SSO.verify_provider_sign_in(disabled, owner)
    assert {:ok, _enabled} = SSO.update_provider(verified, %{enabled: true}, owner_subject)

    assert Accounts.fetch_membership_by_account_id_or_slug(user, origin.id, session) ==
             {:error, :not_found}
  end
end
