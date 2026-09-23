defmodule Emisar.AuthPersonalAuthorityTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Auth, Crypto, Fixtures, Repo, Users}
  alias Emisar.Auth.UserToken

  setup do
    {user, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
    raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    {:ok, token} = Auth.fetch_session_by_token(raw)

    %{
      user: user,
      account: account,
      subject: Fixtures.Subjects.subject_for(user, account, session: token),
      raw: raw,
      digest: Crypto.hash(raw),
      token: token
    }
  end

  defp nonpersonal_subject(personal, :sso) do
    provider =
      Fixtures.SSO.create_identity_provider(account_id: personal.account.id, satisfies_mfa: true)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: personal.account.id,
        provider_id: provider.id,
        user_id: personal.actor.id
      )

    Fixtures.Subjects.subject_for(personal.actor, personal.account,
      auth_method: :sso,
      user_identity_id: identity.id
    )
  end

  defp nonpersonal_subject(personal, nil) do
    raw = Fixtures.Auth.create_session_token!(personal.actor, nil, nil)
    {:ok, token} = Auth.fetch_session_by_token(raw)
    %{personal | session_token_id: token.id, member_grant_id: nil, auth_method: nil, mfa: true}
  end

  for method <- [:sso, nil] do
    @method method
    test "#{inspect(method)} provenance cannot inspect or change personal state", %{
      user: user,
      subject: personal,
      raw: raw,
      digest: digest,
      token: token
    } do
      # Neither an owner role nor an assurance stamp supplies personal authority.
      subject = nonpersonal_subject(personal, @method)
      assert Auth.Subject.ensure_personal_user(subject) == {:error, :unauthorized}

      assert Users.update_user_profile(%{full_name: "Workspace chosen"}, subject) ==
               {:error, :unauthorized}

      assert Auth.list_sessions_for_user(digest, subject) == {:error, :unauthorized}
      assert Auth.revoke_session(token.id, subject) == {:error, :unauthorized}
      assert Auth.revoke_and_disconnect_other_sessions(digest, subject) == {:error, :unauthorized}
      assert Auth.begin_email_change("other@example.test", subject) == {:error, :unauthorized}

      assert Auth.issue_email_change_code("other@example.test", subject) ==
               {:error, :unauthorized}

      assert Auth.confirm_email_change("other@example.test", "123456", digest, subject) ==
               {:error, :unauthorized}

      assert {:ok, %{user: ^user}} = Auth.fetch_session_by_token(raw)
      assert Repo.reload!(user).full_name == user.full_name
      assert Repo.aggregate(Auth.SecurityAttemptWindow, :count) == 0
      refute_received {:email, _}
    end
  end

  test "a pending proof cannot borrow a personal token through SSO or missing provenance", %{
    subject: personal,
    digest: digest
  } do
    assert {:ok, :code} = Auth.begin_email_change("other@example.test", personal)
    assert_received {:email, old_mail}

    assert {:ok, proof} =
             Auth.confirm_email_change(
               "other@example.test",
               Fixtures.Auth.code_from_email(old_mail),
               digest,
               personal
             )

    assert_received {:email, new_mail}
    code = Fixtures.Auth.code_from_email(new_mail)
    before = Repo.get!(UserToken, proof.token_id)

    for method <- [:sso, nil] do
      subject = nonpersonal_subject(personal, method)

      assert Auth.complete_email_change(proof.token_id, proof.nonce, code, digest, subject) ==
               {:error, :unauthorized}

      assert Repo.get!(UserToken, proof.token_id) == before
    end

    assert {:ok, changed} =
             Auth.complete_email_change(proof.token_id, proof.nonce, code, digest, personal)

    assert changed.email == "other@example.test"
  end

  test "a non-user credential cannot use personal self-service", %{
    account: account,
    token: token,
    digest: digest
  } do
    {_secret, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
    subject = Auth.Subject.for_api_key(key, account)

    assert Users.update_user_profile(%{full_name: "Key chosen"}, subject) ==
             {:error, :unauthorized}

    assert Auth.list_sessions_for_user(digest, subject) == {:error, :unauthorized}
    assert Auth.revoke_session(token.id, subject) == {:error, :unauthorized}
    assert Auth.revoke_and_disconnect_other_sessions(digest, subject) == {:error, :unauthorized}
    assert Auth.begin_email_change("other@example.test", subject) == {:error, :unauthorized}
    assert Auth.issue_email_change_code("other@example.test", subject) == {:error, :unauthorized}

    assert Auth.confirm_email_change("other@example.test", "123456", digest, subject) ==
             {:error, :unauthorized}

    assert Auth.complete_email_change(token.id, "nonce", "ABCDEF", digest, subject) ==
             {:error, :unauthorized}

    assert Repo.get!(UserToken, token.id)
    refute_received {:email, _}
  end

  test "independent MFA enrollment stays available to SSO without granting personal authority", %{
    user: user,
    account: account
  } do
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      })

    raw = Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)
    {:ok, sso_session} = Auth.fetch_session_by_token(raw)
    subject = Fixtures.Subjects.subject_for(user, account, session: sso_session)
    Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
    secret = Auth.generate_mfa_secret()
    {enrolled, codes} = Fixtures.Users.enable_mfa!(secret, subject, session_token: raw)
    assert codes != []
    assert {:ok, session} = Auth.fetch_session_by_token(raw)
    assert session.auth_method == :sso
    assert Auth.session_mfa_enrollment_verified_at(enrolled, session) == enrolled.mfa_enabled_at

    subject = %{
      subject
      | actor: enrolled,
        mfa: true,
        mfa_enrollment_verified_at: enrolled.mfa_enabled_at
    }

    assert Users.update_user_profile(%{full_name: "Workspace chosen"}, subject) ==
             {:error, :unauthorized}

    assert Auth.list_sessions_for_user(Crypto.hash(raw), subject) == {:error, :unauthorized}
    assert Auth.begin_email_change("other@example.test", subject) == {:error, :unauthorized}
  end
end
