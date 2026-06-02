defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Auth
  alias Emisar.Accounts.User

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
      token = Auth.create_session_token!(user)
      assert is_binary(token)
      assert {:ok, %User{id: id}} = Auth.fetch_user_by_session_token(token)
      assert id == user.id
    end

    test "delete_session_token invalidates the token" do
      user = user_fixture()
      token = Auth.create_session_token!(user)
      :ok = Auth.delete_session_token(token)
      assert {:error, :not_found} = Auth.fetch_user_by_session_token(token)
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
  end

  describe "password reset" do
    test "reset_user_password swaps the hash and invalidates sessions" do
      user = user_fixture(password: @password)
      session_token = Auth.create_session_token!(user)
      raw = Auth.issue_password_reset_token!(user)
      new_password = "brand-new-password-x"

      assert {:ok, %User{} = updated} = Auth.reset_user_password(raw, new_password)
      assert updated.id == user.id

      # New password works, old does not.
      assert {:ok, %User{}} = Auth.fetch_user_by_email_and_password(user.email, new_password)
      assert {:error, :not_found} = Auth.fetch_user_by_email_and_password(user.email, @password)

      # Existing session was nuked.
      assert {:error, :not_found} = Auth.fetch_user_by_session_token(session_token)
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
      user = user_fixture()
      secret = Auth.generate_mfa_secret()
      otp = NimbleTOTP.verification_code(secret)

      assert {:ok, %User{mfa_secret: ^secret, mfa_enabled_at: %DateTime{}} = updated, codes} =
               Auth.enable_mfa(user, secret, otp)

      assert is_list(codes) and length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
      # The stored set is the digests, not the plaintext.
      assert length(updated.mfa_recovery_codes) == 10
      refute Enum.any?(codes, &(&1 in updated.mfa_recovery_codes))
    end

    test "enable_mfa with the wrong OTP returns :invalid_otp" do
      user = user_fixture()
      secret = Auth.generate_mfa_secret()

      assert {:error, :invalid_otp} = Auth.enable_mfa(user, secret, "000000")
    end

    test "verify_mfa accepts a valid OTP once and rejects an immediate replay" do
      user = user_fixture()
      secret = Auth.generate_mfa_secret()
      {:ok, user, _codes} = Auth.enable_mfa(user, secret, NimbleTOTP.verification_code(secret))

      otp = NimbleTOTP.verification_code(secret)
      assert :ok = Auth.verify_mfa(user, otp)

      user = Repo.reload!(user)
      assert {:error, :replay} = Auth.verify_mfa(user, otp)
    end

    test "verify_mfa rejects an invalid OTP" do
      user = user_fixture()
      secret = Auth.generate_mfa_secret()
      {:ok, user, _codes} = Auth.enable_mfa(user, secret, NimbleTOTP.verification_code(secret))

      assert {:error, :invalid} = Auth.verify_mfa(user, "000000")
    end

    test "consume_mfa_recovery_code accepts a fresh code once, rejects reuse" do
      user = user_fixture()
      secret = Auth.generate_mfa_secret()

      {:ok, user, [code | _]} =
        Auth.enable_mfa(user, secret, NimbleTOTP.verification_code(secret))

      assert :ok = Auth.consume_mfa_recovery_code(user, code)

      user = Repo.reload!(user)
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, code)
    end
  end
end
