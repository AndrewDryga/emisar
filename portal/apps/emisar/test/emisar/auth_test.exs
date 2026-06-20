defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Auth
  alias Emisar.Users.User

  @password "a-password-of-some-length"

  describe "fetch_user_by_email_and_password/2" do
    test "returns the user with a correct password" do
      user = user_fixture(password: @password)
      assert {:ok, %User{id: id}} = Auth.fetch_user_by_email_and_password(user.email, @password)
      assert id == user.id
    end

    test "returns :not_found for the wrong password" do
      user = user_fixture(password: @password)

      assert {:error, :not_found} =
               Auth.fetch_user_by_email_and_password(user.email, "definitely-wrong")
    end

    test "returns :not_found for an unknown email" do
      assert {:error, :not_found} =
               Auth.fetch_user_by_email_and_password("no-one@example.test", @password)
    end
  end

  describe "session tokens" do
    test "create + lookup round-trip" do
      user = user_fixture()
      token = Auth.create_session_token!(user, :password, false)
      assert is_binary(token)

      assert {:ok, %User{id: id}, %{auth_method: :password, mfa: false, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "session provenance round-trips on lookup" do
      user = user_fixture()
      token = Auth.create_session_token!(user, :password, true)

      assert {:ok, %User{}, %{auth_method: :password, mfa: true, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "delete_session_token invalidates the token" do
      user = user_fixture()
      token = Auth.create_session_token!(user, :password, false)
      :ok = Auth.delete_session_token(token)
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a session past its validity window no longer resolves" do
      user = user_fixture()
      token = Auth.create_session_token!(user, :password, false)

      {1, _} =
        Emisar.Auth.UserToken.Query.by_user_id(user.id)
        |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -61, :day)])

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "magic link" do
    test "issued token can be consumed once" do
      user = user_fixture()
      raw = Auth.issue_magic_link_token!(user)

      assert {:ok, %User{id: id}} = Auth.consume_magic_link_token(raw)
      assert id == user.id

      # Single-use — second attempt fails.
      assert {:error, :invalid_or_expired} = Auth.consume_magic_link_token(raw)
    end

    test "garbage token returns invalid_or_expired" do
      assert {:error, :invalid_or_expired} = Auth.consume_magic_link_token("not-a-real-token")
    end

    test "a link whose user was deleted no longer works" do
      user = user_fixture()
      raw = Auth.issue_magic_link_token!(user)

      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :invalid_or_expired} = Auth.consume_magic_link_token(raw)
    end
  end

  describe "password reset" do
    test "reset_user_password swaps the hash and invalidates sessions" do
      user = user_fixture(password: @password)
      session_token = Auth.create_session_token!(user, :password, false)
      raw = Auth.issue_password_reset_token!(user)
      new_password = "brand-new-password-x"

      assert {:ok, %User{} = updated} = Auth.reset_user_password(raw, new_password)
      assert updated.id == user.id

      # New password works, old does not.
      assert {:ok, %User{}} = Auth.fetch_user_by_email_and_password(user.email, new_password)
      assert {:error, :not_found} = Auth.fetch_user_by_email_and_password(user.email, @password)

      # Existing session was nuked.
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(session_token)
    end

    test "garbage token returns invalid_or_expired" do
      assert {:error, :invalid_or_expired} = Auth.reset_user_password("nope", "doesnt-matter-xx")
    end
  end

  describe "email confirmation" do
    test "issue + consume marks the user confirmed" do
      user = user_fixture(confirmed?: false)
      refute user.confirmed_at

      raw = Auth.issue_confirmation_token!(user)
      assert {:ok, %User{confirmed_at: ts}} = Auth.confirm_user_by_token(raw)
      assert %DateTime{} = ts
    end

    test "garbage token returns invalid_or_expired" do
      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token("not-a-real-token")
    end
  end

  describe "MFA" do
    test "generate_mfa_secret returns a binary suitable for NimbleTOTP" do
      secret = Auth.generate_mfa_secret()
      assert is_binary(secret)
      assert byte_size(secret) > 0
    end

    test "enable_mfa with the correct OTP persists the secret + returns recovery codes" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      # enroll_mfa calls Auth.enable_mfa with a single retry across the 30s-window
      # straddle (code-gen vs validation), so this success-contract assertion can't
      # flake on a microsecond boundary.
      assert {:ok, %User{mfa_secret: ^secret, mfa_enabled_at: %DateTime{}} = updated, codes} =
               enroll_mfa(secret, subject)

      assert is_list(codes) and length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
      # The stored set is the digests, not the plaintext.
      assert length(updated.mfa_recovery_codes) == 10
      refute Enum.any?(codes, &(&1 in updated.mfa_recovery_codes))
    end

    test "enable_mfa with the wrong OTP returns :invalid_otp" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      assert {:error, :invalid_otp} = Auth.enable_mfa(secret, "000000", subject)
    end

    test "verify_mfa accepts a valid OTP once and rejects an immediate replay" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = enable_mfa!(secret, subject)

      otp = NimbleTOTP.verification_code(secret)
      assert :ok = Auth.verify_mfa(user, otp)

      user = Repo.reload!(user)
      assert {:error, :replay} = Auth.verify_mfa(user, otp)
    end

    test "verify_mfa rejects an invalid OTP" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa(user, "000000")
    end

    test "an OTP can't complete sign-in after MFA was disabled mid-verify (MAJOR-4)" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()
      # `user` is the pre-disable snapshot — it still carries the live secret +
      # mfa_enabled_at, exactly the stale struct a sign-in attempt would hold.
      {user, _codes} = enable_mfa!(secret, subject)
      otp = NimbleTOTP.verification_code(secret)

      {:ok, _} = Auth.disable_mfa(subject)

      # The old code validated against the stale struct's secret and would pass;
      # the locked verify reads the CURRENT row (MFA now disabled) and refuses.
      assert {:error, :invalid} = Auth.verify_mfa(user, otp)
    end

    test "an OTP for a rotated secret can't complete sign-in (MAJOR-4)" do
      {_user, _account, subject} = owner_subject_fixture()
      secret1 = Auth.generate_mfa_secret()
      {user, _codes} = enable_mfa!(secret1, subject)
      otp1 = NimbleTOTP.verification_code(secret1)

      # Rotate the secret out from under the in-flight verify (disable + re-enable).
      {:ok, _} = Auth.disable_mfa(subject)
      secret2 = Auth.generate_mfa_secret()
      {_user2, _codes} = enable_mfa!(secret2, subject)

      # `user` + `otp1` are for the OLD secret; the locked verify validates
      # against the current secret2 and refuses.
      assert {:error, :invalid} = Auth.verify_mfa(user, otp1)
    end

    test "consume_mfa_recovery_code accepts a fresh code once, rejects reuse" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      {user, [code | _]} = enable_mfa!(secret, subject)

      assert :ok = Auth.consume_mfa_recovery_code(user, code)

      user = Repo.reload!(user)
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, code)
    end

    test "disable_mfa clears the secret, enabled-at, and recovery codes" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      {_user, _codes} = enable_mfa!(secret, subject)

      assert {:ok, %User{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(subject)
    end

    test "regenerate_mfa_recovery_codes issues a fresh set and invalidates the old" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      {:ok, _user, [old_code | _]} =
        Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      assert {:ok, %User{mfa_enabled_at: %DateTime{}} = user, new_codes} =
               Auth.regenerate_mfa_recovery_codes(subject)

      assert length(new_codes) == 10
      # MFA stays enabled; the old plaintext code no longer matches, a new one does.
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, old_code)
      assert :ok = Auth.consume_mfa_recovery_code(Repo.reload!(user), hd(new_codes))
    end
  end

  describe "session revocation (self-service)" do
    setup do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      %{user: user, subject: subject_for(user, account, role: :owner)}
    end

    test "revoke_session removes one of the caller's own sessions by id", %{
      user: user,
      subject: subject
    } do
      _t1 = Auth.create_session_token!(user, :password, false)
      _t2 = Auth.create_session_token!(user, :password, false)
      {:ok, [session | _], _} = Auth.list_sessions_for_user(subject)

      assert :ok = Auth.revoke_session(session.id, subject)
      {:ok, remaining, _} = Auth.list_sessions_for_user(subject)
      assert length(remaining) == 1
    end

    test "revoke_session can't kill another user's session — scoped to the caller", %{
      subject: subject
    } do
      other_account = account_fixture()
      other = user_fixture()
      _ = membership_fixture(account_id: other_account.id, user_id: other.id, role: "owner")
      other_subject = subject_for(other, other_account, role: :owner)
      _ = Auth.create_session_token!(other, :password, false)
      {:ok, [other_session], _} = Auth.list_sessions_for_user(other_subject)

      assert {:error, :not_found} = Auth.revoke_session(other_session.id, subject)
      # Still alive for its real owner.
      assert {:ok, [_], _} = Auth.list_sessions_for_user(other_subject)
    end

    test "revoke_session with a non-uuid id is a clean :not_found", %{subject: subject} do
      assert {:error, :not_found} = Auth.revoke_session("not-a-uuid", subject)
    end

    test "revoke_and_disconnect_other_sessions! keeps only the current session", %{
      user: user,
      subject: subject
    } do
      keep = Auth.create_session_token!(user, :password, false)
      _other1 = Auth.create_session_token!(user, :password, false)
      _other2 = Auth.create_session_token!(user, :password, false)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 2

      {:ok, remaining, _} = Auth.list_sessions_for_user(subject)
      assert length(remaining) == 1
      assert {:ok, %User{}, _auth} = Auth.fetch_user_and_token_by_session_token(keep)
    end
  end
end
