defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Auth
  alias Emisar.Auth.UserToken
  alias Emisar.Users.User

  @password "a-password-of-some-length"

  # Backdate every user_token row so its `inserted_at` lands `minutes` in
  # the past — the only lever on the validity window, since
  # `UserToken.Query.not_expired/2` filters `inserted_at > ago(window)`.
  # Lets a TTL test place a token just inside vs just past its window.
  defp age_tokens(user_id, minutes) do
    {n, _} =
      UserToken.Query.by_user_id(user_id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -minutes, :minute)])

    n
  end

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

    # 15-minute window (magic_link).
    test "a link just inside 15 minutes still consumes" do
      user = user_fixture()
      raw = Auth.issue_magic_link_token!(user)
      age_tokens(user.id, 14)

      assert {:ok, %User{id: id}} = Auth.consume_magic_link_token(raw)
      assert id == user.id
    end

    test "a link just past 15 minutes no longer consumes" do
      user = user_fixture()
      raw = Auth.issue_magic_link_token!(user)
      age_tokens(user.id, 16)

      assert {:error, :invalid_or_expired} = Auth.consume_magic_link_token(raw)
    end
  end

  describe "split-code magic link" do
    test "verifies with both halves and is single-use" do
      user = user_fixture()
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id

      # Single-use — the token is deleted on success.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "the email half alone can't sign in — a wrong nonce is rejected (anti-hijack)" do
      user = user_fixture()
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      # An intercepted email gives token_id + secret but NOT the originating
      # browser's nonce → the core anti-hijack guarantee: no sign-in.
      assert {:error, :invalid_or_expired} =
               Auth.verify_magic_link(token_id, secret, "wrong-nonce")

      # …and the real browser still signs in — one wrong attempt only spent one
      # of the budget, it didn't burn the token.
      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id
    end

    test "a token past the 15-minute window no longer verifies" do
      user = user_fixture()
      {token_id, nonce, secret} = Auth.issue_magic_link(user)
      age_tokens(user.id, 16)

      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "five wrong attempts lock the token — even the correct half then fails" do
      user = user_fixture()
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      # Burn all five attempts (a wrong nonce always mismatches the high-entropy one).
      for _ <- 1..5 do
        assert {:error, :invalid_or_expired} =
                 Auth.verify_magic_link(token_id, secret, "wrong-nonce")
      end

      # Locked: the correct (nonce, secret) no longer works.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "issuing again replaces the prior outstanding token (single outstanding)" do
      user = user_fixture()
      {token_id1, nonce1, secret1} = Auth.issue_magic_link(user)
      {token_id2, nonce2, secret2} = Auth.issue_magic_link(user)

      # The first token is gone — re-issuing deleted it.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id1, secret1, nonce1)
      assert {:ok, %User{}} = Auth.verify_magic_link(token_id2, secret2, nonce2)
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

    # 1-day window (reset_password).
    test "a reset token just inside 1 day still resets" do
      user = user_fixture(password: @password)
      raw = Auth.issue_password_reset_token!(user)
      # 1 day minus 5 minutes still inside the window.
      age_tokens(user.id, 24 * 60 - 5)

      assert {:ok, %User{}} = Auth.reset_user_password(raw, "brand-new-password-y")
    end

    test "a reset token just past 1 day no longer resets" do
      user = user_fixture(password: @password)
      raw = Auth.issue_password_reset_token!(user)
      # 1 day plus 5 minutes is past the window.
      age_tokens(user.id, 24 * 60 + 5)

      assert {:error, :invalid_or_expired} = Auth.reset_user_password(raw, "brand-new-password-y")
    end

    # the 12..128 password rule on the
    # reset path (Users.reset_user_password -> User.Changeset.password).
    test "accepts a 12-char and a 128-char new password" do
      for length <- [12, 128] do
        user = user_fixture(password: @password)
        raw = Auth.issue_password_reset_token!(user)

        assert {:ok, %User{}} = Auth.reset_user_password(raw, String.duplicate("a", length))
      end
    end

    test "rejects an 11-char and a 129-char new password without consuming the token" do
      for length <- [11, 129] do
        user = user_fixture(password: @password)
        raw = Auth.issue_password_reset_token!(user)

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Auth.reset_user_password(raw, String.duplicate("a", length))

        assert changeset.errors[:password]
        # The token is not burnt — a valid-length retry on the SAME link works.
        assert {:ok, %User{}} = Auth.reset_user_password(raw, "valid-length-pass-12")
      end
    end

    # closes the remaining soft-delete row at the context.
    test "a reset link whose user was soft-deleted no longer resets" do
      user = user_fixture(password: @password)
      raw = Auth.issue_password_reset_token!(user)

      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :invalid_or_expired} = Auth.reset_user_password(raw, "brand-new-password-y")
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

    # 7-day window (confirm).
    test "a confirm token just inside 7 days still confirms" do
      user = user_fixture(confirmed?: false)
      raw = Auth.issue_confirmation_token!(user)
      # 7 days minus an hour is still inside the window.
      age_tokens(user.id, 7 * 24 * 60 - 60)

      assert {:ok, %User{confirmed_at: %DateTime{}}} = Auth.confirm_user_by_token(raw)
    end

    test "a confirm token just past 7 days no longer confirms" do
      user = user_fixture(confirmed?: false)
      raw = Auth.issue_confirmation_token!(user)
      # 7 days plus an hour is past the window.
      age_tokens(user.id, 7 * 24 * 60 + 60)

      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token(raw)
    end

    # closes the soft-delete row at the context.
    test "a confirm link whose user was soft-deleted no longer confirms" do
      user = user_fixture(confirmed?: false)
      raw = Auth.issue_confirmation_token!(user)

      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token(raw)
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

    # a non-numeric OTP is rejected, and because the
    # replay guard only stamps on a *valid* code, the real code still works
    # right after (the bad attempt didn't burn the current bucket).
    test "verify_mfa rejects a non-numeric OTP without burning the live code" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa(user, "abcdef")

      # The genuine current code is untouched by the failed attempt.
      assert :ok = Auth.verify_mfa(Repo.reload!(user), NimbleTOTP.verification_code(secret))
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

    # (sequential single-use; true-concurrent is out of
    # scope) — a recovery code consumes once; a second consume of the SAME
    # code fails, while a sibling code from the set is unaffected.
    test "consume_mfa_recovery_code accepts a fresh code once, rejects reuse" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()

      {user, [code, other_code | _]} = enable_mfa!(secret, subject)

      assert :ok = Auth.consume_mfa_recovery_code(user, code)

      user = Repo.reload!(user)
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, code)

      # Consuming one code doesn't invalidate the rest of the set.
      assert :ok = Auth.consume_mfa_recovery_code(user, other_code)
    end

    # recovery codes are shown once in plaintext, and
    # only their SHA-256 digests are persisted (never the plaintext).
    test "recovery codes are stored as SHA-256 digests, never plaintext" do
      {_user, _account, subject} = owner_subject_fixture()
      secret = Auth.generate_mfa_secret()
      {user, codes} = enable_mfa!(secret, subject)

      # Each plaintext code's stored form is exactly its SHA-256 digest.
      assert Enum.all?(codes, &(Emisar.Crypto.hash(&1) in user.mfa_recovery_codes))
      # And no plaintext leaks into the at-rest set.
      refute Enum.any?(codes, &(&1 in user.mfa_recovery_codes))
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
