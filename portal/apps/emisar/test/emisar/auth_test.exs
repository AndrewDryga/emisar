defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, Fixtures, Mail, RequestContext}
  alias Emisar.Auth.{SecurityAttemptWindow, UserToken}
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

  # The raw secret only leaves Auth by email, so a test that must complete a
  # sign-in drives the real request workflow and reads the 6-character code back
  # out of the delivered message — exactly as an operator does.
  defp request_magic_link(user, opts \\ []) do
    assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
             Auth.request_magic_link(user, %RequestContext{}, opts)

    assert_received {:email, sent}
    [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    {token_id, nonce, secret}
  end

  # A user-scoped audit row lands once per account the user belongs to, so read
  # the type straight off the table instead of through an account-scoped list.
  defp events_of_type(event_type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  describe "roles/0" do
    test "carries the assignable membership roles, most-privileged first" do
      assert Auth.roles() == [:owner, :admin, :billing_manager, :operator, :viewer]
    end
  end

  describe "role_label/1" do
    test "renders a role atom or string in its human form" do
      assert Auth.role_label(:owner) == "Owner"
      assert Auth.role_label(:billing_manager) == "Billing manager"
      assert Auth.role_label("billing_manager") == "Billing manager"
    end
  end

  describe "role_description/1" do
    test "describes a known role and stays nil for an unknown one" do
      assert Auth.role_description(:owner) ==
               "Full control of the workspace, including billing and adding or removing other owners."

      assert Auth.role_description("unknown") == nil
    end
  end

  describe "resolve_post_auth_account/2" do
    test "an unbranded sign-in has no target" do
      assert Auth.resolve_post_auth_account(Fixtures.Users.create_user(), nil) == :no_target
    end

    test "a live member lands on the branded account, by slug or id" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      account_id = account.id

      assert {:member, %Accounts.Account{id: ^account_id}} =
               Auth.resolve_post_auth_account(user, account.slug)

      assert {:member, %Accounts.Account{id: ^account_id}} =
               Auth.resolve_post_auth_account(user, account.id)
    end

    test "a member of a disabled account is routed to that account, not denied" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      Fixtures.Accounts.disable_account(account)
      account_id = account.id

      assert {:disabled, %Accounts.Account{id: ^account_id}} =
               Auth.resolve_post_auth_account(user, account.slug)
    end

    test "an unknown ref and a non-member's ref both refuse the same way" do
      member = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      outsider = Fixtures.Users.create_user()

      # Same `:not_member` either way — a branded sign-in never confirms a tenant
      # exists on the slug-probing path.
      assert Auth.resolve_post_auth_account(outsider, account.slug) == :not_member
      assert Auth.resolve_post_auth_account(outsider, "no-such-team") == :not_member
    end

    test "a stale membership — suspended or tombstoned — refuses too" do
      suspended_user = Fixtures.Users.create_user()
      deleted_user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      suspended_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: suspended_user.id
        )

      deleted_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: deleted_user.id)

      Fixtures.Memberships.suspend_membership(suspended_membership)
      Fixtures.Memberships.mark_membership_as_deleted(deleted_membership)

      assert Auth.resolve_post_auth_account(suspended_user, account.slug) == :not_member
      assert Auth.resolve_post_auth_account(deleted_user, account.slug) == :not_member
    end

    test "a soft-deleted account refuses even for its member" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Auth.resolve_post_auth_account(user, account.slug) == :not_member
      assert Auth.resolve_post_auth_account(user, account.id) == :not_member
    end

    test "a member of account A cannot land on account B" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)

      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        user_id: Fixtures.Users.create_user().id
      )

      assert Auth.resolve_post_auth_account(user, account_b.slug) == :not_member
      assert Auth.resolve_post_auth_account(user, account_b.id) == :not_member
    end
  end

  describe "complete_sso_account_sign_in/5" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject, user: user}
    end

    test "records the sign-in and mints an :sso session while the account is active", %{
      account: account,
      user: user
    } do
      context = RequestContext.new(%{ip_address: "203.0.113.9"})

      assert {:ok, token} = Auth.complete_sso_account_sign_in(user, account.id, true, context)

      assert {:ok, %User{id: id}, %UserToken{auth_method: :sso, mfa: true} = stored} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
      # ip + user_agent ride in the token's `metadata` jsonb (string-keyed once persisted).
      assert stored.metadata["ip_address"] == "203.0.113.9"
    end

    test "bounds session display metadata before persisting it", %{
      account: account,
      user: user
    } do
      context = RequestContext.new(%{user_agent: String.duplicate("x", 500)})

      assert {:ok, token} = Auth.complete_sso_account_sign_in(user, account.id, false, context)

      assert {:ok, _user, %UserToken{} = stored} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert String.length(stored.metadata["user_agent"]) == 255
    end

    test "does not mint a session after the account is disabled", %{
      account: account,
      subject: subject,
      user: user
    } do
      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "support incident",
                 subject
               )

      assert {:error, :account_disabled} =
               Auth.complete_sso_account_sign_in(user, account.id, false, %RequestContext{})

      refute Repo.one(UserToken.Query.by_context("session"))
    end
  end

  describe "fetch_user_and_token_by_session_token/1" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "resolves a live session to {:ok, user, token}", %{user: user} do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, %User{id: id}, %UserToken{context: "session"}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "an unknown or non-binary token is :not_found, never a crash", %{user: _user} do
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token("nope")
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token("")
    end

    test "a session past its validity window no longer resolves", %{user: user} do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      # 61 days is past the 60-day session window.
      age_tokens(user.id, 61 * 24 * 60)

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a soft-deleted user's token reads as :not_found (preload scoped to live users)", %{
      user: user
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      {:ok, _} = user |> User.Changeset.delete() |> Repo.update()

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a session holding a removed auth_method fails closed, never raising on load", %{
      user: user
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      # A legacy `password` session from before the passwordless rework dropped
      # that enum value. Written at the DB layer to bypass the enum cast —
      # exactly how it lands in a real DB after the enum narrows. Loading it
      # must resolve to :not_found, not raise ArgumentError and 500 the request.
      Ecto.Adapters.SQL.query!(Repo, "UPDATE auth_user_tokens SET auth_method = 'password'", [])

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "delete_session_token/1" do
    test "drops the session row backing the cookie" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.delete_session_token(token)
      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "deleting an unknown token is an idempotent :ok" do
      assert :ok = Auth.delete_session_token("never-existed")
    end

    test "writes no user.signed_out — a forced invalidation is not a sign-out" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.delete_session_token(token)
      assert events_of_type("user.signed_out") == []
    end
  end

  describe "complete_session_sign_out/2" do
    test "drops the presented session and audits it once, to the token's owner" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      context = RequestContext.new(%{ip_address: "203.0.113.7", user_agent: "Firefox"})

      assert :ok = Auth.complete_session_sign_out(token, context)

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
      assert [event] = events_of_type("user.signed_out")
      assert event.actor_id == user.id
      assert event.target_id == user.id
      assert event.ip_address == "203.0.113.7"
      assert event.user_agent == "Firefox"
    end

    test "an unknown token is an idempotent :ok that audits nothing" do
      assert :ok = Auth.complete_session_sign_out("never-existed")
      assert events_of_type("user.signed_out") == []
    end

    test "a failed audit rolls the token deletion back" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      # A non-string request_id fails the audit changeset, so the sign-out's one
      # transaction aborts — the browser must not be told it signed out.
      context = %RequestContext{request_id: %{invalid: true}}

      assert {:error, changeset} = Auth.complete_session_sign_out(token, context)
      assert "is invalid" in errors_on(changeset).request_id

      assert {:ok, %User{}, _token} = Auth.fetch_user_and_token_by_session_token(token)
      assert events_of_type("user.signed_out") == []
    end

    test "an expired session is swept without a voluntary sign-out audit" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      # 61 days is past the 60-day session window.
      age_tokens(user.id, 61 * 24 * 60)

      assert :ok = Auth.complete_session_sign_out(token)

      refute Repo.one(UserToken.Query.by_token_digest(Crypto.hash(token)))
      assert events_of_type("user.signed_out") == []
    end

    test "a session holding a removed auth_method is swept without an audit" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      Ecto.Adapters.SQL.query!(Repo, "UPDATE auth_user_tokens SET auth_method = 'password'", [])

      assert :ok = Auth.complete_session_sign_out(token)

      refute Repo.one(UserToken.Query.by_token_digest(Crypto.hash(token)))
      assert events_of_type("user.signed_out") == []
    end

    test "only the presented session ends — the user's other devices stay signed in" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      other_token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.complete_session_sign_out(token)

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(token)
      assert {:ok, %User{}, _token} = Auth.fetch_user_and_token_by_session_token(other_token)
    end
  end

  describe "delete_all_session_tokens/1" do
    test "removes every session token for the user and returns the count" do
      user = Fixtures.Users.create_user()
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, 2} = Auth.delete_all_session_tokens(user)

      subject =
        Fixtures.Subjects.subject_for(user, Fixtures.Accounts.create_account(), role: :owner)

      assert {:ok, [], _} = Auth.list_sessions_for_user(nil, subject)
    end

    test "only touches the given user's sessions" do
      user = Fixtures.Users.create_user()
      other = Fixtures.Users.create_user()
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      keep = Fixtures.Auth.create_session_token!(other, :magic_link, false)

      assert {:ok, 1} = Auth.delete_all_session_tokens(user)
      # The other user's session is untouched.
      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(keep)
    end
  end

  describe "revoke_identity_sessions/2" do
    test "kills only the sessions bound to those identities, disconnecting the rest" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      sso =
        Fixtures.Auth.create_session_token!(user, :sso, false, %{}, user_identity_id: identity.id)

      magic_link = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.revoke_identity_sessions(user, [identity.id])

      assert {:error, :not_found} = Auth.fetch_user_and_token_by_session_token(sso)
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(magic_link)
    end

    test "an empty identity list revokes nothing" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert :ok = Auth.revoke_identity_sessions(user, [])
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "disconnect_and_revoke_all_sessions/1" do
    test "revokes every session for the user (and best-effort disconnects sockets)" do
      user = Fixtures.Users.create_user()
      t1 = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      t2 = Fixtures.Auth.create_session_token!(user, :magic_link, false)

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
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _other1 = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _other2 = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 2

      {:ok, remaining, _} = Auth.list_sessions_for_user(nil, subject)
      assert length(remaining) == 1
      # The kept cookie still resolves.
      assert {:ok, %User{}, _auth} = Auth.fetch_user_and_token_by_session_token(keep)
    end

    test "with only the current session, revokes nothing", %{user: user, subject: subject} do
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, false)

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
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)

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

  describe "list_sessions_for_user/3" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "returns the caller's session rows, newest-first", %{user: user, subject: subject} do
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_user(nil, subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "only the subject's own session-context tokens (not the pending magic-link)", %{
      user: user,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      request_magic_link(user)
      Fixtures.Auth.create_session_token!(Fixtures.Users.create_user(), :magic_link, false)

      assert {:ok, [session], _meta} = Auth.list_sessions_for_user(token, subject)
      assert session.current?
    end
  end

  describe "revoke_session/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "removes one of the caller's own sessions by id", %{user: user, subject: subject} do
      _t1 = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _t2 = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      {:ok, [session | _], _} = Auth.list_sessions_for_user(nil, subject)

      assert :ok = Auth.revoke_session(session.id, subject)
      {:ok, remaining, _} = Auth.list_sessions_for_user(nil, subject)
      assert length(remaining) == 1
    end

    test "can't kill another user's session — scoped to the caller", %{subject: subject} do
      {other, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Auth.create_session_token!(other, :magic_link, false)
      {:ok, [other_session], _} = Auth.list_sessions_for_user(nil, other_subject)

      assert {:error, :not_found} = Auth.revoke_session(other_session.id, subject)
      # Still alive for its real owner.
      assert {:ok, [_], _} = Auth.list_sessions_for_user(nil, other_subject)
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
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, keep) == 2
      assert {:ok, [survivor], _} = Auth.list_sessions_for_user(keep, subject)
      assert survivor.current?
    end

    test "with nil, kills every session including the caller's", %{user: user, subject: subject} do
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, false)

      assert Auth.revoke_other_sessions!(user, nil) == 2
      assert {:ok, [], _} = Auth.list_sessions_for_user(nil, subject)
    end
  end

  describe "request_magic_link/3" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "hands back only the browser half, emails the code, and verifies", %{user: user} do
      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery} = result} =
               Auth.request_magic_link(user, %RequestContext{})

      # Three keys and no more: the raw secret stays inside Auth, so no caller
      # can relay a sign-in credential it didn't earn.
      assert map_size(result) == 3
      assert delivery == {:ok, :sent}
      assert is_binary(token_id) and is_binary(nonce)

      assert_received {:email, sent}
      assert [{_, email}] = sent.to
      assert email == user.email
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      # The emailed half is a typable 6-char alphanumeric code, from an
      # unambiguous uppercase alphabet — no 0/O, 1/I/L, or U to misread.
      refute secret =~ ~r/[01ILOU]/

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id
    end

    test "issuing again replaces the prior outstanding token (single outstanding)", %{user: user} do
      {token_id1, nonce1, secret1} = request_magic_link(user)
      {token_id2, nonce2, secret2} = request_magic_link(user)

      # The first token is gone — re-issuing deleted it.
      assert Auth.verify_magic_link(token_id1, secret1, nonce1) == {:error, :invalid_or_expired}
      assert {:ok, %User{}} = Auth.verify_magic_link(token_id2, secret2, nonce2)
    end

    test "a suppressed address is reported as suppressed and nothing is sent", %{user: user} do
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, %{delivery: {:ok, :suppressed}}} =
               Auth.request_magic_link(user, %RequestContext{})

      refute_received {:email, _}
      assert %UserToken{context: "magic_link"} = Repo.one(UserToken)
    end

    test "a mailer failure is reported while the token stays outstanding", %{user: user} do
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery}} =
               Auth.request_magic_link(user, %RequestContext{})

      assert delivery == {:error, {:failed, :boom}}
      # The browser half still comes back and the row survives, so a resend from
      # the sent page is the operator's remedy — not a lost, already-audited link.
      assert is_binary(token_id) and is_binary(nonce)
      assert %UserToken{id: ^token_id, context: "magic_link"} = Repo.one(UserToken)
    end

    test "a branded request issues for a live team", %{user: user} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{delivery: {:ok, :sent}}} =
               Auth.request_magic_link(user, %RequestContext{}, account_ref: account.slug)

      assert_received {:email, _sent}
    end

    test "a branded request for an unavailable team issues and sends nothing", %{user: user} do
      account = Fixtures.Accounts.create_account()
      {token_id, _nonce, _secret} = request_magic_link(user, account_ref: account.slug)
      Fixtures.Accounts.disable_account(account)

      assert Auth.request_magic_link(user, %RequestContext{}, account_ref: account.slug) ==
               {:error, :not_found}

      refute_received {:email, _}
      # The outstanding token is the one issued while the team was live — the
      # refused request minted nothing.
      assert %UserToken{id: ^token_id} = Repo.one(UserToken)
    end

    test "an unknown or malformed team ref issues and sends nothing", %{user: user} do
      assert Auth.request_magic_link(user, %RequestContext{}, account_ref: "no-such-team") ==
               {:error, :not_found}

      assert Auth.request_magic_link(user, %RequestContext{}, account_ref: %{"nested" => "ref"}) ==
               {:error, :not_found}

      refute_received {:email, _}
      refute Repo.one(UserToken)
    end
  end

  describe "correct_registration_email/4" do
    test "updates the pending unconfirmed user and emails a fresh link to it" do
      user = Fixtures.Users.create_user(confirmed?: false)
      {old_token_id, old_nonce, old_secret} = request_magic_link(user)
      new_email = "fixed-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %{token_id: new_token_id, nonce: new_nonce, delivery: delivery} = result} =
               Auth.correct_registration_email(old_token_id, user.id, new_email)

      # The same narrowed shape as a fresh request — no user struct, no secret.
      assert map_size(result) == 3
      assert delivery == {:ok, :sent}
      assert Repo.reload!(user).email == new_email

      assert_received {:email, sent}
      assert [{_, ^new_email}] = sent.to

      [_, ^new_token_id, new_secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      assert Auth.verify_magic_link(old_token_id, old_secret, old_nonce) ==
               {:error, :invalid_or_expired}

      assert {:ok, %User{id: id, email: ^new_email, confirmed_at: %DateTime{}}} =
               Auth.verify_magic_link(new_token_id, new_secret, new_nonce)

      assert id == user.id
    end

    test "refuses when the pending signup user has already confirmed" do
      user = Fixtures.Users.create_user()
      {token_id, _nonce, _secret} = request_magic_link(user)
      new_email = "late-#{System.unique_integer([:positive])}@example.test"

      assert Auth.correct_registration_email(token_id, user.id, new_email) ==
               {:error, :already_confirmed}

      assert Repo.reload!(user).email == user.email
    end

    test "rejects a token that was not minted for the registration user" do
      user = Fixtures.Users.create_user(confirmed?: false)
      other_user = Fixtures.Users.create_user(confirmed?: false)
      {token_id, _nonce, _secret} = request_magic_link(user)
      new_email = "hijack-#{System.unique_integer([:positive])}@example.test"

      assert Auth.correct_registration_email(token_id, other_user.id, new_email) ==
               {:error, :invalid_or_expired}

      assert Repo.reload!(user).email == user.email
    end

    test "rejects an expired or malformed token id" do
      new_email = "unused-#{System.unique_integer([:positive])}@example.test"
      registration_user_id = Repo.generate_id()

      assert Auth.correct_registration_email("not-a-uuid", registration_user_id, new_email) ==
               {:error, :invalid_or_expired}
    end
  end

  describe "magic_link_validity_in_minutes/0" do
    test "is the magic-link code's validity window in minutes" do
      assert Auth.magic_link_validity_in_minutes() == 15
    end
  end

  describe "verify_magic_link/4" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "verifies with both halves and is single-use", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id

      # Single-use — the token is deleted on success.
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}
    end

    test "the email half alone can't sign in — a wrong nonce is rejected (anti-hijack)", %{
      user: user
    } do
      {token_id, nonce, secret} = request_magic_link(user)

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
      {token_id, nonce, secret} = request_magic_link(user)
      age_tokens(user.id, 16)

      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end

    test "a malformed token id is invalid rather than a database cast error" do
      assert {:error, :invalid_or_expired} =
               Auth.verify_magic_link("not-a-uuid", "secret", "nonce")
    end

    test "five wrong attempts lock the token — even the correct half then fails", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)

      # Burn all five attempts (a wrong nonce always mismatches the high-entropy one).
      for _ <- 1..5 do
        assert {:error, :invalid_or_expired} =
                 Auth.verify_magic_link(token_id, secret, "wrong-nonce")
      end

      # Locked: the correct (nonce, secret) no longer works.
      assert {:error, :invalid_or_expired} = Auth.verify_magic_link(token_id, secret, nonce)
    end
  end

  describe "complete_magic_link_sign_in/3" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject, user: user}
    end

    test "an unbranded completion mints a magic_link session with no second factor", %{
      user: user
    } do
      assert {:ok, %User{} = signed_in, token, :no_target} =
               Auth.complete_magic_link_sign_in(user.id, nil, %RequestContext{})

      assert signed_in.id == user.id

      assert {:ok, %User{id: id}, %UserToken{auth_method: :magic_link, mfa: false}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    # The returned user carries the sign-in the minting transaction just stamped,
    # so a boundary that installs it can't render a pre-sign-in snapshot.
    test "the returned user is the row the sign-in stamped", %{user: user} do
      assert {:ok, signed_in, _token, :no_target} =
               Auth.complete_magic_link_sign_in(user.id, nil, %RequestContext{})

      refute user.last_sign_in_at
      assert %DateTime{} = signed_in.last_sign_in_at
    end

    test "a branded completion lands the member on that account", %{
      account: account,
      user: user
    } do
      assert {:ok, _user, token, {:member, landed}} =
               Auth.complete_magic_link_sign_in(user.id, account.slug, %RequestContext{})

      assert landed.id == account.id

      assert {:ok, _user, %UserToken{auth_method: :magic_link, mfa: false}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a branded completion for a non-member still signs them in, without the target", %{
      user: user
    } do
      other_account = Fixtures.Accounts.create_account()

      assert {:ok, _user, token, :not_member} =
               Auth.complete_magic_link_sign_in(user.id, other_account.slug, %RequestContext{})

      assert {:ok, _user, %UserToken{}} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "an enrollment made since the link was issued still owes a second factor", %{
      subject: subject,
      user: user
    } do
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_sign_in(user.id, nil, %RequestContext{}) ==
               {:error, :mfa_required}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a disabled branded account mints nothing and hands back the account", %{
      account: account,
      subject: subject,
      user: user
    } do
      {:ok, _account} =
        Accounts.set_account_disabled_for_support(account.id, true, "support incident", subject)

      assert {:error, {:account_disabled, disabled}} =
               Auth.complete_magic_link_sign_in(user.id, account.slug, %RequestContext{})

      assert disabled.id == account.id
      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a failed sign-in audit rolls the stamp and the session back", %{user: user} do
      # A non-string request_id fails the audit changeset, so the one minting
      # transaction aborts — no stamped sign-in, no session, no audit row.
      context = %RequestContext{request_id: %{invalid: true}}

      assert {:error, changeset} = Auth.complete_magic_link_sign_in(user.id, nil, context)
      assert "is invalid" in errors_on(changeset).request_id

      assert Repo.reload!(user).last_sign_in_at == user.last_sign_in_at
      refute Repo.one(UserToken.Query.by_context("session"))
      assert events_of_type("user.signed_in") == []
    end

    test "a user that no longer resolves is :not_found" do
      assert Auth.complete_magic_link_sign_in(Ecto.UUID.generate(), nil, %RequestContext{}) ==
               {:error, :not_found}
    end
  end

  describe "complete_magic_link_mfa_sign_in/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {user, codes} = Fixtures.Users.enable_mfa!(secret, subject)
      %{account: account, codes: codes, secret: secret, subject: subject, user: user}
    end

    test "a verified TOTP proof mints a magic_link session stamped mfa: true", %{
      secret: secret,
      user: user
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, %User{} = signed_in, token, :no_target} =
               Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{})

      assert signed_in.id == user.id

      assert {:ok, %User{id: id}, %UserToken{auth_method: :magic_link, mfa: true}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "a verified recovery-code proof mints the same session", %{
      codes: [code | _],
      user: user
    } do
      assert {:ok, proof} = Auth.verify_mfa_challenge(user, {:recovery_code, code})

      assert {:ok, _user, token, :no_target} =
               Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{})

      assert {:ok, _user, %UserToken{auth_method: :magic_link, mfa: true}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a completed proof cannot be replayed into a second session", %{
      secret: secret,
      user: user
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user, _token, :no_target} =
               Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{})

      assert Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{}) ==
               {:error, :mfa_proof_stale}

      # `Repo.one` raises on a second row, so this asserts the replay minted none.
      assert Repo.one(UserToken.Query.by_context("session"))
    end

    test "a branded completion lands the member on that account", %{
      account: account,
      secret: secret,
      user: user
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user, _token, {:member, landed}} =
               Auth.complete_magic_link_mfa_sign_in(proof, account.slug, %RequestContext{})

      assert landed.id == account.id
    end

    test "a proof no longer matches once MFA was disabled after the challenge", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      user: user
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user} = Auth.disable_mfa(code, subject)

      assert Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{}) ==
               {:error, :mfa_proof_stale}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a proof no longer matches once the secret was rotated (disable, re-enable)", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      user: user
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user} = Auth.disable_mfa(code, subject)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_mfa_sign_in(proof, nil, %RequestContext{}) ==
               {:error, :mfa_proof_stale}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "current user fields are not an MFA proof", %{user: user} do
      forged = %{
        user_id: user.id,
        mfa_enabled_at: user.mfa_enabled_at,
        updated_at: user.updated_at
      }

      assert Auth.complete_magic_link_mfa_sign_in(forged, nil, %RequestContext{}) ==
               {:error, :not_found}

      refute Repo.one(UserToken.Query.by_context("session"))
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

    test "emails the fresh DB address when the subject actor snapshot is stale", %{
      user: user,
      subject: subject
    } do
      old_email = user.email
      current_email = Fixtures.Random.unique_email()
      Fixtures.Users.update_email(user, current_email)

      assert subject.actor.email == old_email

      assert :ok = Auth.issue_email_change_code("new@example.com", subject)

      assert_received {:email, email}
      assert [{_, ^current_email}] = email.to
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

    test "direct starts and begin share one issuance budget without replacing on rejection", %{
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for index <- 1..4 do
        assert :ok = Auth.issue_email_change_code("direct-#{index}@example.com", subject)
        assert_received {:email, _}
      end

      assert {:ok, :code} = Auth.begin_email_change("latest@example.com", subject)
      assert_received {:email, latest_email}
      [latest_code] = Regex.run(~r/\d{6}/, latest_email.text_body)

      assert {:error, :rate_limited} =
               Auth.issue_email_change_code("rejected@example.com", subject)

      refute_received {:email, _}

      # A refused resend never deletes the live token it failed to replace.
      assert {:ok, "latest@example.com"} =
               Auth.verify_email_change_code(latest_code, subject)
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
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      :ok = Auth.issue_email_change_code("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      for _ <- 1..5,
          do: assert({:error, :invalid} = Auth.verify_email_change_code("000000", subject))

      # Both the token-local and durable budgets are spent. The durable check
      # refuses the next attempt before the token is loaded.
      assert {:error, :rate_limited} = Auth.verify_email_change_code(code, subject)
    end

    test "replacement tokens cannot reset the durable inbox budget", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      :ok = Auth.issue_email_change_code("first@example.com", subject)
      assert_received {:email, _first_email}

      for _ <- 1..3 do
        assert {:error, :invalid} = Auth.verify_email_change_code("000000", subject)
      end

      :ok = Auth.issue_email_change_code("latest@example.com", subject)
      assert_received {:email, latest_email}
      [latest_code] = Regex.run(~r/\d{6}/, latest_email.text_body)

      for _ <- 1..2 do
        assert {:error, :invalid} = Auth.verify_email_change_code("000000", subject)
      end

      assert {:error, :rate_limited} =
               Auth.verify_email_change_code(latest_code, subject)

      window =
        Repo.get_by!(SecurityAttemptWindow,
          user_id: subject.actor.id,
          scope: :inbox_step_up
        )

      expired = ~U[2001-01-01 00:05:00.000000Z]

      window
      |> Ecto.Changeset.change(
        window_started_at: DateTime.add(expired, -300, :second),
        window_expires_at: expired
      )
      |> Repo.update!()

      # The rate-limited attempt did not read, decrement, or consume the latest
      # token; it remains valid when the durable window resets.
      assert {:ok, "latest@example.com"} =
               Auth.verify_email_change_code(latest_code, subject)
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

  describe "begin_email_change/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "a user without MFA gets the emailed-code factor, bound to the new email", %{
      user: user,
      subject: subject
    } do
      current = user.email

      assert {:ok, :code} = Auth.begin_email_change("new@example.com", subject)

      assert_received {:email, email}
      assert [{_, ^current}] = email.to
      assert [code] = Regex.run(~r/\d{6}/, email.text_body)
      assert {:ok, "new@example.com"} = Auth.verify_email_change_code(code, subject)
    end

    test "an MFA user gets the TOTP factor — read from the fresh row, not the stale subject", %{
      subject: subject
    } do
      secret = Auth.generate_mfa_secret()
      # Enrolls MFA in the DB AFTER the subject was built, so `subject.actor` still
      # carries `mfa_enabled_at: nil` — exactly the stale snapshot the web must not
      # trust to pick the factor.
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      refute subject.actor.mfa_enabled_at

      # The domain re-reads the row, sees MFA, and demands TOTP — no code emailed.
      assert {:ok, :totp} = Auth.begin_email_change("new@example.com", subject)
      refute_received {:email, _}
    end
  end

  describe "confirm_email_change/3" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "a non-MFA user confirms with the emailed code and the bound email is applied", %{
      subject: subject
    } do
      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)
    end

    test "the code path applies the TOKEN-bound email, not the argument passed to confirm", %{
      subject: subject
    } do
      {:ok, :code} = Auth.begin_email_change("bound@example.com", subject)
      assert_received {:email, email}
      [code] = Regex.run(~r/\d{6}/, email.text_body)

      # The emailed code is bound to "bound@example.com"; even though a different
      # target is passed here, the binding wins — a confirm can't swap the target.
      assert {:ok, %User{email: "bound@example.com"}} =
               Auth.confirm_email_change("other@example.com", code, subject)
    end

    test "a wrong code is rejected and the email is unchanged", %{user: user, subject: subject} do
      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, _email}

      assert {:error, :invalid} = Auth.confirm_email_change("new@example.com", "000000", subject)
      assert Repo.reload!(user).email == user.email
    end

    test "an MFA user confirms with a fresh TOTP — factor decided from the fresh row", %{
      subject: subject
    } do
      secret = Auth.generate_mfa_secret()
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      {:ok, :totp} = Auth.begin_email_change("new@example.com", subject)

      otp = NimbleTOTP.verification_code(secret)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", otp, subject)
    end

    test "an MFA user with a wrong TOTP is rejected and the email is unchanged", %{
      user: user,
      subject: subject
    } do
      secret = Auth.generate_mfa_secret()
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      {:ok, :totp} = Auth.begin_email_change("new@example.com", subject)

      assert {:error, :invalid} = Auth.confirm_email_change("new@example.com", "000000", subject)
      assert Repo.reload!(user).email == user.email
    end

    test "shares the MFA attempt cap with the disable step-up", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert {:error, :invalid_code} = Auth.disable_mfa("000000", subject)
      end

      # The disable misses spent the window, so the genuine TOTP is refused
      # before verification: the email stands and the code was never consumed.
      otp = NimbleTOTP.verification_code(secret)
      assert {:error, :rate_limited} = Auth.confirm_email_change("new@example.com", otp, subject)

      reloaded = Repo.reload!(user)
      assert reloaded.email == user.email
      assert reloaded.mfa_last_used_at == nil
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

  describe "mfa_facts/1" do
    test "an unenrolled user is off with no recovery codes" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert Auth.mfa_facts(subject) ==
               {:ok, %Auth.MfaFacts{enabled?: false, recovery_codes_remaining: 0}}
    end

    test "an enrolled user is on with its remaining recovery codes" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {enrolled, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      # The actor snapshot IS the answer, so the facts follow the row the
      # enable handed back — not the pre-enrollment one on `subject`.
      enrolled_subject = Fixtures.Subjects.subject_for(enrolled, account)

      assert Auth.mfa_facts(enrolled_subject) ==
               {:ok, %Auth.MfaFacts{enabled?: true, recovery_codes_remaining: 10}}
    end

    test "the same user's facts are the same from a subject on another workspace" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {enrolled, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      other_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: enrolled.id)

      # A second factor belongs to the identity, not to a tenant.
      assert Auth.mfa_facts(Fixtures.Subjects.subject_for(enrolled, other_account)) ==
               Auth.mfa_facts(Fixtures.Subjects.subject_for(enrolled, account))
    end

    test "refuses a non-user subject" do
      account = Fixtures.Accounts.create_account()
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert Auth.mfa_facts(Auth.Subject.for_api_key(api_key, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "generate_mfa_secret/0" do
    test "returns a non-empty binary suitable for NimbleTOTP" do
      secret = Auth.generate_mfa_secret()
      assert is_binary(secret)
      assert byte_size(secret) > 0
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

  describe "disable_mfa/2" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "uses the fresh user row to clear MFA", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      refute subject.actor.mfa_enabled_at

      assert {:ok, %User{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(NimbleTOTP.verification_code(secret), subject)
    end

    test "accepts a valid recovery code", %{secret: secret, subject: subject} do
      {_user, [code | _]} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:ok, %User{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(code, subject)
    end

    test "rejects a wrong code and leaves MFA enabled", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid_code} = Auth.disable_mfa("000000", subject)
      assert %User{mfa_enabled_at: %DateTime{}} = Repo.reload!(subject.actor)
    end

    test "rejects a missing code and leaves MFA enabled", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid_code} = Auth.disable_mfa(nil, subject)
      assert %User{mfa_enabled_at: %DateTime{}} = Repo.reload!(subject.actor)
    end

    test "shares the MFA attempt cap with sign-in without consuming a recovery code", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, [code | _]} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, "000000"})
      end

      # The sign-in misses spent the window, so a genuine recovery code is
      # refused before the consume — MFA stays on and the code stays usable.
      assert {:error, :rate_limited} = Auth.disable_mfa(code, subject)

      reloaded = Repo.reload!(user)
      assert %DateTime{} = reloaded.mfa_enabled_at
      assert reloaded.mfa_recovery_codes == user.mfa_recovery_codes
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
      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:recovery_code, old_code})

      assert {:ok, _proof} =
               Auth.verify_mfa_challenge(Repo.reload!(user), {:recovery_code, hd(new_codes)})
    end

    test "refuses when MFA is not enabled", %{subject: subject} do
      assert Auth.regenerate_mfa_recovery_codes(subject) == {:error, :mfa_not_enabled}
    end
  end

  describe "check_security_attempt/4" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      %{subject: subject}
    end

    test "resets from database time and saturates after the first rejection", %{
      subject: subject
    } do
      user = subject.actor

      for _ <- 1..5 do
        assert :ok = Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000)
      end

      assert {:error, :rate_limited, :exhausted} =
               Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000)

      assert {:error, :rate_limited, :capped} =
               Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000)

      window = Repo.get_by!(SecurityAttemptWindow, user_id: user.id, scope: :mfa_challenge)
      assert window.attempt_count == 6

      expired = ~U[2001-01-01 00:05:00.000000Z]

      window
      |> Ecto.Changeset.change(
        window_started_at: DateTime.add(expired, -300, :second),
        window_expires_at: expired
      )
      |> Repo.update!()

      assert :ok = Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000)

      reset = Repo.reload!(window)
      assert reset.attempt_count == 1
      assert DateTime.compare(reset.window_started_at, expired) == :gt
      assert DateTime.compare(reset.window_expires_at, reset.window_started_at) == :gt
    end

    test "a persistence failure rejects the credential attempt", %{subject: subject} do
      missing_user = %{subject.actor | id: Repo.generate_id()}

      assert {:error, :rate_limited, :store_unavailable} =
               Auth.check_security_attempt(missing_user, :mfa_challenge, 5, 300_000)
    end
  end

  describe "check_security_attempt/5" do
    test "carries request provenance onto the first over-limit audit signal" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      context = %RequestContext{request_id: "req-direct-security-attempt"}

      assert :ok =
               Auth.check_security_attempt(
                 subject.actor,
                 :mfa_challenge,
                 1,
                 300_000,
                 context
               )

      assert {:error, :rate_limited, :exhausted} =
               Auth.check_security_attempt(
                 subject.actor,
                 :mfa_challenge,
                 1,
                 300_000,
                 context
               )

      assert [event] = events_of_type("user.mfa_rate_limited")
      assert event.request_id == "req-direct-security-attempt"
    end

    test "logs each email-change limit only on its first refusal" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for scope <- [:email_change_issue, :inbox_step_up] do
        context = %RequestContext{request_id: "req-#{scope}"}

        assert :ok = Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context)

        assert {:error, :rate_limited, :exhausted} =
                 Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context)

        assert {:error, :rate_limited, :capped} =
                 Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context)
      end

      events =
        "user.email_change_rate_limited"
        |> events_of_type()
        |> Enum.sort_by(& &1.payload["scope"])

      assert Enum.map(events, &{&1.payload["scope"], &1.request_id}) == [
               {"email_change_issue", "req-email_change_issue"},
               {"inbox_step_up", "req-inbox_step_up"}
             ]
    end
  end

  describe "verify_mfa_challenge/3" do
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
      assert {:ok, _proof} = Auth.verify_mfa_challenge(user, {:totp, otp})

      user = Repo.reload!(user)
      assert {:error, :replay} = Auth.verify_mfa_challenge(user, {:totp, otp})
    end

    test "rejects an invalid OTP", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, "000000"})
    end

    test "a malformed factor is the catch-all :invalid" do
      assert {:error, :invalid} = Auth.verify_mfa_challenge(%User{}, {:totp, nil})
      assert {:error, :invalid} = Auth.verify_mfa_challenge(%User{}, {:recovery_code, nil})
      assert {:error, :invalid} = Auth.verify_mfa_challenge(%User{}, {:sms, "000000"})
    end

    # a non-numeric OTP is rejected, and because the replay guard only stamps
    # on a *valid* code, the real code still works right after (the bad attempt
    # didn't burn the current bucket).
    test "rejects a non-numeric OTP without burning the live code", %{
      secret: secret,
      subject: subject
    } do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, "abcdef"})

      # The genuine current code is untouched by the failed attempt.
      otp = NimbleTOTP.verification_code(secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(Repo.reload!(user), {:totp, otp})
    end

    test "an OTP can't complete sign-in after MFA was disabled mid-verify (MAJOR-4)", %{
      secret: secret,
      subject: subject
    } do
      # `user` is the pre-disable snapshot — it still carries the live secret +
      # mfa_enabled_at, exactly the stale struct a sign-in attempt would hold.
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      otp = NimbleTOTP.verification_code(secret)

      {:ok, _} = Auth.disable_mfa(otp, subject)

      # The old code validated against the stale struct's secret and would pass;
      # the locked verify reads the CURRENT row (MFA now disabled) and refuses.
      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, otp})
    end

    test "an OTP for a rotated secret can't complete sign-in (MAJOR-4)", %{subject: subject} do
      secret1 = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret1, subject)
      otp1 = NimbleTOTP.verification_code(secret1)

      # Rotate the secret out from under the in-flight verify (disable + re-enable).
      {:ok, _} = Auth.disable_mfa(otp1, subject)
      secret2 = Auth.generate_mfa_secret()
      {_user2, _codes} = Fixtures.Users.enable_mfa!(secret2, subject)

      # `user` + `otp1` are for the OLD secret; the locked verify validates
      # against the current secret2 and refuses.
      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, otp1})
    end

    # (sequential single-use; true-concurrent is out of scope) — a recovery
    # code consumes once; a second consume of the SAME code fails, while a
    # sibling code from the set is unaffected.
    test "accepts a fresh recovery code once, rejects reuse, leaves siblings valid", %{
      secret: secret,
      subject: subject
    } do
      {user, [code, other_code | _]} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:ok, _proof} = Auth.verify_mfa_challenge(user, {:recovery_code, code})

      user = Repo.reload!(user)
      assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:recovery_code, code})

      # Consuming one code doesn't invalidate the rest of the set.
      assert {:ok, _proof} = Auth.verify_mfa_challenge(user, {:recovery_code, other_code})
    end

    test "rejects an unknown recovery code as :invalid", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:error, :invalid} =
               Auth.verify_mfa_challenge(user, {:recovery_code, "not-a-real-code"})
    end

    test "counts both factors against one per-user window and refuses the sixth attempt", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert {:error, :invalid} = Auth.verify_mfa_challenge(user, {:totp, "000000"})
      end

      # The window is exhausted: even the genuine current code is refused, and
      # switching to the recovery factor doesn't buy more attempts.
      otp = NimbleTOTP.verification_code(secret)
      assert {:error, :rate_limited} = Auth.verify_mfa_challenge(user, {:totp, otp})

      assert {:error, :rate_limited} =
               Auth.verify_mfa_challenge(user, {:recovery_code, "not-a-real-code"})

      # The capped attempt never reached verification: the genuine code was
      # refused without being consumed (a verify would have stamped the row).
      assert Repo.reload!(user).mfa_last_used_at == nil
    end

    test "the cap is per user — an exhausted window doesn't throttle another user", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      {_other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      other_secret = Auth.generate_mfa_secret()
      {other_user, _other_codes} = Fixtures.Users.enable_mfa!(other_secret, other_subject)

      for _ <- 1..6, do: Auth.verify_mfa_challenge(user, {:totp, "000000"})

      other_otp = NimbleTOTP.verification_code(other_secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(other_user, {:totp, other_otp})
    end

    test "concurrent attempts can't overshoot the window", %{secret: secret, subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> Auth.verify_mfa_challenge(user, {:totp, "000000"}) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &(&1 == {:error, :invalid})) == 5
      assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 5
    end
  end

  describe "mfa_proof_user_id/1" do
    test "names the user a verified proof was minted for" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert Auth.mfa_proof_user_id(proof) == user.id
    end

    test "anything that isn't a proof names no one" do
      assert Auth.mfa_proof_user_id(Ecto.UUID.generate()) == nil
      assert Auth.mfa_proof_user_id(%{user_id: 42}) == nil
      assert Auth.mfa_proof_user_id(nil) == nil
    end

    test "a hand-assembled map carrying a user id is not a proof" do
      user = Fixtures.Users.create_user()

      assert Auth.mfa_proof_user_id(%{user_id: user.id}) == nil

      assert Auth.mfa_proof_user_id(%{
               user_id: user.id,
               mfa_enabled_at: nil,
               updated_at: DateTime.utc_now()
             }) == nil

      assert Auth.mfa_proof_user_id(%{
               user_id: user.id,
               mfa_enabled_at: DateTime.utc_now(),
               updated_at: nil
             }) == nil
    end
  end
end
