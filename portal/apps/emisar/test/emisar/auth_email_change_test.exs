defmodule Emisar.AuthEmailChangeTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Auth, Crypto, Fixtures, Mail, Repo, RequestContext, Users}
  alias Emisar.Auth.UserToken

  setup do
    {user, account, _subject} = Fixtures.Subjects.owner_subject()
    raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    {:ok, session} = Auth.fetch_session_by_token(raw)
    subject = Fixtures.Subjects.subject_for(user, account, session: session)

    %{
      user: user,
      account: account,
      subject: subject,
      raw: raw,
      digest: Crypto.hash(raw)
    }
  end

  describe "complete_email_change/5" do
    test "a retained session cannot inherit an invitation through an unproved new address", %{
      user: user,
      raw: raw,
      digest: digest,
      subject: subject
    } do
      victim_email = Fixtures.Random.unique_email()
      {proof, code, mail} = pending_change(digest, subject, victim_email)
      assert mail.to == [{"", victim_email}]
      assert Repo.reload!(user).email == user.email
      assert Users.fetch_user_by_email(victim_email) == {:error, :not_found}

      {_owner, target, target_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, invitation} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: victim_email, role: "operator"),
                 target_subject
               )

      assert {:ok, _} =
               Accounts.accept_invitation(
                 invitation.membership,
                 invitation.invitation_token,
                 %{display_name: "Mailbox Owner"}
               )

      assert {:ok, retained_token} =
               Auth.fetch_session_by_token(raw)

      assert Accounts.fetch_membership_by_account_id_or_slug(
               target.id,
               retained_token
             ) ==
               {:error, :not_found}

      # Even the new mailbox owner cannot accidentally complete an unsolicited
      # request by opening an email link: there is no link or browser nonce in it.
      refute mail.text_body =~ "/confirm/"
      refute mail.text_body =~ proof.nonce

      assert Auth.complete_email_change(
               proof.token_id,
               "missing-browser-nonce",
               code,
               digest,
               subject
             ) ==
               {:error, :invalid}
    end

    test "both proofs change and confirm exactly once, without publishing the address early", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject, "new@example.test")
      before = Repo.reload!(user)
      assert before.email == user.email
      assert before.confirmed_at == user.confirmed_at
      assert before.email_changed_at == user.email_changed_at

      assert {:ok, changed} = complete(proof, code, digest, subject)
      assert changed.email == "new@example.test"
      assert changed.confirmed_at
      assert changed.email_changed_at != before.email_changed_at
      assert {:error, :invalid} = complete(proof, code, digest, subject)
      refute Repo.get(UserToken, proof.token_id)
    end

    test "wrong guesses persist and the code cannot be used without its nonce", %{
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)
      wrong = if code == "AAAAAA", do: "BBBBBB", else: "AAAAAA"
      assert {:error, :invalid} = complete(proof, wrong, digest, subject)
      assert Repo.get!(UserToken, proof.token_id).remaining_attempts == 4
      assert {:error, :invalid} = complete(%{proof | nonce: "wrong"}, code, digest, subject)
      assert Repo.get!(UserToken, proof.token_id).remaining_attempts == 3
      assert {:ok, _changed} = complete(proof, code, digest, subject)
    end

    test "another session's digest and another user cannot finish the request", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)
      second_raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:error, :session_not_found} =
               complete(proof, code, Crypto.hash(second_raw), subject)

      {_other, _account, other_subject} = Fixtures.Subjects.owner_subject()
      {:ok, other_session} = Auth.fetch_current_session(other_subject)

      assert {:error, :invalid} =
               complete(proof, code, other_session.token, other_subject)

      assert {:ok, _changed} = complete(proof, code, digest, subject)
    end

    test "revoking the initiating session fences a still-mounted browser", %{
      user: user,
      raw: raw,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)
      assert :ok = Auth.delete_session_token(raw)
      assert {:error, :unauthorized} = complete(proof, code, digest, subject)
      assert Repo.reload!(user).email == user.email
    end

    test "a workspace SSO session is not a personal authorizing session", %{
      user: user,
      subject: subject
    } do
      sso_raw = Fixtures.Auth.create_session_token!(user, :sso, nil)
      {:ok, sso_session} = Auth.fetch_session_by_token(sso_raw)
      sso_subject = %{subject | session_token_id: sso_session.id}
      assert {:ok, :code} = Auth.begin_email_change("new@example.test", subject)
      assert_received {:email, mail}
      code = Fixtures.Auth.code_from_email(mail)

      assert Auth.confirm_email_change(
               "new@example.test",
               code,
               Crypto.hash(sso_raw),
               sso_subject
             ) ==
               {:error, :unauthorized}

      assert Repo.reload!(user).email == user.email
      refute_received {:email, _}
    end

    test "expired and exhausted proofs leave the original address usable", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {expired, code, _mail} = pending_change(digest, subject)

      Fixtures.Auth.backdate_token_inserted_at!(
        expired.token_id,
        DateTime.add(DateTime.utc_now(), -16, :minute)
      )

      assert {:error, :invalid} = complete(expired, code, digest, subject)

      {exhausted, code, _mail} = pending_change(digest, subject)
      wrong = if code == "AAAAAA", do: "BBBBBB", else: "AAAAAA"
      for _ <- 1..5, do: assert({:error, :invalid} = complete(exhausted, wrong, digest, subject))
      assert {:error, :invalid} = complete(exhausted, code, digest, subject)
      assert Repo.reload!(user).email == user.email
    end

    test "another token purpose cannot authorize the new address", %{
      raw: raw,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)
      assert {:ok, session} = Auth.fetch_session_by_token(raw)
      assert {:error, :invalid} = complete(%{proof | token_id: session.id}, code, digest, subject)

      assert {:error, :invalid} =
               complete(%{proof | token_id: "not-a-uuid"}, code, digest, subject)

      assert {:ok, _changed} = complete(proof, code, digest, subject)
    end

    test "new MFA enrollment after old-inbox proof requires restarting", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)

      Fixtures.Users.set_mfa_state(user,
        mfa_secret: Auth.generate_mfa_secret(),
        mfa_enabled_at: DateTime.utc_now()
      )

      assert {:error, :invalid} = complete(proof, code, digest, subject)
      assert Repo.reload!(user).email == user.email
    end

    test "MFA proof preserves enrollment and recovery codes, but a rotated enrollment invalidates it",
         %{digest: digest, subject: subject} do
      secret = Auth.generate_mfa_secret()
      {enrolled, _recovery} = Fixtures.Users.enable_mfa!(secret, subject)
      assert {:ok, :totp} = Auth.begin_email_change("new@example.test", subject)

      assert {:ok, proof} =
               Auth.confirm_email_change(
                 "new@example.test",
                 NimbleTOTP.verification_code(secret),
                 digest,
                 subject
               )

      assert_received {:email, mail}
      code = Fixtures.Auth.code_from_email(mail)
      after_factor = Repo.reload!(enrolled)
      assert after_factor.mfa_last_used_at

      # The old factor remains the authority, even if an unrelated name changes.
      assert {:ok, _} = Users.update_user_profile(%{full_name: "Updated Name"}, subject)
      assert {:ok, changed} = complete(proof, code, digest, subject)
      assert changed.mfa_enabled_at == enrolled.mfa_enabled_at
      assert changed.mfa_secret == enrolled.mfa_secret
      assert changed.mfa_recovery_codes == enrolled.mfa_recovery_codes
      assert changed.mfa_last_used_at == after_factor.mfa_last_used_at

      changed |> Ecto.Changeset.change(mfa_last_used_at: nil) |> Repo.update!()

      assert {:ok, next_proof} =
               Auth.confirm_email_change(
                 "another@example.test",
                 NimbleTOTP.verification_code(secret),
                 digest,
                 subject
               )

      assert_received {:email, next_mail}

      Fixtures.Users.set_mfa_state(changed,
        mfa_enabled_at: DateTime.add(changed.mfa_enabled_at, 1, :second)
      )

      assert {:error, :invalid} =
               complete(next_proof, Fixtures.Auth.code_from_email(next_mail), digest, subject)
    end

    test "suppressed or failed new-address delivery leaves the current address unchanged", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {:ok, _} = Mail.suppress("bounced@example.test", :hard_bounce, "test bounce")

      for {address, expected} <- [
            {"bounced@example.test", {:error, :delivery_suppressed}},
            {"failed@example.test", {:error, {:failed, :test_delivery}}}
          ] do
        assert {:ok, :code} = Auth.begin_email_change(address, subject)
        assert_received {:email, old_mail}

        if address == "failed@example.test" do
          Emisar.Config.put_override(
            :emisar,
            :mailer_deliver_error,
            {:error, {:failed, :test_delivery}}
          )
        end

        assert Auth.confirm_email_change(
                 address,
                 Fixtures.Auth.code_from_email(old_mail),
                 digest,
                 subject
               ) == expected

        assert Repo.reload!(user).email == user.email
        refute_received {:email, _}
      end
    end

    test "a competing confirmed owner rejects final completion without consuming proof or changing credentials",
         %{user: user, raw: raw, digest: digest, subject: subject} do
      {proof, code, _mail} = pending_change(digest, subject, "claimed@example.test")
      Fixtures.Users.create_user(email: "claimed@example.test")
      assert {:error, changeset} = complete(proof, code, digest, subject)
      assert "has already been taken" in errors_on(changeset).email
      assert Repo.reload!(user).email == user.email
      assert Repo.get(UserToken, proof.token_id)
      assert {:ok, _session} = Auth.fetch_session_by_token(raw)
    end

    test "a final audit failure rolls back address, confirmation and token consumption", %{
      user: user,
      digest: digest,
      subject: subject
    } do
      {proof, code, _mail} = pending_change(digest, subject)
      bad_subject = %{subject | context: %RequestContext{request_id: %{invalid: true}}}
      assert {:error, changeset} = complete(proof, code, digest, bad_subject)
      assert "is invalid" in errors_on(changeset).request_id
      assert Repo.reload!(user).email == user.email
      assert Repo.get(UserToken, proof.token_id)
      assert {:ok, _changed} = complete(proof, code, digest, subject)
    end

    test "a newer request replaces the pending proof", %{digest: digest, subject: subject} do
      {first, first_code, _mail} = pending_change(digest, subject, "first@example.test")
      {second, second_code, _mail} = pending_change(digest, subject, "second@example.test")
      assert {:error, :invalid} = complete(first, first_code, digest, subject)

      assert {:ok, %{email: "second@example.test"}} =
               complete(second, second_code, digest, subject)
    end
  end

  defp pending_change(digest, subject, address \\ "new@example.test") do
    assert {:ok, :code} = Auth.begin_email_change(address, subject)
    assert_received {:email, old_mail}

    assert {:ok, proof} =
             Auth.confirm_email_change(
               address,
               Fixtures.Auth.code_from_email(old_mail),
               digest,
               subject
             )

    assert_received {:email, new_mail}
    {proof, Fixtures.Auth.code_from_email(new_mail), new_mail}
  end

  defp complete(proof, code, digest, subject) do
    Auth.complete_email_change(
      proof.token_id,
      proof.nonce,
      code,
      digest,
      subject
    )
  end
end
