defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Fixtures
  alias Emisar.Users.User

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

  describe "create_session_token!/5" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "mints a raw session token that round-trips on lookup", %{user: user} do
      token = Auth.create_session_token!(user, :magic_link, false)
      assert is_binary(token)

      assert {:ok, %User{id: id}, %{auth_method: :magic_link, mfa: false, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "stamps the auth_method + mfa provenance onto the row", %{user: user} do
      token = Auth.create_session_token!(user, :magic_link, true)

      assert {:ok, %User{}, %{auth_method: :magic_link, mfa: true, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "metadata's ip + user_agent ride onto the row for the device list", %{user: user} do
      token =
        Auth.create_session_token!(user, :magic_link, false, %{
          ip_address: "203.0.113.9",
          user_agent: "ExUnit/1.0"
        })

      {:ok, _user, %UserToken{} = stored} = Auth.fetch_user_and_token_by_session_token(token)
      # ip + user_agent ride in the token's `metadata` jsonb (string-keyed once persisted).
      assert stored.metadata["ip_address"] == "203.0.113.9"
      assert stored.metadata["user_agent"] == "ExUnit/1.0"
    end
  end

  describe "fetch_user_and_token_by_session_token/1" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "resolves a live session to {:ok, user, token}", %{user: user} do
      token = Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, %User{id: id}, %UserToken{context: "session"}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "an unknown or non-binary token is :not_found, never a crash", %{user: _user} do
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token("nope")
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token("")
    end

    test "a session past its validity window no longer resolves", %{user: user} do
      token = Auth.create_session_token!(user, :magic_link, false)
      # 61 days is past the 60-day session window.
      age_tokens(user.id, 61 * 24 * 60)

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a soft-deleted user's token reads as :not_found (preload scoped to live users)", %{
      user: user
    } do
      token = Auth.create_session_token!(user, :magic_link, false)
      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "delete_session_token/1" do
    test "drops the session row backing the cookie" do
      user = Fixtures.Users.create_user()
      token = Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.delete_session_token(token)
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "deleting an unknown token is an idempotent :ok" do
      assert :ok = Auth.delete_session_token("never-existed")
    end
  end

  describe "record_sign_out/2" do
    test "audits user.signed_out attributed to the user" do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()

      assert :ok = Auth.record_sign_out(user)

      {:ok, events, _} =
        Emisar.Audit.list_events(
          Fixtures.Subjects.subject_for(user, account, role: :owner),
          filter: [event_type: ["user.signed_out"]]
        )

      assert [event] = events
      assert event.actor_id == user.id
    end
  end

  describe "record_failed_sign_in/3" do
    test "audits on a KNOWN email, landing on that user's account" do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()

      assert :ok = Auth.record_failed_sign_in(user.email, "bad_credentials")

      {:ok, events, _} =
        Emisar.Audit.list_events(
          Fixtures.Subjects.subject_for(user, account, role: :owner),
          filter: [event_type: ["user.sign_in_failed"]]
        )

      assert [event] = events
      assert event.actor_id == user.id
      assert event.payload["reason"] == "bad_credentials"
    end

    test "silently drops an UNKNOWN email (anti-enumeration) — no crash" do
      # An unknown email must not be auditable anywhere, or an attacker could
      # enumerate accounts by watching their own org's log; the contract is the
      # quiet :ok.
      assert :ok =
               Auth.record_failed_sign_in("ghost-#{System.unique_integer()}@nowhere.test", "x")
    end

    test "a non-binary email is the catch-all :ok" do
      assert :ok = Auth.record_failed_sign_in(nil, "x")
    end
  end

  describe "delete_all_session_tokens/1" do
    test "removes every session token for the user and returns the count" do
      user = Fixtures.Users.create_user()
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, 2} = Auth.delete_all_session_tokens(user)

      subject =
        Fixtures.Subjects.subject_for(user, Fixtures.Accounts.create_account(), role: :owner)

      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end

    test "only touches the given user's sessions" do
      user = Fixtures.Users.create_user()
      other = Fixtures.Users.create_user()
      _ = Auth.create_session_token!(user, :magic_link, false)
      keep = Auth.create_session_token!(other, :magic_link, false)

      assert {:ok, 1} = Auth.delete_all_session_tokens(user)
      # The other user's session is untouched.
      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(keep)
    end
  end

  describe "disconnect_and_revoke_all_sessions/1" do
    test "revokes every session for the user (and best-effort disconnects sockets)" do
      user = Fixtures.Users.create_user()
      t1 = Auth.create_session_token!(user, :magic_link, false)
      t2 = Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.disconnect_and_revoke_all_sessions(user)

      # Both cookies are now dead — the DB rows are gone.
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(t1)
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(t2)
    end
  end

  describe "revoke_and_disconnect_other_sessions!/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "keeps only the current session and returns the revoked count", %{
      user: user,
      subject: subject
    } do
      keep = Auth.create_session_token!(user, :magic_link, false)
      _other1 = Auth.create_session_token!(user, :magic_link, false)
      _other2 = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 2

      {:ok, remaining, _} = Auth.list_sessions_for_user(subject)
      assert length(remaining) == 1
      # The kept cookie still resolves.
      assert {:ok, %User{}, _auth} = Auth.fetch_user_and_token_by_session_token(keep)
    end

    test "with only the current session, revokes nothing", %{user: user, subject: subject} do
      keep = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 0
      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(keep)
    end
  end

  describe "broadcast_disconnect_for_user/2" do
    # In the `:emisar`-only test process the `:session_disconnect_handler`
    # (which lives in `emisar_web`) isn't configured, so this is a pure,
    # best-effort no-op that must not raise or touch token rows — its
    # observable contract here is the `:ok` and that the DB is untouched.
    test "is a best-effort :ok that deletes no token rows" do
      user = Fixtures.Users.create_user()
      token = Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.broadcast_disconnect_for_user(user)
      assert :ok = Auth.broadcast_disconnect_for_user(user, except: Crypto.hash(token))

      # The session is still alive — broadcasting disconnects sockets, never rows.
      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "live_socket_topic/1" do
    test "builds the per-session topic off the token digest" do
      digest = Crypto.hash("a-raw-token")

      assert Auth.live_socket_topic(digest) ==
               "users_sessions:#{Crypto.encode_digest(digest)}"
    end

    test "the same digest always yields the same topic (server-derivable)" do
      digest = Crypto.hash("stable")
      assert Auth.live_socket_topic(digest) == Auth.live_socket_topic(digest)
    end
  end

  describe "live_socket_topic_for_session/1" do
    test "derives the same topic from the RAW token as live_socket_topic/1 does from its digest" do
      raw = "raw-session-token"

      assert Auth.live_socket_topic_for_session(raw) ==
               Auth.live_socket_topic(Crypto.hash(raw))
    end
  end

  describe "list_sessions_for_user/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "returns the caller's session rows, newest-first", %{user: user, subject: subject} do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "only the subject's own session-context tokens (not the pending magic-link)", %{
      user: user,
      subject: subject
    } do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.issue_magic_link(user)
      _ = Auth.create_session_token!(Fixtures.Users.create_user(), :magic_link, false)

      assert {:ok, [token], _meta} = Auth.list_sessions_for_user(subject)
      assert token.context == "session"
    end
  end

  describe "revoke_session/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "removes one of the caller's own sessions by id", %{user: user, subject: subject} do
      _t1 = Auth.create_session_token!(user, :magic_link, false)
      _t2 = Auth.create_session_token!(user, :magic_link, false)
      {:ok, [session | _], _} = Auth.list_sessions_for_user(subject)

      assert :ok = Auth.revoke_session(session.id, subject)
      {:ok, remaining, _} = Auth.list_sessions_for_user(subject)
      assert length(remaining) == 1
    end

    test "can't kill another user's session — scoped to the caller", %{subject: subject} do
      {other, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      _ = Auth.create_session_token!(other, :magic_link, false)
      {:ok, [other_session], _} = Auth.list_sessions_for_user(other_subject)

      assert {:error, :not_found} = Auth.revoke_session(other_session.id, subject)
      # Still alive for its real owner.
      assert {:ok, [_], _} = Auth.list_sessions_for_user(other_subject)
    end

    test "a non-uuid id is a clean :not_found (no DB touch)", %{subject: subject} do
      assert {:error, :not_found} = Auth.revoke_session("not-a-uuid", subject)
    end
  end

  describe "revoke_other_sessions!/3" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "keeps the named session, revokes the rest", %{user: user, subject: subject} do
      keep = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, keep) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(subject)
      assert survivor.token == Crypto.hash(keep)
    end

    test "with nil, kills every session including the caller's", %{user: user, subject: subject} do
      _ = Auth.create_session_token!(user, :magic_link, false)
      _ = Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(subject)
    end
  end

  describe "issue_magic_link/2" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "returns {token_id, nonce, secret} that verifies back to the user", %{user: user} do
      {token_id, nonce, secret} = Auth.issue_magic_link(user)
      assert is_binary(token_id) and is_binary(nonce)
      # The emailed half is a typable 6-digit code.
      assert secret =~ ~r/^\d{6}$/

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id
    end

    test "issuing again replaces the prior outstanding token (single outstanding)", %{user: user} do
      {token_id1, nonce1, secret1} = Auth.issue_magic_link(user)
      {token_id2, nonce2, secret2} = Auth.issue_magic_link(user)

      # The first token is gone — re-issuing deleted it.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id1, secret1, nonce1)
      assert {:ok, %User{}} = Auth.verify_magic_link(token_id2, secret2, nonce2)
    end
  end

  describe "verify_magic_link/4" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "verifies with both halves and is single-use", %{user: user} do
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id

      # Single-use — the token is deleted on success.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "the email half alone can't sign in — a wrong nonce is rejected (anti-hijack)", %{
      user: user
    } do
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

    test "a token past the 15-minute window no longer verifies", %{user: user} do
      {token_id, nonce, secret} = Auth.issue_magic_link(user)
      age_tokens(user.id, 16)

      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "five wrong attempts lock the token — even the correct half then fails", %{user: user} do
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      # Burn all five attempts (a wrong nonce always mismatches the high-entropy one).
      for _ <- 1..5 do
        assert {:error, :invalid_or_expired} =
                 Auth.verify_magic_link(token_id, secret, "wrong-nonce")
      end

      # Locked: the correct (nonce, secret) no longer works.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end
  end

  describe "issue_email_change_code/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "emails a 6-digit code to the CURRENT address, bound to the new email", %{
      user: user,
      subject: subject
    } do
      current = user.email

      assert :ok = Auth.issue_email_change_code("new@example.com", subject)

      assert_received {:email, email}
      assert [{_, ^current}] = email.to
      assert email.subject =~ "email change"
      assert [code] = Regex.run(~r/\d{6}/, email.text_body)

      # The bound code confirms and hands back the new email.
      assert {:ok, "new@example.com"} = Auth.verify_email_change_code(code, subject)
    end

    test "issuing again replaces the prior code (single outstanding)", %{subject: subject} do
      :ok = Auth.issue_email_change_code("first@example.com", subject)
      assert_received {:email, first_email}
      [first_code] = Regex.run(~r/\d{6}/, first_email.text_body)

      :ok = Auth.issue_email_change_code("second@example.com", subject)
      assert_received {:email, _second_email}

      # The first code is gone; only the latest issuance verifies.
      assert {:error, :invalid} = Auth.verify_email_change_code(first_code, subject)
    end
  end

  describe "verify_email_change_code/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "the right code returns the bound email and is single-use", %{subject: subject} do
      :ok = Auth.issue_email_change_code("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      assert {:ok, "new@example.com"} = Auth.verify_email_change_code(code, subject)
      # Consumed — a second verify of the same code fails.
      assert {:error, :invalid} = Auth.verify_email_change_code(code, subject)
    end

    test "a wrong code is rejected and spends an attempt; the right one still works", %{
      subject: subject
    } do
      :ok = Auth.issue_email_change_code("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      assert {:error, :invalid} = Auth.verify_email_change_code("000000", subject)
      assert {:ok, "new@example.com"} = Auth.verify_email_change_code(code, subject)
    end

    test "the code locks after the attempt budget is spent", %{subject: subject} do
      :ok = Auth.issue_email_change_code("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      for _ <- 1..5,
          do: assert({:error, :invalid} = Auth.verify_email_change_code("000000", subject))

      # Budget spent → even the right code no longer loads a token.
      assert {:error, :invalid} = Auth.verify_email_change_code(code, subject)
    end

    test "an expired code is rejected", %{user: user, subject: subject} do
      :ok = Auth.issue_email_change_code("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      age_tokens(user.id, 16)
      assert {:error, :invalid} = Auth.verify_email_change_code(code, subject)
    end

    test "verifying with no outstanding code is rejected", %{subject: subject} do
      assert {:error, :invalid} = Auth.verify_email_change_code("123456", subject)
    end
  end

  describe "issue_confirmation_token!/1" do
    test "mints a raw confirm token that confirms the user" do
      user = Fixtures.Users.create_user(confirmed?: false)
      refute user.confirmed_at

      raw = Auth.issue_confirmation_token!(user)
      assert is_binary(raw)

      assert {:ok, %User{confirmed_at: %DateTime{}}} = Auth.confirm_user_by_token(raw)
    end
  end

  describe "deliver_confirmation_instructions/1" do
    test "issues a fresh token, emails the confirm link, and returns :ok" do
      user = Fixtures.Users.create_user(confirmed?: false)

      assert :ok = Auth.deliver_confirmation_instructions(user)

      assert_received {:email, email}
      assert [{_, to}] = email.to
      assert to == user.email
      assert email.subject =~ "Confirm"
    end
  end

  describe "confirm_user_by_token/2" do
    setup do
      %{user: Fixtures.Users.create_user(confirmed?: false)}
    end

    test "issue + consume marks the user confirmed", %{user: user} do
      refute user.confirmed_at

      raw = Auth.issue_confirmation_token!(user)
      assert {:ok, %User{confirmed_at: ts}} = Auth.confirm_user_by_token(raw)
      assert %DateTime{} = ts
    end

    test "a garbage token returns invalid_or_expired" do
      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token("not-a-real-token")
    end

    # 7-day window (confirm).
    test "a confirm token just inside 7 days still confirms", %{user: user} do
      raw = Auth.issue_confirmation_token!(user)
      # 7 days minus an hour is still inside the window.
      age_tokens(user.id, 7 * 24 * 60 - 60)

      assert {:ok, %User{confirmed_at: %DateTime{}}} = Auth.confirm_user_by_token(raw)
    end

    test "a confirm token just past 7 days no longer confirms", %{user: user} do
      raw = Auth.issue_confirmation_token!(user)
      # 7 days plus an hour is past the window.
      age_tokens(user.id, 7 * 24 * 60 + 60)

      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token(raw)
    end

    # A soft-deleted user behind a live token is the same dead-link outcome.
    test "a confirm link whose user was soft-deleted no longer confirms", %{user: user} do
      raw = Auth.issue_confirmation_token!(user)

      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :invalid_or_expired} = Auth.confirm_user_by_token(raw)
    end
  end

  describe "enable_mfa/3" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "with the correct OTP persists the secret + returns recovery codes", %{
      secret: secret,
      subject: subject
    } do
      # Fixtures.Users.enroll_mfa calls Auth.enable_mfa with a single retry across the 30s-window
      # straddle (code-gen vs validation), so this success-contract assertion can't
      # flake on a microsecond boundary.
      assert {:ok, %User{mfa_secret: ^secret, mfa_enabled_at: %DateTime{}} = updated, codes} =
               Fixtures.Users.enroll_mfa(secret, subject)

      assert is_list(codes) and length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
      # The stored set is the digests, not the plaintext.
      assert length(updated.mfa_recovery_codes) == 10
      refute Enum.any?(codes, &(&1 in updated.mfa_recovery_codes))
    end

    test "with the wrong OTP returns :invalid_otp (nothing persisted)", %{
      secret: secret,
      subject: subject
    } do
      assert {:error, :invalid_otp} = Auth.enable_mfa(secret, "000000", subject)
    end

    # recovery codes are shown once in plaintext, and only their SHA-256
    # digests are persisted (never the plaintext).
    test "recovery codes are stored as SHA-256 digests, never plaintext", %{
      secret: secret,
      subject: subject
    } do
      {user, codes} = Fixtures.Users.enable_mfa!(secret, subject)

      # Each plaintext code's stored form is exactly its SHA-256 digest.
      assert Enum.all?(codes, &(Crypto.hash(&1) in user.mfa_recovery_codes))
      # And no plaintext leaks into the at-rest set.
      refute Enum.any?(codes, &(&1 in user.mfa_recovery_codes))
    end
  end

  describe "disable_mfa/1" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "clears the secret, enabled-at, and recovery codes", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:ok, %User{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(subject)
    end
  end

  describe "regenerate_mfa_recovery_codes/1" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "issues a fresh set and invalidates the old (MFA stays enabled)", %{
      secret: secret,
      subject: subject
    } do
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

  describe "mfa_required?/1" do
    test "false for a user with MFA not enabled" do
      refute Auth.mfa_required?(%User{mfa_enabled_at: nil})
    end

    test "true once mfa_enabled_at is set" do
      assert Auth.mfa_required?(%User{mfa_enabled_at: DateTime.utc_now()})
    end
  end

  describe "verify_mfa/3" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "accepts a valid OTP once and rejects an immediate replay", %{
      secret: secret,
      subject: subject
    } do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      otp = NimbleTOTP.verification_code(secret)
      assert :ok = Auth.verify_mfa(user, otp)

      user = Repo.reload!(user)
      assert {:error, :replay} = Auth.verify_mfa(user, otp)
    end

    test "rejects an invalid OTP", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa(user, "000000")
    end

    test "a non-binary OTP is the catch-all :invalid" do
      assert {:error, :invalid} = Auth.verify_mfa(%User{}, nil)
    end

    # a non-numeric OTP is rejected, and because the replay guard only stamps
    # on a *valid* code, the real code still works right after (the bad attempt
    # didn't burn the current bucket).
    test "rejects a non-numeric OTP without burning the live code", %{
      secret: secret,
      subject: subject
    } do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa(user, "abcdef")

      # The genuine current code is untouched by the failed attempt.
      assert :ok = Auth.verify_mfa(Repo.reload!(user), NimbleTOTP.verification_code(secret))
    end

    test "an OTP can't complete sign-in after MFA was disabled mid-verify (MAJOR-4)", %{
      secret: secret,
      subject: subject
    } do
      # `user` is the pre-disable snapshot — it still carries the live secret +
      # mfa_enabled_at, exactly the stale struct a sign-in attempt would hold.
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      otp = NimbleTOTP.verification_code(secret)

      {:ok, _} = Auth.disable_mfa(subject)

      # The old code validated against the stale struct's secret and would pass;
      # the locked verify reads the CURRENT row (MFA now disabled) and refuses.
      assert {:error, :invalid} = Auth.verify_mfa(user, otp)
    end

    test "an OTP for a rotated secret can't complete sign-in (MAJOR-4)", %{subject: subject} do
      secret1 = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret1, subject)
      otp1 = NimbleTOTP.verification_code(secret1)

      # Rotate the secret out from under the in-flight verify (disable + re-enable).
      {:ok, _} = Auth.disable_mfa(subject)
      secret2 = Auth.generate_mfa_secret()
      {_user2, _codes} = Fixtures.Users.enable_mfa!(secret2, subject)

      # `user` + `otp1` are for the OLD secret; the locked verify validates
      # against the current secret2 and refuses.
      assert {:error, :invalid} = Auth.verify_mfa(user, otp1)
    end
  end

  describe "consume_mfa_recovery_code/3" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    # (sequential single-use; true-concurrent is out of scope) — a recovery
    # code consumes once; a second consume of the SAME code fails, while a
    # sibling code from the set is unaffected.
    test "accepts a fresh code once, rejects reuse, leaves siblings valid", %{
      secret: secret,
      subject: subject
    } do
      {user, [code, other_code | _]} = Fixtures.Users.enable_mfa!(secret, subject)

      assert :ok = Auth.consume_mfa_recovery_code(user, code)

      user = Repo.reload!(user)
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, code)

      # Consuming one code doesn't invalidate the rest of the set.
      assert :ok = Auth.consume_mfa_recovery_code(user, other_code)
    end

    test "rejects an unknown code as :invalid", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(user, "not-a-real-code")
    end

    test "a non-binary code is the catch-all :invalid" do
      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(%User{}, nil)
    end
  end

  describe "generate_mfa_secret/0" do
    test "returns a non-empty binary suitable for NimbleTOTP" do
      secret = Auth.generate_mfa_secret()
      assert is_binary(secret)
      assert byte_size(secret) > 0
    end
  end
end
