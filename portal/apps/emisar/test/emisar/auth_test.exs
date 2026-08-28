defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, Fixtures, Mail, RequestContext, Users}
  alias Emisar.Accounts.Account
  alias Emisar.Auth.{SecurityAttemptWindow, Subject, UserToken}
  alias Emisar.Users.User

  defmodule RaisingSessionDisconnector do
    def disconnect_live_sessions(_topics), do: raise("handler must not run")
  end

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

  defp verify_magic_link(user, opts \\ []) do
    {token_id, nonce, secret} = request_magic_link(user, opts)
    assert {:ok, %User{id: user_id}} = Auth.verify_magic_link(token_id, secret, nonce)
    assert user_id == user.id
    token_id
  end

  defp owner_registration(account_name, full_name \\ "Inbox Owner"),
    do: %{account_name: account_name, full_name: full_name}

  # A user-scoped audit row lands once per account the user belongs to, so read
  # the type straight off the table instead of through an account-scoped list.
  defp events_of_type(event_type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  defp issue_mfa_enrollment_code(subject) do
    assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :sent}
    assert_received {:email, email}
    Fixtures.Auth.code_from_email(email)
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

  describe "role_carries_runner_access?/1" do
    # The finance seat is the only role with no runner reach, and every
    # membership write normalizes through it — so a role added here without a
    # deliberate answer would silently start carrying scope.
    test "every role but the finance seat reaches runners" do
      for role <- Auth.roles() -- [:billing_manager] do
        assert Auth.role_carries_runner_access?(role)
      end

      refute Auth.role_carries_runner_access?(:billing_manager)
    end

    test "takes the string a form posts, and fails closed on an unknown role" do
      assert Auth.role_carries_runner_access?("operator")
      refute Auth.role_carries_runner_access?("billing_manager")
      refute Auth.role_carries_runner_access?("nope")
      refute Auth.role_carries_runner_access?(nil)
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

  describe "complete_sso_account_sign_in/4" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Accounts.create_subscription(account, "team")

      provider = Fixtures.SSO.create_identity_provider(%{account_id: account.id})

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        })

      %{account: account, identity: identity, provider: provider, subject: subject, user: user}
    end

    test "records the sign-in and mints an :sso session while the account is active", %{
      account: account,
      identity: identity,
      provider: provider,
      user: user
    } do
      context = RequestContext.new(%{ip_address: "203.0.113.9"})
      provider |> Ecto.Changeset.change(satisfies_mfa: true) |> Repo.update!()

      assert {:ok, token, true} =
               Auth.complete_sso_account_sign_in(user, account.id, context,
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, %User{id: id},
              %UserToken{auth_method: :sso, mfa_verified_at: %DateTime{}} = stored} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
      # ip + user_agent ride in the token's `metadata` jsonb (string-keyed once persisted).
      assert stored.metadata["ip_address"] == "203.0.113.9"
    end

    test "bounds session display metadata before persisting it", %{
      account: account,
      identity: identity,
      user: user
    } do
      context = RequestContext.new(%{user_agent: String.duplicate("x", 500)})

      assert {:ok, token, false} =
               Auth.complete_sso_account_sign_in(user, account.id, context,
                 user_identity_id: identity.id,
                 provider_identifier: identity.provider_identifier
               )

      assert {:ok, _user, %UserToken{} = stored} =
               Auth.fetch_user_and_token_by_session_token(token)

      refute stored.mfa_verified_at
      assert String.length(stored.metadata["user_agent"]) == 255
    end

    test "does not mint a session after the account is disabled", %{
      account: account,
      identity: identity,
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

      assert Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             ) ==
               {:error, :account_disabled}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "fails closed for a missing, foreign-user, foreign-account, or deleted identity", %{
      account: account,
      identity: identity,
      user: user
    } do
      context = %RequestContext{}

      assert Auth.complete_sso_account_sign_in(user, account.id, context) ==
               {:error, :provider_disabled}

      other_user = Fixtures.Users.create_user()

      assert Auth.complete_sso_account_sign_in(other_user, account.id, context,
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             ) == {:error, :provider_disabled}

      other_account = Fixtures.Accounts.create_account()

      assert Auth.complete_sso_account_sign_in(user, other_account.id, context,
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             ) == {:error, :provider_disabled}

      identity
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert Auth.complete_sso_account_sign_in(user, account.id, context,
               user_identity_id: identity.id,
               provider_identifier: identity.provider_identifier
             ) == {:error, :provider_disabled}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "binds the mint to the callback identifier and a still-active OIDC binding", %{
      account: account,
      identity: identity,
      user: user
    } do
      callback_identifier = identity.provider_identifier

      rebound =
        identity
        |> Ecto.Changeset.change(provider_identifier: "rebound-#{Ecto.UUID.generate()}")
        |> Repo.update!()

      assert Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
               user_identity_id: rebound.id,
               provider_identifier: callback_identifier
             ) == {:error, :provider_disabled}

      retired =
        rebound
        |> Ecto.Changeset.change(provider_identifier_retired_at: DateTime.utc_now())
        |> Repo.update!()

      assert Auth.complete_sso_account_sign_in(user, account.id, %RequestContext{},
               user_identity_id: retired.id,
               provider_identifier: retired.provider_identifier
             ) == {:error, :provider_disabled}

      refute Repo.one(UserToken.Query.by_context("session"))
    end
  end

  describe "fetch_user_and_token_by_session_token/1" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "resolves a live session to {:ok, user, token}", %{user: user} do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, %User{id: id}, %UserToken{context: "session"}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "an unknown or non-binary token is :not_found, never a crash", %{user: _user} do
      assert Auth.fetch_user_and_token_by_session_token("nope") == {:error, :not_found}
      assert Auth.fetch_user_and_token_by_session_token("") == {:error, :not_found}
    end

    test "a session past its validity window no longer resolves", %{user: user} do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      # 61 days is past the 60-day session window.
      age_tokens(user.id, 61 * 24 * 60)

      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end

    test "a soft-deleted user's token reads as :not_found (preload scoped to live users)", %{
      user: user
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Users.mark_user_as_deleted(user)

      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end

    test "a session holding a removed auth_method fails closed, never raising on load", %{
      user: user
    } do
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      # Loading a session whose enum value was removed must resolve to
      # :not_found, not raise ArgumentError and 500 the request.
      Fixtures.Auth.write_removed_auth_method!()

      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end
  end

  describe "session_mfa_verified?/2" do
    # Fixed instants rather than `utc_now`, so the ordering the predicate turns
    # on is what each test asserts and never an equal-instant coin flip.
    test "a magic-link proof taken against the current enrollment counts" do
      user = %User{mfa_enabled_at: ~U[2026-08-01 12:00:00.000000Z]}

      session = %UserToken{
        auth_method: :magic_link,
        mfa_verified_at: ~U[2026-08-01 12:00:01.000000Z],
        mfa_enrollment_verified_at: ~U[2026-08-01 12:00:00.000000Z]
      }

      assert Auth.session_mfa_verified?(user, session) == true
    end

    test "a magic-link proof older than the current enrollment does not" do
      # A disable → re-enroll moves `mfa_enabled_at` forward, and that is exactly
      # what strips the claim from a session that only proved the old factor.
      user = %User{mfa_enabled_at: ~U[2026-08-01 12:00:00.000000Z]}

      session = %UserToken{
        auth_method: :magic_link,
        mfa_verified_at: ~U[2026-07-31 09:00:00.000000Z],
        mfa_enrollment_verified_at: ~U[2026-07-31 09:00:00.000000Z]
      }

      assert Auth.session_mfa_verified?(user, session) == false
    end

    test "a magic-link proof with no enrollment left behind it does not" do
      user = %User{mfa_enabled_at: nil}

      session = %UserToken{
        auth_method: :magic_link,
        mfa_verified_at: ~U[2026-08-01 12:00:00.000000Z],
        mfa_enrollment_verified_at: ~U[2026-08-01 12:00:00.000000Z]
      }

      assert Auth.session_mfa_verified?(user, session) == false
    end

    test "an SSO proof survives TOTP enrollment churn" do
      # The IdP proved the factor, so our TOTP lifecycle does not govern it —
      # enrolling here afterwards must not retroactively invalidate the session.
      user = %User{mfa_enabled_at: ~U[2026-08-02 12:00:00.000000Z]}
      session = %UserToken{auth_method: :sso, mfa_verified_at: ~U[2026-08-01 12:00:00.000000Z]}

      assert Auth.session_mfa_verified?(user, session) == true
    end

    test "a session that never proved a factor is never verified" do
      user = %User{mfa_enabled_at: ~U[2026-08-01 12:00:00.000000Z]}

      assert Auth.session_mfa_verified?(user, %UserToken{auth_method: :magic_link}) == false
      assert Auth.session_mfa_verified?(user, %UserToken{auth_method: :sso}) == false
    end
  end

  describe "session_mfa_enrollment_verified_at/2" do
    test "returns only an exact non-nil enrollment epoch" do
      current = ~U[2026-08-01 12:00:00.000000Z]
      user = %User{mfa_enabled_at: current}

      assert Auth.session_mfa_enrollment_verified_at(
               user,
               %UserToken{mfa_enrollment_verified_at: current}
             ) == current

      assert Auth.session_mfa_enrollment_verified_at(
               user,
               %UserToken{mfa_enrollment_verified_at: DateTime.add(current, -1, :second)}
             ) == nil

      assert Auth.session_mfa_enrollment_verified_at(
               %User{mfa_enabled_at: nil},
               %UserToken{mfa_enrollment_verified_at: nil}
             ) == nil
    end
  end

  describe "delete_session_token/1" do
    test "drops the session row backing the cookie" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.delete_session_token(token) == :ok
      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end

    test "deleting an unknown token is an idempotent :ok" do
      assert Auth.delete_session_token("never-existed") == :ok
    end

    test "writes no user.signed_out — a forced invalidation is not a sign-out" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.delete_session_token(token) == :ok
      assert events_of_type("user.signed_out") == []
    end
  end

  describe "complete_session_sign_out/2" do
    test "drops the presented session and audits it once, to the token's owner" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      context = RequestContext.new(%{ip_address: "203.0.113.7", user_agent: "Firefox"})

      assert Auth.complete_session_sign_out(token, context) == :ok

      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
      assert [event] = events_of_type("user.signed_out")
      assert event.actor_id == user.id
      assert event.target_id == user.id
      assert event.ip_address == "203.0.113.7"
      assert event.user_agent == "Firefox"
    end

    test "an unknown token is an idempotent :ok that audits nothing" do
      assert Auth.complete_session_sign_out("never-existed") == :ok
      assert events_of_type("user.signed_out") == []
    end

    test "a failed audit rolls the token deletion back" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
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
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      # 61 days is past the 60-day session window.
      age_tokens(user.id, 61 * 24 * 60)

      assert Auth.complete_session_sign_out(token) == :ok

      refute Repo.one(UserToken.Query.by_token_digest(Crypto.hash(token)))
      assert events_of_type("user.signed_out") == []
    end

    test "a session holding a removed auth_method is swept without an audit" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      Fixtures.Auth.write_removed_auth_method!()

      assert Auth.complete_session_sign_out(token) == :ok

      refute Repo.one(UserToken.Query.by_token_digest(Crypto.hash(token)))
      assert events_of_type("user.signed_out") == []
    end

    test "only the presented session ends — the user's other devices stay signed in" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      other_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.complete_session_sign_out(token) == :ok

      assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
      assert {:ok, %User{}, _token} = Auth.fetch_user_and_token_by_session_token(other_token)
    end
  end

  describe "delete_all_session_tokens/1" do
    test "removes every session token for the user and returns the count" do
      user = Fixtures.Users.create_user()
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.delete_all_session_tokens(user) === {:ok, 2}

      subject =
        Fixtures.Subjects.subject_for(user, Fixtures.Accounts.create_account(), role: :owner)

      assert {:ok, [], _} = Auth.list_sessions_for_user(nil, subject)
    end

    test "only touches the given user's sessions" do
      user = Fixtures.Users.create_user()
      other = Fixtures.Users.create_user()
      _ = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      keep = Fixtures.Auth.create_session_token!(other, :magic_link, nil)

      assert Auth.delete_all_session_tokens(user) === {:ok, 1}
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
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)

      magic_link = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_identity_sessions(user, [identity.id]) == :ok

      assert Auth.fetch_user_and_token_by_session_token(sso) == {:error, :not_found}
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(magic_link)
    end

    test "an empty identity list revokes nothing" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_identity_sessions(user, []) == :ok
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "delete_identity_session_tokens/3" do
    test "deletes only the named identity sessions and returns their exact topics" do
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
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)

      magic_link = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, %{count: 1, socket_topics: [topic]}} =
               Auth.delete_identity_session_tokens(user, [identity.id], Repo)

      assert topic == Auth.live_socket_topic_for_session(sso)
      assert Auth.fetch_user_and_token_by_session_token(sso) == {:error, :not_found}
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(magic_link)
    end
  end

  describe "revoke_provider_sessions/2" do
    test "revokes only sessions minted through the selected provider identities" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      other_identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: other_provider.id,
          user_id: user.id
        )

      revoked =
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)

      other_sso =
        Fixtures.Auth.create_session_token!(user, :sso, nil, %{},
          user_identity_id: other_identity.id
        )

      magic_link = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_provider_sessions(user, [identity.id]) == :ok

      assert Auth.fetch_user_and_token_by_session_token(revoked) == {:error, :not_found}
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(other_sso)
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(magic_link)
    end
  end

  describe "capture_live_socket_topics/1" do
    test "captures a topic per live session, and still resolves them after the rows are gone" do
      user = Fixtures.Users.create_user()
      token_one = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      token_two = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      captured = Auth.capture_live_socket_topics(user)

      expected = Enum.map([token_one, token_two], &Auth.live_socket_topic(Crypto.hash(&1)))
      assert Enum.sort(captured) == Enum.sort(expected)

      # The point of capturing: once the rows are deleted the topics can no
      # longer be derived, so a caller that deletes them in a transaction must
      # hold this list to disconnect anyone at all.
      {:ok, 2} = Auth.delete_all_session_tokens(user)
      assert Auth.capture_live_socket_topics(user) == []
    end
  end

  describe "disconnect_live_socket_topics/1" do
    # In the `:emisar`-only test process the configured handler's sibling app
    # isn't started, so this is a pure, best-effort no-op.
    test "is a best-effort :ok that deletes no token rows" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      captured = Auth.capture_live_socket_topics(user)

      assert Auth.disconnect_live_socket_topics(captured) == :ok
      assert Auth.disconnect_live_socket_topics([]) == :ok

      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "does not call a loaded handler whose application is not started" do
      Emisar.Config.put_override(
        :session_disconnect_handler,
        {:emisar_not_started_for_test, RaisingSessionDisconnector}
      )

      assert Code.ensure_loaded?(RaisingSessionDisconnector)
      assert Auth.disconnect_live_socket_topics(["users_sessions:test"]) == :ok
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
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      _other1 = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      _other2 = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 2

      {:ok, remaining, _} = Auth.list_sessions_for_user(nil, subject)
      assert length(remaining) == 1
      # The kept cookie still resolves.
      assert {:ok, %User{}, _auth} = Auth.fetch_user_and_token_by_session_token(keep)
    end

    test "with only the current session, revokes nothing", %{user: user, subject: subject} do
      keep = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.revoke_and_disconnect_other_sessions!(keep, subject) == 0
      assert {:ok, %User{}, _} = Auth.fetch_user_and_token_by_session_token(keep)
    end
  end

  describe "broadcast_disconnect_for_user/2" do
    # In the `:emisar`-only test process the configured handler's sibling app
    # isn't started, so this is a pure, best-effort no-op whose observable
    # contract is `:ok` with the DB untouched.
    test "is a best-effort :ok that deletes no token rows" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert Auth.broadcast_disconnect_for_user(user) == :ok
      assert Auth.broadcast_disconnect_for_user(user, except: Crypto.hash(token)) == :ok

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

    test "a stale browser cannot inherit another browser's registration intent", %{user: user} do
      victim_workspace = "Victim #{Ecto.UUID.generate()}"
      attacker_workspace = "Attacker #{Ecto.UUID.generate()}"

      {victim_token_id, _victim_nonce, _victim_secret} =
        request_magic_link(user,
          owner_registration: owner_registration(victim_workspace, "Victim Name")
        )

      {attacker_token_id, _attacker_nonce, _attacker_secret} =
        request_magic_link(user,
          owner_registration: owner_registration(attacker_workspace, "Attacker Name")
        )

      assert %UserToken{
               id: ^attacker_token_id,
               metadata: %{"registration_account_name" => ^attacker_workspace}
             } = Repo.get!(UserToken, attacker_token_id)

      {replacement_id, replacement_nonce, replacement_secret} =
        request_magic_link(user, prior_magic_link_token_id: victim_token_id)

      assert %UserToken{id: ^replacement_id, metadata: %{}} =
               Repo.get!(UserToken, replacement_id)

      assert {:ok, %User{id: user_id}} =
               Auth.verify_magic_link(replacement_id, replacement_secret, replacement_nonce)

      assert user_id == user.id

      assert {:ok, _user, _session, :no_target, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 replacement_id,
                 nil,
                 %RequestContext{}
               )

      refute Repo.get_by(Account, name: victim_workspace)
      refute Repo.get_by(Account, name: attacker_workspace)
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
      account = Fixtures.Accounts.create_account(name: "Northstar")

      assert {:ok, %{delivery: {:ok, :sent}}} =
               Auth.request_magic_link(user, %RequestContext{}, account_ref: account.slug)

      assert_received {:email, sent}

      assert sent.text_body =~
               "sign in to Northstar (http://localhost/app/#{account.slug})"

      refute sent.text_body =~ "Requested from:"
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

  describe "magic_link_decoy/0" do
    test "matches real browser-state shape without persisting authority" do
      assert %{token_id: token_id, nonce: nonce} = Auth.magic_link_decoy()
      assert Repo.valid_uuid?(token_id)
      assert String.at(token_id, 14) == "7"
      assert is_binary(nonce)
      refute Repo.get(UserToken, token_id)
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

    test "promotes the exact row and correct retries remain idempotent", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)

      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id

      assert %UserToken{
               id: ^token_id,
               user_id: ^id,
               context: "magic_link_verified",
               sent_to: sent_to,
               metadata: %{"verified_at" => verified_at}
             } = Repo.get!(UserToken, token_id)

      assert sent_to == user.email
      assert is_binary(verified_at)

      assert {:ok, %User{id: ^id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert Repo.get!(UserToken, token_id).metadata["verified_at"] == verified_at
    end

    test "the email half alone can't sign in — a wrong nonce is rejected (anti-hijack)", %{
      user: user
    } do
      {token_id, nonce, secret} = request_magic_link(user)

      # An intercepted email gives token_id + secret but NOT the originating
      # browser's nonce → the core anti-hijack guarantee: no sign-in.
      assert Auth.verify_magic_link(token_id, secret, "wrong-nonce") ==
               {:error, :invalid_or_expired}

      # …and the real browser still signs in — one wrong attempt only spent one
      # of the budget, it didn't burn the token.
      assert {:ok, %User{id: id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert id == user.id
    end

    test "a token past the 15-minute window no longer verifies", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)
      age_tokens(user.id, 16)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}
    end

    test "a malformed token id is invalid rather than a database cast error" do
      assert Auth.verify_magic_link("not-a-uuid", "secret", "nonce") ==
               {:error, :invalid_or_expired}
    end

    test "a soft-deleted token owner is uniformly invalid", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)
      Fixtures.Users.mark_user_as_deleted(user)

      assert Auth.verify_magic_link(token_id, secret, nonce) ==
               {:error, :invalid_or_expired}
    end

    test "a pending factor sent to an old address is uniformly invalid", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)

      user
      |> Users.User.Changeset.email(%{email: "moved-#{Ecto.UUID.generate()}@example.test"})
      |> Repo.update!()

      assert Auth.verify_magic_link(token_id, secret, nonce) ==
               {:error, :invalid_or_expired}

      assert %UserToken{context: "magic_link"} = Repo.get!(UserToken, token_id)
    end

    test "five wrong attempts lock the token — even the correct half then fails", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)

      # Burn all five attempts (a wrong nonce always mismatches the high-entropy one).
      for _ <- 1..5 do
        assert Auth.verify_magic_link(token_id, secret, "wrong-nonce") ==
                 {:error, :invalid_or_expired}
      end

      # Locked: the correct (nonce, secret) no longer works.
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}
    end

    test "promotion does not reset the public five-attempt budget", %{user: user} do
      {token_id, nonce, secret} = request_magic_link(user)
      assert {:ok, %User{id: user_id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert user_id == user.id

      for _ <- 1..5 do
        assert Auth.verify_magic_link(token_id, secret, "wrong-nonce") ==
                 {:error, :invalid_or_expired}
      end

      assert %UserToken{context: "magic_link_verified", remaining_attempts: 0} =
               Repo.get!(UserToken, token_id)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}

      # The already-issued completion handoff remains valid; public retry abuse
      # cannot turn the attempt budget into a denial of the authorized browser.
      assert {:ok, _user, _session, :no_target, false} =
               Auth.complete_magic_link_sign_in(user.id, token_id, nil, %RequestContext{})
    end
  end

  describe "complete_magic_link_sign_in/4" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject, user: user}
    end

    test "an unbranded completion mints a magic_link session with no second factor", %{
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, %User{} = signed_in, token, :no_target, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert signed_in.id == user.id

      assert {:ok, %User{id: id}, %UserToken{auth_method: :magic_link, mfa_verified_at: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "a deferred registration creates its one workspace only with the final session" do
      user = Fixtures.Users.create_user(confirmed?: false, full_name: "Unproved Name")

      verified_token_id =
        verify_magic_link(user,
          owner_registration: owner_registration("Deferred Workspace", "Proved Name")
        )

      refute Repo.get_by(Accounts.Membership, user_id: user.id)
      refute Repo.get_by(Accounts.Account, name: "Deferred Workspace")

      assert {:ok, signed_in, token, :no_target, true} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert signed_in.id == user.id
      assert signed_in.full_name == "Proved Name"

      assert %Accounts.Account{name: "Deferred Workspace"} =
               account = Repo.get_by!(Accounts.Account, name: "Deferred Workspace")

      assert %Accounts.Membership{
               account_id: account_id,
               user_id: user_id,
               role: :owner
             } = Repo.get_by!(Accounts.Membership, user_id: user.id)

      assert account_id == account.id
      assert user_id == user.id

      assert {:ok, %User{id: ^user_id}, %UserToken{}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a copied registration handoff becomes an ordinary sign-in after first completion" do
      user = Fixtures.Users.create_user(confirmed?: false)

      first_factor =
        verify_magic_link(user, owner_registration: owner_registration("First Workspace"))

      assert {:ok, _user, _token, :no_target, true} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 first_factor,
                 nil,
                 %RequestContext{}
               )

      second_factor =
        verify_magic_link(user, owner_registration: owner_registration("Replay Workspace"))

      assert {:ok, _user, _token, :no_target, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 second_factor,
                 nil,
                 %RequestContext{}
               )

      assert %Accounts.Account{} = Repo.get_by(Accounts.Account, name: "First Workspace")
      refute Repo.get_by(Accounts.Account, name: "Replay Workspace")
      assert %Accounts.Membership{} = Repo.get_by(Accounts.Membership, user_id: user.id)
    end

    test "a final audit rollback preserves the exact factor for a successful retry" do
      user = Fixtures.Users.create_user(confirmed?: false)

      verified_token_id =
        verify_magic_link(user, owner_registration: owner_registration("Retry Workspace"))

      invalid_context = %RequestContext{request_id: %{invalid: true}}

      assert {:error, changeset} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 invalid_context
               )

      assert "is invalid" in errors_on(changeset).request_id
      refute Repo.get_by(Accounts.Account, name: "Retry Workspace")
      refute Repo.get_by(Accounts.Membership, user_id: user.id)
      refute Repo.one(UserToken.Query.by_context("session"))
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"

      assert {:ok, _user, _token, :no_target, true} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert %Accounts.Account{name: "Retry Workspace"} =
               Repo.get_by(Accounts.Account, name: "Retry Workspace")
    end

    test "a membership gained after issuance cannot cancel the proved registration" do
      user = Fixtures.Users.create_user(confirmed?: false)

      {token_id, nonce, secret} =
        request_magic_link(user, owner_registration: owner_registration("Requested Workspace"))

      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      assert {:ok, %User{}} = Auth.verify_magic_link(token_id, secret, nonce)

      assert {:ok, _user, _token, {:member, landed}, true} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 token_id,
                 account.slug,
                 %RequestContext{}
               )

      assert landed.id == account.id
      assert %Accounts.Account{} = Repo.get_by(Accounts.Account, name: "Requested Workspace")

      assert 2 ==
               Accounts.Membership.Query.not_deleted()
               |> Accounts.Membership.Query.by_user_id(user.id)
               |> Repo.aggregate(:count)
    end

    # The returned user carries the sign-in the minting transaction just stamped,
    # so a boundary that installs it can't render a pre-sign-in snapshot.
    test "the returned user is the row the sign-in stamped", %{user: user} do
      verified_token_id = verify_magic_link(user)

      assert {:ok, signed_in, _token, :no_target, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      refute user.last_sign_in_at
      assert %DateTime{} = signed_in.last_sign_in_at
    end

    test "a branded completion lands the member on that account", %{
      account: account,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, _user, token, {:member, landed}, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 account.slug,
                 %RequestContext{}
               )

      assert landed.id == account.id

      assert {:ok, _user, %UserToken{auth_method: :magic_link, mfa_verified_at: nil}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a branded completion for a non-member still signs them in, without the target", %{
      user: user
    } do
      other_account = Fixtures.Accounts.create_account()
      verified_token_id = verify_magic_link(user)

      assert {:ok, _user, token, :not_member, false} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 other_account.slug,
                 %RequestContext{}
               )

      assert {:ok, _user, %UserToken{}} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "an enrollment made since the link was issued still owes a second factor", %{
      subject: subject,
      user: user
    } do
      verified_token_id = verify_magic_link(user)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_sign_in(
               user.id,
               verified_token_id,
               nil,
               %RequestContext{}
             ) ==
               {:error, :mfa_required}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a verified factor cannot sign in after the user's email changes", %{user: user} do
      verified_token_id = verify_magic_link(user)
      Fixtures.Users.update_email(user, Fixtures.Random.unique_email())

      assert Auth.complete_magic_link_sign_in(
               user.id,
               verified_token_id,
               nil,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      refute Repo.one(UserToken.Query.by_context("session"))
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"
    end

    test "a verified factor expires ten minutes after promotion", %{user: user} do
      verified_token_id = verify_magic_link(user)
      verified_at = DateTime.utc_now() |> DateTime.add(-601, :second) |> DateTime.to_iso8601()

      UserToken.Query.by_id(verified_token_id)
      |> Repo.update_all(set: [metadata: %{"verified_at" => verified_at}])

      assert Auth.complete_magic_link_sign_in(
               user.id,
               verified_token_id,
               nil,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "missing or malformed promotion time fails closed", %{user: user} do
      for metadata <- [%{}, %{"verified_at" => "not-a-time"}] do
        verified_token_id = verify_magic_link(user)

        UserToken.Query.by_id(verified_token_id)
        |> Repo.update_all(set: [metadata: metadata])

        assert Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               ) == {:error, :invalid_or_expired}
      end

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a disabled branded account mints nothing and hands back the account", %{
      account: account,
      subject: subject,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      {:ok, _account} =
        Accounts.set_account_disabled_for_support(account.id, true, "support incident", subject)

      assert {:error, {:account_disabled, disabled}} =
               Auth.complete_magic_link_sign_in(
                 user.id,
                 verified_token_id,
                 account.slug,
                 %RequestContext{}
               )

      assert disabled.id == account.id
      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a failed sign-in audit rolls the stamp and the session back", %{user: user} do
      # A non-string request_id fails the audit changeset, so the one minting
      # transaction aborts — no stamped sign-in, no session, no audit row.
      context = %RequestContext{request_id: %{invalid: true}}
      verified_token_id = verify_magic_link(user)

      assert {:error, changeset} =
               Auth.complete_magic_link_sign_in(user.id, verified_token_id, nil, context)

      assert "is invalid" in errors_on(changeset).request_id

      assert Repo.reload!(user).last_sign_in_at == user.last_sign_in_at
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"
      refute Repo.one(UserToken.Query.by_context("session"))
      assert events_of_type("user.signed_in") == []
    end

    test "a user that no longer resolves is :not_found" do
      assert Auth.complete_magic_link_sign_in(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               nil,
               %RequestContext{}
             ) ==
               {:error, :not_found}
    end
  end

  describe "complete_magic_link_mfa_sign_in/4" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {user, codes} = Fixtures.Users.enable_mfa!(secret, subject)
      %{account: account, codes: codes, secret: secret, subject: subject, user: user}
    end

    test "a verified TOTP proof mints a magic_link session stamping the proof time", %{
      secret: secret,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, %User{} = signed_in, token, :no_target, false} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert signed_in.id == user.id

      assert {:ok, %User{id: id},
              %UserToken{auth_method: :magic_link, mfa_verified_at: %DateTime{}}} =
               Auth.fetch_user_and_token_by_session_token(token)

      assert id == user.id
    end

    test "a verified recovery-code proof mints the same session", %{
      codes: [code | _],
      user: user
    } do
      verified_token_id = verify_magic_link(user)
      assert {:ok, proof} = Auth.verify_mfa_challenge(user, {:recovery_code, code})

      assert {:ok, _user, token, :no_target, false} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert {:ok, _user, %UserToken{auth_method: :magic_link, mfa_verified_at: %DateTime{}}} =
               Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a completed proof cannot be replayed into a second session", %{
      secret: secret,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user, _token, :no_target, false} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 nil,
                 %RequestContext{}
               )

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               nil,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      # `Repo.one` raises on a second row, so this asserts the replay minted none.
      assert Repo.one(UserToken.Query.by_context("session"))
    end

    test "a branded completion lands the member on that account", %{
      account: account,
      secret: secret,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user, _token, {:member, landed}, false} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 account.slug,
                 %RequestContext{}
               )

      assert landed.id == account.id
    end

    test "a verified inbox factor cannot finish MFA after the email changes", %{
      secret: secret,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      Fixtures.Users.update_email(user, Fixtures.Random.unique_email())

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               nil,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a proof no longer matches once MFA was disabled after the challenge", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user} = Auth.disable_mfa(code, subject)

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               nil,
               %RequestContext{}
             ) ==
               {:error, :mfa_proof_stale}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "a proof no longer matches once the secret was rotated (disable, re-enable)", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      user: user
    } do
      verified_token_id = verify_magic_link(user)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      assert {:ok, _user} = Auth.disable_mfa(code, subject)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               nil,
               %RequestContext{}
             ) ==
               {:error, :mfa_proof_stale}

      refute Repo.one(UserToken.Query.by_context("session"))
    end

    test "current user fields are not an MFA proof", %{user: user} do
      verified_token_id = verify_magic_link(user)

      forged = %{
        user_id: user.id,
        mfa_enabled_at: user.mfa_enabled_at,
        updated_at: user.updated_at
      }

      assert Auth.complete_magic_link_mfa_sign_in(
               forged,
               verified_token_id,
               nil,
               %RequestContext{}
             ) ==
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

      assert Auth.issue_email_change_code("new@example.com", subject) == :ok

      assert_received {:email, email}
      assert [{_, ^current}] = email.to
      assert email.subject =~ "email change"
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)
    end

    test "emails the fresh DB address when the subject actor snapshot is stale", %{
      user: user,
      subject: subject
    } do
      old_email = user.email
      current_email = Fixtures.Random.unique_email()
      Fixtures.Users.update_email(user, current_email)

      assert subject.actor.email == old_email

      assert Auth.issue_email_change_code("new@example.com", subject) == :ok

      assert_received {:email, email}
      assert [{_, ^current_email}] = email.to
    end

    test "issuing again replaces the prior code (single outstanding)", %{subject: subject} do
      :ok = Auth.issue_email_change_code("first@example.com", subject)
      assert_received {:email, first_email}
      first_code = Fixtures.Auth.code_from_email(first_email)

      :ok = Auth.issue_email_change_code("second@example.com", subject)
      assert_received {:email, second_email}
      second_code = Fixtures.Auth.code_from_email(second_email)

      # The first code is gone; only the latest issuance completes the change.
      assert Auth.confirm_email_change("first@example.com", first_code, subject) ==
               {:error, :invalid}

      assert {:ok, %User{email: "second@example.com"}} =
               Auth.confirm_email_change("second@example.com", second_code, subject)
    end

    test "direct starts and begin share one issuance budget without replacing on rejection", %{
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for index <- 1..4 do
        assert Auth.issue_email_change_code("direct-#{index}@example.com", subject) == :ok
        assert_received {:email, _}
      end

      assert Auth.begin_email_change("latest@example.com", subject) == {:ok, :code}
      assert_received {:email, latest_email}
      latest_code = Fixtures.Auth.code_from_email(latest_email)

      assert Auth.issue_email_change_code("rejected@example.com", subject) ==
               {:error, :rate_limited}

      refute_received {:email, _}

      # A refused resend never deletes the live token it failed to replace.
      assert {:ok, %User{email: "latest@example.com"}} =
               Auth.confirm_email_change("latest@example.com", latest_code, subject)
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

      assert Auth.begin_email_change("new@example.com", subject) == {:ok, :code}

      assert_received {:email, email}
      assert [{_, ^current}] = email.to
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)
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
      assert Auth.begin_email_change("new@example.com", subject) == {:ok, :totp}
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
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)
    end

    test "the code path applies the TOKEN-bound email, not the argument passed to confirm", %{
      subject: subject
    } do
      {:ok, :code} = Auth.begin_email_change("bound@example.com", subject)
      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      # The emailed code is bound to "bound@example.com"; even though a different
      # target is passed here, the binding wins — a confirm can't swap the target.
      assert {:ok, %User{email: "bound@example.com"}} =
               Auth.confirm_email_change("other@example.com", code, subject)
    end

    test "a wrong code spends an attempt and the right code still completes", %{
      subject: subject
    } do
      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      wrong_code = if code == "000000", do: "000001", else: "000000"

      assert Auth.confirm_email_change("new@example.com", wrong_code, subject) ==
               {:error, :invalid}

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)

      assert Auth.confirm_email_change("new@example.com", code, subject) ==
               {:error, :invalid}
    end

    test "the durable attempt budget survives replacement tokens", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      {:ok, :code} = Auth.begin_email_change("first@example.com", subject)
      assert_received {:email, first_email}
      first_code = Fixtures.Auth.code_from_email(first_email)
      wrong_first = if first_code == "000000", do: "000001", else: "000000"

      for _ <- 1..3 do
        assert Auth.confirm_email_change("first@example.com", wrong_first, subject) ==
                 {:error, :invalid}
      end

      :ok = Auth.issue_email_change_code("latest@example.com", subject)
      assert_received {:email, latest_email}
      latest_code = Fixtures.Auth.code_from_email(latest_email)
      wrong_latest = if latest_code == "000000", do: "000001", else: "000000"

      for _ <- 1..2 do
        assert Auth.confirm_email_change("latest@example.com", wrong_latest, subject) ==
                 {:error, :invalid}
      end

      assert Auth.confirm_email_change("latest@example.com", latest_code, subject) ==
               {:error, :rate_limited}

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

      assert {:ok, %User{email: "latest@example.com"}} =
               Auth.confirm_email_change("latest@example.com", latest_code, subject)
    end

    test "an expired or missing inbox code cannot change the email", %{
      user: user,
      subject: subject
    } do
      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)
      age_tokens(user.id, 16)

      assert Auth.confirm_email_change("new@example.com", code, subject) ==
               {:error, :invalid}

      assert Auth.confirm_email_change("new@example.com", "123456", subject) ==
               {:error, :invalid}

      assert Repo.reload!(user).email == user.email
    end

    test "the new address lands UNCONFIRMED and gets its own verification email", %{
      user: user,
      subject: subject
    } do
      assert user.confirmed_at

      {:ok, :code} = Auth.begin_email_change("moved@example.com", subject)
      assert_received {:email, step_up}
      code = Fixtures.Auth.code_from_email(step_up)

      assert {:ok, %User{email: "moved@example.com"} = updated} =
               Auth.confirm_email_change("moved@example.com", code, subject)

      # The step-up proved control of the OLD inbox, so the new address is not
      # verified: a typo'd or attacker-supplied address must not inherit the
      # confirmation, which would suppress the verify banner and make it eligible
      # as the account's billing contact.
      refute updated.confirmed_at
      refute Repo.reload!(user).confirmed_at

      assert_received {:email, confirmation}
      assert confirmation.to == [{"", "moved@example.com"}]
    end

    test "the address update replaces every old address credential atomically", %{
      user: user,
      subject: subject
    } do
      {magic_id, magic_nonce, magic_secret} = request_magic_link(user)
      assert {:ok, _user} = Auth.verify_magic_link(magic_id, magic_secret, magic_nonce)
      old_confirmation = Fixtures.Auth.create_confirmation_token!(user)
      enrollment_code = issue_mfa_enrollment_code(subject)
      assert Repo.one(UserToken.Query.by_context("mfa_enrollment"))

      user
      |> UserToken.Changeset.pending_mfa_enrollment(Crypto.hash("pending-enrollment"), 5)
      |> Repo.insert!()

      assert Repo.one(UserToken.Query.by_context("mfa_enrollment_pending"))

      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, step_up}
      code = Fixtures.Auth.code_from_email(step_up)

      assert {:ok, %User{email: "new@example.com"}} =
               Auth.confirm_email_change("new@example.com", code, subject)

      assert Auth.verify_magic_link(magic_id, magic_secret, magic_nonce) ==
               {:error, :invalid_or_expired}

      assert Auth.complete_magic_link_sign_in(
               user.id,
               magic_id,
               nil,
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      assert Auth.confirm_user_by_token(old_confirmation) == {:error, :invalid_or_expired}
      assert Auth.verify_mfa_enrollment_code(enrollment_code, subject) == {:error, :invalid}
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment"))
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment_pending"))

      assert [%UserToken{context: "confirm", sent_to: "new@example.com"}] =
               UserToken.Query.by_user_id(user.id) |> Repo.all()
    end

    test "a rejected address update rolls back the factor and every credential change", %{
      user: user,
      subject: subject
    } do
      existing = Fixtures.Users.create_user()
      secret = Auth.generate_mfa_secret()
      {enrolled, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      {magic_id, magic_nonce, magic_secret} = request_magic_link(enrolled)
      assert {:ok, _user} = Auth.verify_magic_link(magic_id, magic_secret, magic_nonce)
      old_confirmation = Fixtures.Auth.create_confirmation_token!(enrolled)
      otp = NimbleTOTP.verification_code(secret)

      assert {:error, %Ecto.Changeset{}} =
               Auth.confirm_email_change(existing.email, otp, subject)

      reloaded = Repo.reload!(user)
      assert reloaded.email == user.email
      assert reloaded.mfa_last_used_at == nil
      refute_received {:email, _}

      assert {:ok, _user} = Auth.verify_magic_link(magic_id, magic_secret, magic_nonce)
      assert {:ok, _user} = Auth.confirm_user_by_token(old_confirmation)

      refute Repo.exists?(
               Emisar.Audit.Event.Query.all()
               |> Emisar.Audit.Event.Query.by_event_type("user.email_changed")
               |> Emisar.Audit.Event.Query.by_actor_id(user.id)
             )
    end

    test "a wrong code is rejected and the email is unchanged", %{user: user, subject: subject} do
      {:ok, :code} = Auth.begin_email_change("new@example.com", subject)
      assert_received {:email, _email}

      assert Auth.confirm_email_change("new@example.com", "000000", subject) == {:error, :invalid}
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

      assert Auth.confirm_email_change("new@example.com", "000000", subject) == {:error, :invalid}
      assert Repo.reload!(user).email == user.email
    end

    test "shares the MFA attempt cap with the disable step-up", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert Auth.disable_mfa("000000", subject) == {:error, :invalid_code}
      end

      # The disable misses spent the window, so the genuine TOTP is refused
      # before verification: the email stands and the code was never consumed.
      otp = NimbleTOTP.verification_code(secret)
      assert Auth.confirm_email_change("new@example.com", otp, subject) == {:error, :rate_limited}

      reloaded = Repo.reload!(user)
      assert reloaded.email == user.email
      assert reloaded.mfa_last_used_at == nil
    end
  end

  describe "deliver_confirmation_instructions/3" do
    test "issues a fresh token, emails the confirm link, and returns :ok" do
      user = Fixtures.Users.create_user(confirmed?: false)

      assert Auth.deliver_confirmation_instructions(user) == :ok

      assert_received {:email, email}
      assert [{_, to}] = email.to
      assert to == user.email
      assert email.subject =~ "Confirm"
    end

    test "includes the account and request origin when they are available" do
      user = Fixtures.Users.create_user(confirmed?: false)
      account = Fixtures.Accounts.create_account(name: "Northstar")
      context = %RequestContext{ip_address: "203.0.113.18"}

      assert Auth.deliver_confirmation_instructions(user, account, context) == :ok

      assert_received {:email, email}

      assert email.text_body =~
               "emisar sign-in for Northstar (http://localhost/app/#{account.slug})"

      refute email.text_body =~ "Requested from:"
      assert email.text_body =~ "203.0.113.18"
    end
  end

  describe "confirm_user_by_token/2" do
    setup do
      %{user: Fixtures.Users.create_user(confirmed?: false)}
    end

    test "issue + consume marks the user confirmed", %{user: user} do
      refute user.confirmed_at

      raw = Fixtures.Auth.create_confirmation_token!(user)
      assert {:ok, %User{confirmed_at: ts}} = Auth.confirm_user_by_token(raw)
      assert %DateTime{} = ts
    end

    test "a garbage token returns invalid_or_expired" do
      assert Auth.confirm_user_by_token("not-a-real-token") == {:error, :invalid_or_expired}
    end

    # 7-day window (confirm).
    test "a confirm token just inside 7 days still confirms", %{user: user} do
      raw = Fixtures.Auth.create_confirmation_token!(user)
      # 7 days minus an hour is still inside the window.
      age_tokens(user.id, 7 * 24 * 60 - 60)

      assert {:ok, %User{confirmed_at: %DateTime{}}} = Auth.confirm_user_by_token(raw)
    end

    test "a confirm token just past 7 days no longer confirms", %{user: user} do
      raw = Fixtures.Auth.create_confirmation_token!(user)
      # 7 days plus an hour is past the window.
      age_tokens(user.id, 7 * 24 * 60 + 60)

      assert Auth.confirm_user_by_token(raw) == {:error, :invalid_or_expired}
    end

    # A soft-deleted user behind a live token is the same dead-link outcome.
    test "a confirm link whose user was soft-deleted no longer confirms", %{user: user} do
      raw = Fixtures.Auth.create_confirmation_token!(user)

      Fixtures.Users.mark_user_as_deleted(user)

      assert Auth.confirm_user_by_token(raw) == {:error, :invalid_or_expired}
    end

    test "a confirm link cannot confirm a different current address", %{user: user} do
      raw = Fixtures.Auth.create_confirmation_token!(user)
      Fixtures.Users.update_email(user, Fixtures.Random.unique_email())

      assert Auth.confirm_user_by_token(raw) == {:error, :invalid_or_expired}
      refute Repo.reload!(user).confirmed_at
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

  describe "issue_mfa_enrollment_code/1" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, subject: subject}
    end

    test "reports sent delivery and records the credential request without sensitive payload", %{
      subject: subject
    } do
      assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :sent}
      assert_received {:email, _email}

      assert [event] = events_of_type("user.mfa_enrollment_requested")
      assert event.payload == %{}
    end

    test "reports a suppressed current address without pretending a code was sent", %{
      user: user,
      subject: subject
    } do
      assert {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :suppressed}
      refute_received {:email, _email}
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment"))
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment_pending"))
    end

    test "reports a mail-provider failure without activating an undelivered code", %{
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert Auth.issue_mfa_enrollment_code(subject) == {:error, {:failed, :boom}}
      refute_received {:email, _email}
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment"))
      refute Repo.one(UserToken.Query.by_context("mfa_enrollment_pending"))
    end

    test "a suppressed resend preserves the code already delivered", %{
      user: user,
      subject: subject
    } do
      delivered_code = issue_mfa_enrollment_code(subject)
      assert {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :suppressed}
      refute_received {:email, _email}
      assert {:ok, _proof} = Auth.verify_mfa_enrollment_code(delivered_code, subject)
    end

    test "a failed resend preserves the code already delivered", %{subject: subject} do
      delivered_code = issue_mfa_enrollment_code(subject)
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert Auth.issue_mfa_enrollment_code(subject) == {:error, {:failed, :boom}}
      refute_received {:email, _email}
      assert {:ok, _proof} = Auth.verify_mfa_enrollment_code(delivered_code, subject)
    end
  end

  describe "verify_mfa_enrollment_code/2" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      session_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      %{
        user: user,
        subject: subject,
        secret: Auth.generate_mfa_secret(),
        session_token: session_token
      }
    end

    test "the emailed code is single-use and enables only its user", %{
      user: user,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      code = issue_mfa_enrollment_code(subject)

      assert Auth.verify_mfa_enrollment_code("000000", subject) == {:error, :invalid}
      assert {:ok, proof} = Auth.verify_mfa_enrollment_code(code, subject)
      assert Auth.verify_mfa_enrollment_code(code, subject) == {:error, :invalid}

      assert {:ok, %User{id: id, mfa_enabled_at: %DateTime{}}, codes} =
               Auth.enable_mfa(
                 secret,
                 NimbleTOTP.verification_code(secret),
                 proof,
                 session_token,
                 subject
               )

      assert id == user.id
      assert length(codes) == 10
    end

    test "a forged proof cannot enroll or upgrade the email-change factor", %{
      user: user,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               "forged",
               session_token,
               subject
             ) == {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(user).mfa_enabled_at
      assert Auth.begin_email_change("attacker@example.com", subject) == {:ok, :code}
      assert_received {:email, _current_inbox_code}
    end

    test "a code sent before an email change proves neither the new inbox nor enrollment", %{
      user: user,
      subject: subject
    } do
      code = issue_mfa_enrollment_code(subject)
      new_email = Fixtures.Random.unique_email()
      Fixtures.Users.update_email(user, new_email)

      assert Auth.verify_mfa_enrollment_code(code, subject) == {:error, :invalid}

      refute Repo.one(
               UserToken.Query.by_user_id(user.id)
               |> UserToken.Query.by_context("mfa_enrollment")
             )
    end

    test "a proof becomes stale after any intervening user-row change", %{
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      assert {:ok, _updated} = Users.update_user_profile(%{full_name: "Changed"}, subject)

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               proof,
               session_token,
               subject
             ) == {:error, :mfa_enrollment_proof_stale}
    end

    test "an expired proof is refused", %{
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      signing_secret = Application.fetch_env!(:emisar, :email_link_secret)

      assert {:ok, payload} =
               Phoenix.Token.verify(signing_secret, "mfa enrollment proof", proof, max_age: 300)

      expired =
        Phoenix.Token.sign(signing_secret, "mfa enrollment proof", payload,
          signed_at: System.system_time(:second) - 301
        )

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               expired,
               session_token,
               subject
             ) == {:error, :mfa_enrollment_proof_stale}
    end

    test "delivery is bounded and first exhaustion emits one MFA signal", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _ <- 1..5 do
        issue_mfa_enrollment_code(subject)
      end

      assert Auth.issue_mfa_enrollment_code(subject) == {:error, :rate_limited}
      refute_received {:email, _}

      assert [event] = events_of_type("user.mfa_rate_limited")
      assert event.payload["scope"] == "mfa_enrollment_issue"
      assert event.payload["attempt_limit"] == 5
      assert event.payload["window_seconds"] == 900
    end

    test "email-change and enrollment verification share the inbox budget", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      enrollment_code = issue_mfa_enrollment_code(subject)

      for _ <- 1..3 do
        assert Auth.verify_mfa_enrollment_code("000000", subject) == {:error, :invalid}
      end

      assert Auth.issue_email_change_code("new@example.com", subject) == :ok
      assert_received {:email, _email_change_code}

      for _ <- 1..2 do
        assert Auth.confirm_email_change("new@example.com", "000000", subject) ==
                 {:error, :invalid}
      end

      assert Auth.verify_mfa_enrollment_code(enrollment_code, subject) == {:error, :rate_limited}

      assert [_event] = events_of_type("user.inbox_step_up_rate_limited")
    end
  end

  describe "enable_mfa/5" do
    setup do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      session_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      %{
        user: user,
        subject: subject,
        secret: Auth.generate_mfa_secret(),
        session_token: session_token
      }
    end

    test "with the correct OTP persists the secret + returns recovery codes", %{
      user: user,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      sibling_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      # Fixtures.Users.enroll_mfa calls Auth.enable_mfa with a single retry across the 30s-window
      # straddle (code-gen vs validation), so this success-contract assertion can't
      # flake on a microsecond boundary.
      assert {:ok, %User{mfa_secret: ^secret, mfa_enabled_at: %DateTime{}} = updated, codes} =
               Fixtures.Users.enroll_mfa(secret, subject, session_token: session_token)

      assert is_list(codes) and length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
      # The stored set is the digests, not the plaintext.
      assert length(updated.mfa_recovery_codes) == 10
      refute Enum.any?(codes, &(&1 in updated.mfa_recovery_codes))

      assert {:ok, ^updated, current_session} =
               Auth.fetch_user_and_token_by_session_token(session_token)

      assert current_session.mfa_enrollment_verified_at == updated.mfa_enabled_at

      assert {:ok, ^updated, sibling_session} =
               Auth.fetch_user_and_token_by_session_token(sibling_token)

      assert sibling_session.mfa_enrollment_verified_at == nil
    end

    test "with the wrong OTP returns :invalid_otp (nothing persisted)", %{
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)

      assert Auth.enable_mfa(secret, "000000", proof, session_token, subject) ==
               {:error, :invalid_otp}
    end

    test "a revoked presented session rolls enrollment and its audit back", %{
      user: user,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      :ok = Auth.delete_session_token(session_token)

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               proof,
               session_token,
               subject
             ) == {:error, :session_not_found}

      refute Repo.reload!(user).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "an expired presented session rolls enrollment and its audit back", %{
      user: user,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      age_tokens(user.id, 61 * 24 * 60)

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               proof,
               session_token,
               subject
             ) == {:error, :session_not_found}

      refute Repo.reload!(user).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "a foreign user's presented session rolls enrollment and its audit back", %{
      user: user,
      secret: secret,
      subject: subject
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      foreign = Fixtures.Users.create_user()
      foreign_token = Fixtures.Auth.create_session_token!(foreign, :magic_link, nil)

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               proof,
               foreign_token,
               subject
             ) == {:error, :session_not_found}

      refute Repo.reload!(user).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "a non-session credential rolls enrollment and its audit back", %{
      user: user,
      secret: secret,
      subject: subject
    } do
      proof = Fixtures.Users.mfa_enrollment_proof(subject)
      {raw_token, digest} = Crypto.session_token()

      user
      |> UserToken.Changeset.hashed(digest, "confirm", user.email)
      |> Repo.insert!()

      assert Auth.enable_mfa(
               secret,
               NimbleTOTP.verification_code(secret),
               proof,
               raw_token,
               subject
             ) == {:error, :session_not_found}

      refute Repo.reload!(user).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
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

    test "leaves the caller's sessions signed in", %{secret: secret, subject: subject} do
      {user, [code | _]} = Fixtures.Users.enable_mfa!(secret, subject)
      token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())

      assert {:ok, %User{mfa_enabled_at: nil}} = Auth.disable_mfa(code, subject)

      # Turning your own factor off is not a compromise signal, so it does not
      # sign you out. The claim it stripped is `session_mfa_verified?/2`'s, which
      # binds the session's proof to the enrollment it was taken against. The
      # sockets ARE dropped so each re-decides — proven end-to-end in
      # `EmisarWeb.MfaDisableDisconnectTest`, since the disconnect handler lives
      # in `emisar_web` and is a no-op in this `:emisar`-only test process.
      assert {:ok, %User{}, _session} = Auth.fetch_user_and_token_by_session_token(token)
    end

    test "rejects a wrong code and leaves MFA enabled", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert Auth.disable_mfa("not-a-real-code", subject) == {:error, :invalid_code}
      assert %User{mfa_enabled_at: %DateTime{}} = Repo.reload!(subject.actor)
    end

    test "rejects a missing code and leaves MFA enabled", %{secret: secret, subject: subject} do
      {_user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert Auth.disable_mfa(nil, subject) == {:error, :invalid_code}
      assert %User{mfa_enabled_at: %DateTime{}} = Repo.reload!(subject.actor)
    end

    test "shares the MFA attempt cap with sign-in without consuming a recovery code", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, [code | _]} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(user, {:totp, "000000"}) == {:error, :invalid}
      end

      # The sign-in misses spent the window, so a genuine recovery code is
      # refused before the consume — MFA stays on and the code stays usable.
      assert Auth.disable_mfa(code, subject) == {:error, :rate_limited}

      reloaded = Repo.reload!(user)
      assert %DateTime{} = reloaded.mfa_enabled_at
      assert reloaded.mfa_recovery_codes == user.mfa_recovery_codes
    end
  end

  describe "regenerate_mfa_recovery_codes/2" do
    setup do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "issues a fresh set and invalidates the old (MFA stays enabled)", %{
      secret: secret,
      subject: subject
    } do
      {:ok, _user, [old_code | _]} = Fixtures.Users.enroll_mfa(secret, subject)
      otp = NimbleTOTP.verification_code(secret)

      assert {:ok, %User{mfa_enabled_at: %DateTime{}} = user, new_codes} =
               Auth.regenerate_mfa_recovery_codes(otp, subject)

      assert length(new_codes) == 10
      # MFA stays enabled; the old plaintext code no longer matches, a new one does.
      assert Auth.verify_mfa_challenge(user, {:recovery_code, old_code}) == {:error, :invalid}

      assert {:ok, _proof} =
               Auth.verify_mfa_challenge(Repo.reload!(user), {:recovery_code, hd(new_codes)})
    end

    test "an existing recovery code can prove a lost-authenticator regeneration", %{
      secret: secret,
      subject: subject
    } do
      {:ok, _user, [proof_code | old_codes]} = Fixtures.Users.enroll_mfa(secret, subject)

      assert {:ok, updated, new_codes} =
               Auth.regenerate_mfa_recovery_codes(proof_code, subject)

      assert length(new_codes) == 10
      refute Enum.any?([proof_code | old_codes], &(Crypto.hash(&1) in updated.mfa_recovery_codes))
    end

    test "two concurrent recovery proofs produce one authoritative replacement", %{
      secret: secret,
      subject: subject
    } do
      {:ok, user, [proof_a, proof_b | _]} = Fixtures.Users.enroll_mfa(secret, subject)

      results =
        [proof_a, proof_b]
        |> Enum.map(&regenerate_recovery_codes_task(&1, subject))
        |> Enum.map(&Task.await(&1, 5_000))

      assert [{:ok, _updated, winner_codes}] =
               Enum.filter(results, &match?({:ok, %User{}, _codes}, &1))

      assert Enum.count(results, &(&1 == {:error, :invalid_code})) == 1
      assert Repo.reload!(user).mfa_recovery_codes == Enum.map(winner_codes, &Crypto.hash/1)
    end

    test "two concurrent submissions of one TOTP produce one success and one replay", %{
      secret: secret,
      subject: subject
    } do
      {:ok, user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)
      otp = NimbleTOTP.verification_code(secret)

      results =
        otp
        |> List.duplicate(2)
        |> Enum.map(&regenerate_recovery_codes_task(&1, subject))
        |> Enum.map(&Task.await(&1, 5_000))

      assert [{:ok, _updated, winner_codes}] =
               Enum.filter(results, &match?({:ok, %User{}, _codes}, &1))

      assert Enum.count(results, &(&1 == {:error, :replay})) == 1
      assert Repo.reload!(user).mfa_recovery_codes == Enum.map(winner_codes, &Crypto.hash/1)
    end

    test "wrong or missing proof leaves the old code set unchanged", %{
      secret: secret,
      subject: subject
    } do
      {:ok, user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)
      old_digests = user.mfa_recovery_codes

      assert Auth.regenerate_mfa_recovery_codes("not-a-recovery-code", subject) ==
               {:error, :invalid_code}

      assert Auth.regenerate_mfa_recovery_codes(nil, subject) == {:error, :invalid_code}
      assert Repo.reload!(user).mfa_recovery_codes == old_digests

      assert [event] = events_of_type("user.mfa_failed")
      assert event.payload["reason"] == "invalid_recovery_code"
      assert events_of_type("user.mfa_recovery_codes_regenerated") == []
    end

    test "the shared attempt cap refuses even a valid proof without replacing codes", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {:ok, user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)
      old_digests = user.mfa_recovery_codes
      stale_otp = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 90)

      for _ <- 1..5 do
        assert Auth.regenerate_mfa_recovery_codes(stale_otp, subject) == {:error, :invalid_code}
      end

      assert Auth.regenerate_mfa_recovery_codes(
               NimbleTOTP.verification_code(secret),
               subject
             ) == {:error, :rate_limited}

      assert Repo.reload!(user).mfa_recovery_codes == old_digests
      assert [_event] = events_of_type("user.mfa_rate_limited")
      assert events_of_type("user.mfa_recovery_codes_regenerated") == []
    end

    test "a stale enabled subject is refused after the locked row is disabled", %{
      secret: secret,
      subject: subject
    } do
      {:ok, user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

      assert {:ok, _disabled} =
               Users.update_user_mfa(user.id, nil, nil, [],
                 audit: &Audit.user_changesets(&1, "user.mfa_disabled")
               )

      assert Auth.regenerate_mfa_recovery_codes(
               NimbleTOTP.verification_code(secret),
               subject
             ) == {:error, :mfa_not_enabled}

      assert events_of_type("user.mfa_recovery_codes_regenerated") == []
    end

    test "refuses when MFA is not enabled", %{subject: subject} do
      assert Auth.regenerate_mfa_recovery_codes("000000", subject) ==
               {:error, :mfa_not_enabled}
    end
  end

  defp regenerate_recovery_codes_task(code, subject),
    do: Task.async(Auth, :regenerate_mfa_recovery_codes, [code, subject])

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
        assert Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000) == :ok
      end

      assert Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :exhausted}

      assert Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :capped}

      window = Repo.get_by!(SecurityAttemptWindow, user_id: user.id, scope: :mfa_challenge)
      assert window.attempt_count == 6

      expired = ~U[2001-01-01 00:05:00.000000Z]

      window
      |> Ecto.Changeset.change(
        window_started_at: DateTime.add(expired, -300, :second),
        window_expires_at: expired
      )
      |> Repo.update!()

      assert Auth.check_security_attempt(user, :mfa_challenge, 5, 300_000) == :ok

      reset = Repo.reload!(window)
      assert reset.attempt_count == 1
      assert DateTime.compare(reset.window_started_at, expired) == :gt
      assert DateTime.compare(reset.window_expires_at, reset.window_started_at) == :gt
    end

    test "a persistence failure rejects the credential attempt", %{subject: subject} do
      missing_user = %{subject.actor | id: Repo.generate_id()}

      assert Auth.check_security_attempt(missing_user, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :store_unavailable}
    end
  end

  describe "check_security_attempt/5" do
    test "carries request provenance onto the first over-limit audit signal" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      context = %RequestContext{request_id: "req-direct-security-attempt"}

      assert Auth.check_security_attempt(
               subject.actor,
               :mfa_challenge,
               1,
               300_000,
               context
             ) == :ok

      assert Auth.check_security_attempt(
               subject.actor,
               :mfa_challenge,
               1,
               300_000,
               context
             ) == {:error, :rate_limited, :exhausted}

      assert [event] = events_of_type("user.mfa_rate_limited")
      assert event.request_id == "req-direct-security-attempt"
    end

    test "logs each credential limit under its accurate event type" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for scope <- [:email_change_issue, :inbox_step_up] do
        context = %RequestContext{request_id: "req-#{scope}"}

        assert Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context) == :ok

        assert Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context) ==
                 {:error, :rate_limited, :exhausted}

        assert Auth.check_security_attempt(subject.actor, scope, 1, 300_000, context) ==
                 {:error, :rate_limited, :capped}
      end

      assert [issue_event] = events_of_type("user.email_change_rate_limited")
      assert issue_event.payload["scope"] == "email_change_issue"
      assert issue_event.request_id == "req-email_change_issue"

      assert [verify_event] = events_of_type("user.inbox_step_up_rate_limited")
      assert verify_event.payload["scope"] == "inbox_step_up"
      assert verify_event.request_id == "req-inbox_step_up"
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
      assert Auth.verify_mfa_challenge(user, {:totp, otp}) == {:error, :replay}
    end

    test "rejects an invalid OTP", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(user, {:totp, "000000"}) == {:error, :invalid}
    end

    test "a malformed factor is the catch-all :invalid" do
      assert Auth.verify_mfa_challenge(%User{}, {:totp, nil}) == {:error, :invalid}
      assert Auth.verify_mfa_challenge(%User{}, {:recovery_code, nil}) == {:error, :invalid}
      assert Auth.verify_mfa_challenge(%User{}, {:sms, "000000"}) == {:error, :invalid}
    end

    # a non-numeric OTP is rejected, and because the replay guard only stamps
    # on a *valid* code, the real code still works right after (the bad attempt
    # didn't burn the current bucket).
    test "rejects a non-numeric OTP without burning the live code", %{
      secret: secret,
      subject: subject
    } do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(user, {:totp, "abcdef"}) == {:error, :invalid}

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
      assert Auth.verify_mfa_challenge(user, {:totp, otp}) == {:error, :invalid}
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
      assert Auth.verify_mfa_challenge(user, {:totp, otp1}) == {:error, :invalid}
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
      assert Auth.verify_mfa_challenge(user, {:recovery_code, code}) == {:error, :invalid}

      # Consuming one code doesn't invalidate the rest of the set.
      assert {:ok, _proof} = Auth.verify_mfa_challenge(user, {:recovery_code, other_code})
    end

    test "rejects an unknown recovery code as :invalid", %{secret: secret, subject: subject} do
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(user, {:recovery_code, "not-a-real-code"}) ==
               {:error, :invalid}
    end

    test "counts both factors against one per-user window and refuses the sixth attempt", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(user, {:totp, "000000"}) == {:error, :invalid}
      end

      # The window is exhausted: even the genuine current code is refused, and
      # switching to the recovery factor doesn't buy more attempts.
      otp = NimbleTOTP.verification_code(secret)
      assert Auth.verify_mfa_challenge(user, {:totp, otp}) == {:error, :rate_limited}

      assert Auth.verify_mfa_challenge(user, {:recovery_code, "not-a-real-code"}) ==
               {:error, :rate_limited}

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

  describe "verify_current_session_mfa_challenge/2" do
    test "uses the authenticated Subject actor and rejects a non-user actor" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, subject)
      subject = %{subject | actor: user}

      assert {:ok, _proof} =
               Auth.verify_current_session_mfa_challenge(
                 {:totp, NimbleTOTP.verification_code(secret)},
                 subject
               )

      assert Auth.verify_current_session_mfa_challenge(
               {:recovery_code, "not-a-real-code"},
               %Subject{}
             ) == {:error, :unauthorized}
    end
  end

  describe "issue_member_mfa_reset_proof/5" do
    test "binds a verified local source to the actor, account, target, and target epoch" do
      reset = member_mfa_reset_auth_fixture()

      assert {:ok, payload} = Auth.verify_member_mfa_reset_proof(reset.reset_proof)
      assert payload.actor_id == reset.actor.id
      assert payload.account_id == reset.account.id
      assert payload.target_membership_id == reset.target_membership.id
      assert payload.target_mfa_enabled_at == reset.target.mfa_enabled_at
      assert payload.actor_session_token_digest == reset.actor_session_token_digest
      assert payload.source == {:local, reset.local_proof}

      assert Auth.issue_member_mfa_reset_proof(
               reset.target_membership,
               %{reset.target | mfa_enabled_at: nil},
               {:local, reset.local_proof},
               reset.actor_session_token_digest,
               reset.subject
             ) == {:error, :mfa_reset_proof_stale}
    end
  end

  describe "verify_member_mfa_reset_proof/1" do
    test "uses a separate salt and a 120-second lifetime" do
      reset = member_mfa_reset_auth_fixture()
      signing_secret = Application.fetch_env!(:emisar, :email_link_secret)

      assert Auth.verify_member_mfa_reset_proof(reset.local_proof) ==
               {:error, :mfa_reset_proof_stale}

      assert {:ok, payload} =
               Phoenix.Token.verify(
                 signing_secret,
                 "member mfa reset proof",
                 reset.reset_proof,
                 max_age: 120
               )

      expired =
        Phoenix.Token.sign(signing_secret, "member mfa reset proof", payload,
          signed_at: System.system_time(:second) - 121
        )

      assert Auth.verify_member_mfa_reset_proof(expired) ==
               {:error, :mfa_reset_proof_stale}
    end
  end

  describe "verify_local_member_mfa_reset_source/2" do
    test "rechecks the embedded proof against the current locked actor row" do
      reset = member_mfa_reset_auth_fixture()

      assert Auth.verify_local_member_mfa_reset_source(
               {:local, reset.local_proof},
               reset.actor
             ) == :ok

      assert {:ok, changed} =
               Users.update_user_profile(
                 %{full_name: "Changed after verification"},
                 reset.subject
               )

      assert Auth.verify_local_member_mfa_reset_source(
               {:local, reset.local_proof},
               changed
             ) == {:error, :mfa_reset_proof_stale}
    end

    test "a fresh outer handoff cannot extend an expired local proof" do
      reset = member_mfa_reset_auth_fixture()
      signing_secret = Application.fetch_env!(:emisar, :email_link_secret)

      assert {:ok, payload} =
               Phoenix.Token.verify(
                 signing_secret,
                 "mfa sign-in proof",
                 reset.local_proof,
                 max_age: 120
               )

      expired =
        Phoenix.Token.sign(signing_secret, "mfa sign-in proof", payload,
          signed_at: System.system_time(:second) - 121
        )

      assert Auth.verify_local_member_mfa_reset_source({:local, expired}, reset.actor) ==
               {:error, :mfa_reset_proof_stale}
    end
  end

  describe "lock_member_mfa_reset_session/4" do
    test "accepts only the bound live actor session and SSO identity source" do
      reset = member_mfa_reset_auth_fixture()

      assert {:ok, %UserToken{user_id: actor_id}} =
               Auth.lock_member_mfa_reset_session(
                 Repo,
                 reset.actor_session_token_digest,
                 reset.actor.id,
                 {:local, reset.local_proof}
               )

      assert actor_id == reset.actor.id

      assert Auth.lock_member_mfa_reset_session(
               Repo,
               reset.actor_session_token_digest,
               reset.actor.id,
               {:sso, %{identity_id: Repo.generate_id()}}
             ) == {:error, :mfa_reset_proof_stale}
    end
  end

  describe "complete_current_session_mfa/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {enrolled, recovery_codes} = Fixtures.Users.enable_mfa!(secret, subject)
      session_token = Fixtures.Auth.create_session_token!(enrolled, :magic_link, nil)

      %{
        account: account,
        subject: %{subject | actor: enrolled},
        secret: secret,
        user: enrolled,
        recovery_codes: recovery_codes,
        session_token: session_token
      }
    end

    test "a TOTP proof stamps only the presented live session", %{
      user: user,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      sibling_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(
                 user,
                 {:totp, NimbleTOTP.verification_code(secret)}
               )

      assert {:ok, %UserToken{id: updated_id}} =
               Auth.complete_current_session_mfa(proof, session_token, subject)

      assert {:ok, current_user, current_session} =
               Auth.fetch_user_and_token_by_session_token(session_token)

      assert current_session.id == updated_id
      assert current_session.mfa_enrollment_verified_at == current_user.mfa_enabled_at

      assert {:ok, sibling_user, sibling_session} =
               Auth.fetch_user_and_token_by_session_token(sibling_token)

      assert sibling_user.id == current_user.id
      assert sibling_session.mfa_enrollment_verified_at == nil
    end

    test "a recovery proof adds local assurance without rewriting SSO provenance", %{
      user: user,
      account: account,
      subject: subject,
      recovery_codes: [recovery_code | _]
    } do
      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        })

      idp_verified_at = DateTime.utc_now()

      sso_token =
        Fixtures.Auth.create_session_token!(user, :sso, idp_verified_at, %{},
          user_identity_id: identity.id
        )

      sibling_token =
        Fixtures.Auth.create_session_token!(user, :sso, idp_verified_at, %{},
          user_identity_id: identity.id
        )

      sso_subject = %{
        subject
        | auth_method: :sso,
          mfa: true,
          user_identity_id: identity.id
      }

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:recovery_code, recovery_code})

      assert {:ok, _session} =
               Auth.complete_current_session_mfa(proof, sso_token, sso_subject)

      assert {:ok, current_user, session} =
               Auth.fetch_user_and_token_by_session_token(sso_token)

      assert session.auth_method == :sso
      assert session.user_identity_id == identity.id
      assert session.mfa_verified_at == idp_verified_at
      assert session.mfa_enrollment_verified_at == current_user.mfa_enabled_at

      assert {:ok, sibling_user, sibling_session} =
               Auth.fetch_user_and_token_by_session_token(sibling_token)

      assert sibling_user.id == current_user.id
      assert sibling_session.mfa_enrollment_verified_at == nil

      assert Auth.verify_mfa_challenge(current_user, {:recovery_code, recovery_code}) ==
               {:error, :invalid}
    end

    test "proof, subject, and token must all name the same user", %{
      user: user,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(
                 user,
                 {:totp, NimbleTOTP.verification_code(secret)}
               )

      {other_user, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      other_token = Fixtures.Auth.create_session_token!(other_user, :magic_link, nil)

      assert Auth.complete_current_session_mfa(proof, session_token, other_subject) ==
               {:error, :mfa_proof_stale}

      assert Auth.complete_current_session_mfa(proof, other_token, subject) ==
               {:error, :session_not_found}

      assert {:ok, _user, session} =
               Auth.fetch_user_and_token_by_session_token(session_token)

      assert session.mfa_enrollment_verified_at == nil
    end

    test "a revoked session grants nothing while the recovery code stays consumed", %{
      user: user,
      subject: subject,
      recovery_codes: [recovery_code | _],
      session_token: session_token
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(user, {:recovery_code, recovery_code})

      :ok = Auth.delete_session_token(session_token)

      assert Auth.complete_current_session_mfa(proof, session_token, subject) ==
               {:error, :session_not_found}

      assert Auth.verify_mfa_challenge(Repo.reload!(user), {:recovery_code, recovery_code}) ==
               {:error, :invalid}
    end

    test "an expired or wrong-context token cannot be upgraded", %{
      user: user,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(
                 user,
                 {:totp, NimbleTOTP.verification_code(secret)}
               )

      {wrong_context_token, digest} = Crypto.session_token()

      user
      |> UserToken.Changeset.hashed(digest, "confirm", user.email)
      |> Repo.insert!()

      assert Auth.complete_current_session_mfa(proof, wrong_context_token, subject) ==
               {:error, :session_not_found}

      age_tokens(user.id, 61 * 24 * 60)

      assert Auth.complete_current_session_mfa(proof, session_token, subject) ==
               {:error, :session_not_found}

      session =
        UserToken.Query.by_token_digest(Crypto.hash(session_token))
        |> Repo.one!()

      assert session.mfa_enrollment_verified_at == nil
    end

    test "a disable and re-enroll makes an in-flight proof stale", %{
      user: user,
      subject: subject,
      recovery_codes: [proof_code, disable_code | _],
      session_token: session_token
    } do
      assert {:ok, proof} = Auth.verify_mfa_challenge(user, {:recovery_code, proof_code})
      assert {:ok, disabled} = Auth.disable_mfa(disable_code, subject)

      next_subject = %{subject | actor: disabled, mfa: false, mfa_enrollment_verified_at: nil}

      {re_enrolled, _codes} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), next_subject)

      assert Auth.complete_current_session_mfa(
               proof,
               session_token,
               %{next_subject | actor: re_enrolled}
             ) == {:error, :mfa_proof_stale}

      assert {:ok, _user, session} =
               Auth.fetch_user_and_token_by_session_token(session_token)

      assert session.mfa_enrollment_verified_at == nil
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

      incomplete_enrollment = %{
        user_id: user.id,
        mfa_enabled_at: nil,
        updated_at: DateTime.utc_now()
      }

      incomplete_update = %{
        user_id: user.id,
        mfa_enabled_at: DateTime.utc_now(),
        updated_at: nil
      }

      assert Auth.mfa_proof_user_id(incomplete_enrollment) == nil
      assert Auth.mfa_proof_user_id(incomplete_update) == nil
    end
  end

  defp member_mfa_reset_auth_fixture do
    {_actor, account, subject} = Fixtures.Subjects.owner_subject()
    secret = Auth.generate_mfa_secret()
    {actor, _recovery_codes} = Fixtures.Users.enable_mfa!(secret, subject)
    subject = %{subject | actor: actor}

    target =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_mfa_state(
        mfa_secret: Auth.generate_mfa_secret(),
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: []
      )

    target_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: target.id,
        role: "operator"
      )

    {:ok, local_proof} =
      Auth.verify_current_session_mfa_challenge(
        {:totp, NimbleTOTP.verification_code(secret)},
        subject
      )

    actor = Repo.reload!(actor)
    subject = %{subject | actor: actor}
    actor_session_token = Fixtures.Auth.create_session_token!(actor, :magic_link, nil)
    actor_session_token_digest = Crypto.hash(actor_session_token)

    {:ok, reset_proof} =
      Auth.issue_member_mfa_reset_proof(
        target_membership,
        target,
        {:local, local_proof},
        actor_session_token_digest,
        subject
      )

    %{
      account: account,
      actor: actor,
      actor_session_token: actor_session_token,
      actor_session_token_digest: actor_session_token_digest,
      local_proof: local_proof,
      reset_proof: reset_proof,
      subject: subject,
      target: target,
      target_membership: target_membership
    }
  end
end
