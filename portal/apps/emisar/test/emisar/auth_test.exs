defmodule Emisar.AuthTest do
  use Emisar.DataCase, async: true
  import ExUnit.CaptureLog
  alias Emisar.{Accounts, Audit, Auth, Crypto, Fixtures, Mail, RequestContext}
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Auth.{SecurityAttemptWindow, Subject, UserToken}

  defp session_rows do
    UserToken.Query.by_context("session") |> Repo.all() |> Enum.sort_by(& &1.id)
  end

  defmodule RaisingSessionDisconnector do
    def disconnect_live_sessions(_topics), do: raise("handler must not run")
  end

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:session_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  # Backdate every token row of one Member so its `inserted_at` lands `minutes`
  # in the past — the only lever on the validity window, since
  # `UserToken.Query.not_expired/2` filters `inserted_at > ago(window)`.
  defp age_tokens(%Membership{} = member, minutes) do
    {n, _} =
      UserToken.Query.by_membership(member.account_id, member.id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -minutes, :minute)])

    n
  end

  # The raw secret only leaves Auth by email, so a test that must complete a
  # sign-in drives the real request workflow and reads the 6-character code back
  # out of the delivered message — exactly as an operator does.
  defp request_magic_link(%Account{} = account, email) do
    assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
             Auth.request_magic_link(account, email, %RequestContext{})

    assert_received {:email, sent}
    [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    {token_id, nonce, secret}
  end

  defp verify_magic_link(%Membership{} = member) do
    account = Repo.get!(Account, member.account_id)
    {token_id, nonce, secret} = request_magic_link(account, member.email)
    assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}
    token_id
  end

  defp events_of_type(event_type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  # Fires once, inside the step-up's own transaction, right after it spends the
  # emailed code: the member enrolls an authenticator in that window.
  def enroll_mfa_once_code_spent(_event, _measurements, metadata, {owner, handler, member}) do
    if self() == owner and metadata.source == "auth_user_tokens" and
         String.starts_with?(metadata.query, "DELETE") do
      :telemetry.detach(handler)

      Fixtures.Memberships.set_mfa_state(member,
        mfa_secret: Auth.generate_mfa_secret(),
        mfa_enabled_at: DateTime.utc_now()
      )
    end
  end

  defp email_member(_context) do
    account = Fixtures.Accounts.create_account()
    member = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    %{account: account, member: member, subject: Fixtures.Subjects.subject_for(member)}
  end

  defp begin_email_change_code(subject, address) do
    assert {:ok, :email} = Auth.begin_email_change(address, subject)
    assert_received {:email, mail}
    Fixtures.Auth.code_from_email(mail)
  end

  defp pending_email_change(subject, address) do
    code = begin_email_change_code(subject, address)
    assert {:ok, proof} = Auth.confirm_email_change(address, code, subject)
    assert_received {:email, mail}
    {proof, Fixtures.Auth.code_from_email(mail)}
  end

  defp issue_mfa_enrollment_code(subject) do
    assert Auth.issue_mfa_enrollment_code(subject) == {:ok, :sent}
    assert_received {:email, email}
    Fixtures.Auth.code_from_email(email)
  end

  defp browser_id, do: Crypto.random_secret()

  # An owner with TOTP enrolled through the real inbox proof.
  defp mfa_owner do
    {_owner, account, subject} = Fixtures.Subjects.owner_subject()
    secret = Auth.generate_mfa_secret()
    {member, codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
    %{account: account, member: member, secret: secret, codes: codes, subject: subject}
  end

  # One enabled connection per kind and workspace: a second route in the same
  # workspace takes `kind: :openid_connect`.
  defp sso_route(account, opts \\ []) do
    provider =
      Fixtures.SSO.create_identity_provider(
        account_id: account.id,
        kind: Keyword.get(opts, :kind, :okta),
        satisfies_mfa: Keyword.get(opts, :satisfies_mfa, false)
      )

    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        role: Keyword.get(opts, :role, "operator"),
        email_verified?: Keyword.get(opts, :email_verified?, false)
      )

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        membership: member
      })

    %{provider: provider, member: member, identity: identity}
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
               "Owners can manage the entire account, including billing and other owners, and access all runners and packs."

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

  describe "complete_sso_sign_in/5" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      %{provider: provider, member: member, identity: identity} = sso_route(account)

      %{
        account: account,
        identity: identity,
        provider: provider,
        subject: subject,
        member: member
      }
    end

    test "records the sign-in and mints an :sso session that freezes its route", %{
      account: account,
      identity: identity,
      provider: provider,
      member: member
    } do
      context = RequestContext.new(%{ip_address: "203.0.113.9", request_id: "req-sso"})
      provider = provider |> Ecto.Changeset.change(satisfies_mfa: true) |> Repo.update!()
      browser = browser_id()

      assert {:ok, token, true} =
               Auth.complete_sso_sign_in(member, identity, provider, browser, context)

      assert {:ok, %UserToken{auth_method: :sso, mfa_verified_at: %DateTime{}} = stored} =
               Auth.fetch_session_by_token(token, account.id)

      assert stored.membership_id == member.id
      assert stored.user_identity_id == identity.id
      assert stored.sso_issuer == provider.issuer
      assert stored.sso_provider_identifier == identity.provider_identifier
      assert stored.browser_digest == Crypto.hash(browser)
      # ip + user_agent ride in the token's `metadata` jsonb (string-keyed once persisted).
      assert stored.metadata["ip_address"] == "203.0.113.9"
      assert %DateTime{} = Repo.reload!(member).last_active_at

      assert [event] = events_of_type("user.signed_in")

      assert {event.account_id, event.actor_id, event.target_id} ==
               {account.id, member.id, member.id}

      assert event.payload == %{"method" => "sso"}
      assert event.request_id == "req-sso"
    end

    test "bounds session display metadata before persisting it", %{
      account: account,
      identity: identity,
      provider: provider,
      member: member
    } do
      context = RequestContext.new(%{user_agent: String.duplicate("x", 500)})

      assert {:ok, token, false} =
               Auth.complete_sso_sign_in(member, identity, provider, browser_id(), context)

      assert {:ok, %UserToken{} = stored} = Auth.fetch_session_by_token(token, account.id)

      refute stored.mfa_verified_at
      assert String.length(stored.metadata["user_agent"]) == 255
    end

    test "does not mint a session after the account is disabled", %{
      account: account,
      identity: identity,
      provider: provider,
      subject: subject,
      member: member
    } do
      sessions_before = session_rows()

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "support incident",
                 subject
               )

      assert Auth.complete_sso_sign_in(
               member,
               identity,
               provider,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :account_disabled}

      assert session_rows() == sessions_before
    end

    test "fails closed for a deleted, retired, rebound or moved identity and a disabled provider",
         %{account: account, identity: identity, provider: provider, member: member} do
      sessions_before = session_rows()
      context = %RequestContext{}

      Fixtures.SSO.disable_provider(provider)

      assert Auth.complete_sso_sign_in(member, identity, provider, browser_id(), context) ==
               {:error, :provider_disabled}

      provider = Repo.reload!(provider) |> Ecto.Changeset.change(enabled: true) |> Repo.update!()

      rebound =
        identity
        |> Ecto.Changeset.change(provider_identifier: "rebound-#{Ecto.UUID.generate()}")
        |> Repo.update!()

      # The callback asserted the identifier the identity carried then; a
      # rebind since must not mint under the new one.
      assert Auth.complete_sso_sign_in(member, identity, provider, browser_id(), context) ==
               {:error, :provider_disabled}

      other = Fixtures.Memberships.create_membership(account_id: account.id)
      moved = rebound |> Ecto.Changeset.change(membership_id: other.id) |> Repo.update!()

      assert Auth.complete_sso_sign_in(member, moved, provider, browser_id(), context) ==
               {:error, :membership_unavailable}

      retired = Fixtures.SSO.retire_identity(moved)

      assert Auth.complete_sso_sign_in(other, retired, provider, browser_id(), context) ==
               {:error, :provider_disabled}

      deleted = retired |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

      assert Auth.complete_sso_sign_in(other, deleted, provider, browser_id(), context) ==
               {:error, :provider_disabled}

      assert session_rows() == sessions_before
    end

    test "a provider pointed at another issuer since the callback mints nothing", %{
      identity: identity,
      provider: provider,
      member: member
    } do
      sessions_before = session_rows()

      provider
      |> Ecto.Changeset.change(issuer: "https://other-issuer.test")
      |> Repo.update!()

      assert Auth.complete_sso_sign_in(
               member,
               identity,
               provider,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :provider_disabled}

      assert session_rows() == sessions_before
    end

    test "a suspended or removed Member mints nothing", %{
      identity: identity,
      provider: provider,
      member: member
    } do
      sessions_before = session_rows()
      Fixtures.Memberships.suspend_membership(member)

      assert Auth.complete_sso_sign_in(
               member,
               identity,
               provider,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :membership_unavailable}

      assert session_rows() == sessions_before
    end

    test "a workspace without the SSO entitlement mints nothing", %{
      account: account,
      identity: identity,
      provider: provider,
      member: member
    } do
      Fixtures.Accounts.create_subscription(account, "team", status: "canceled")

      assert Auth.complete_sso_sign_in(
               member,
               identity,
               provider,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :provider_disabled}
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

  describe "disconnect_live_socket_topics/1" do
    # In the `:emisar`-only test process the configured handler's sibling app
    # isn't started, so this is a pure, best-effort no-op.
    test "is a best-effort :ok that deletes no token rows" do
      member = Fixtures.Memberships.create_membership()
      token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert Auth.disconnect_live_socket_topics([Auth.live_socket_topic(Crypto.hash(token))]) ==
               :ok

      assert Auth.disconnect_live_socket_topics([]) == :ok
      assert {:ok, %UserToken{}} = Auth.fetch_session_by_token(token, member.account_id)
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

  describe "broadcast_disconnect_for_membership/1" do
    test "reaches exactly this Member's session topics, none of a teammate's" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      teammate = Fixtures.Memberships.create_membership(account_id: account.id)
      mine = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      mine_too = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      _theirs = Fixtures.Auth.create_session_token!(teammate, :magic_link, nil)

      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.broadcast_disconnect_for_membership(owner) == :ok
      assert_receive {:session_disconnect, topics, false}

      assert Enum.sort(topics) ==
               Enum.sort(Enum.map([mine, mine_too], &Auth.live_socket_topic(Crypto.hash(&1))))

      assert {:ok, _} = Auth.fetch_session_by_token(mine, account.id)
    end
  end

  describe "request_magic_link/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      %{member: owner, account: account}
    end

    test "hands back only the browser half, emails the code naming the workspace, and verifies",
         %{member: member, account: account} do
      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery} = result} =
               Auth.request_magic_link(account, member.email, %RequestContext{})

      # Three keys and no more: the raw secret stays inside Auth, so no caller
      # can relay a sign-in credential it didn't earn.
      assert map_size(result) == 3
      assert delivery == {:ok, :sent}
      assert is_binary(token_id) and is_binary(nonce)

      assert_received {:email, sent}
      assert sent.to == [{"", member.email}]
      assert sent.text_body =~ "sign in to #{account.name}"
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      # The emailed half is a typable 6-char alphanumeric code, from an
      # unambiguous uppercase alphabet — no 0/O, 1/I/L, or U to misread.
      refute secret =~ ~r/[01ILOU]/

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}

      assert [event] = events_of_type("user.magic_link_issued")
      assert {event.account_id, event.actor_id} == {account.id, member.id}
    end

    test "returns before the code's email goes out, so the request cannot time a Member's address",
         %{member: member, account: account} do
      Emisar.Config.put_override(:emisar, :email_codes_async?, true)
      parent = self()

      # The send blocks until released: the request must already have returned.
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, fn _email ->
        send(parent, {:sending, self()})

        receive do
          :release -> nil
        end
      end)

      assert {:ok, %{delivery: {:ok, :queued}}} =
               Auth.request_magic_link(account, member.email, %RequestContext{})

      assert_receive {:sending, sender}, 2_000
      refute_received {:email, _sent}
      send(sender, :release)
      assert_receive {:email, %{to: [{"", address}]}}, 2_000
      assert address == member.email
    end

    test "a failed send logs the code's token and a label, never the provider's body", %{
      member: member,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :email_codes_async?, true)
      parent = self()

      # Postmark's refusal names the address it refused.
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, fn _email ->
        send(parent, {:sending, self()})
        {:error, {422, %{"Message" => "Found inactive addresses: #{member.email}."}}}
      end)

      log =
        capture_log(fn ->
          assert {:ok, %{token_id: token_id}} =
                   Auth.request_magic_link(account, member.email, %RequestContext{})

          assert_receive {:sending, sender}, 2_000
          ref = Process.monitor(sender)
          assert_receive {:DOWN, ^ref, :process, ^sender, _reason}, 2_000
          send(parent, {:token_id, token_id})
        end)

      assert_received {:token_id, token_id}
      assert log =~ "sign-in code not delivered token_id=#{token_id} reason=http_422"
      refute log =~ member.email
    end

    test "the address is matched case-insensitively", %{member: member, account: account} do
      {token_id, nonce, secret} = request_magic_link(account, String.upcase(member.email))
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}
    end

    test "issuing again replaces the prior outstanding token (single outstanding)", %{
      member: member,
      account: account
    } do
      {token_id1, nonce1, secret1} = request_magic_link(account, member.email)
      {token_id2, nonce2, secret2} = request_magic_link(account, member.email)

      # The first token is gone — re-issuing deleted it.
      assert Auth.verify_magic_link(token_id1, secret1, nonce1) == {:error, :invalid_or_expired}
      assert Auth.verify_magic_link(token_id2, secret2, nonce2) == {:ok, member.id}
    end

    test "a suppressed address is reported as suppressed and nothing is sent", %{
      member: member,
      account: account
    } do
      {:ok, _} = Mail.suppress(member.email, :hard_bounce, "bounce")

      assert {:ok, %{delivery: {:ok, :suppressed}}} =
               Auth.request_magic_link(account, member.email, %RequestContext{})

      refute_received {:email, _}
      assert %UserToken{context: "magic_link"} = Repo.one(UserToken)
    end

    test "a mailer failure is reported while the token stays outstanding", %{
      member: member,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery}} =
               Auth.request_magic_link(account, member.email, %RequestContext{})

      assert delivery == {:error, {:failed, :boom}}
      # The browser half still comes back and the row survives, so a resend from
      # the sent page is the operator's remedy — not a lost, already-audited link.
      assert is_binary(token_id) and is_binary(nonce)
      assert %UserToken{id: ^token_id, context: "magic_link"} = Repo.one(UserToken)
    end

    test "an unknown, unverified, suspended, pending or elsewhere-only address issues nothing",
         %{member: member, account: account} do
      unverified =
        Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false)

      suspended = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.suspend_membership(suspended)

      pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          invitation_token_digest: "pending-digest"
        )

      elsewhere = Fixtures.Memberships.create_membership()
      removed = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.mark_membership_as_deleted(removed)

      for email <- [
            "nobody-#{System.unique_integer([:positive])}@example.test",
            unverified.email,
            suspended.email,
            pending.email,
            elsewhere.email,
            removed.email
          ] do
        assert Auth.request_magic_link(account, email, %RequestContext{}) == {:error, :not_found},
               "#{email} was issued a code"
      end

      refute_received {:email, _}
      refute Repo.one(UserToken)
      assert Repo.reload!(member)
    end

    test "a workspace that requires SSO refuses the email code while a connection is enabled",
         %{member: member, account: account} do
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      assert Auth.request_magic_link(account, member.email, %RequestContext{}) ==
               {:error, :not_found}

      refute_received {:email, _}
      refute Repo.one(UserToken)

      # No usable connection left: the policy fails open so the workspace keeps a way in.
      Fixtures.SSO.disable_provider(provider)

      assert {:ok, %{delivery: {:ok, :sent}}} =
               Auth.request_magic_link(account, member.email, %RequestContext{})
    end

    test "a disabled or deleted workspace issues nothing", %{member: member, account: account} do
      Fixtures.Accounts.disable_account(account)

      assert Auth.request_magic_link(account, member.email, %RequestContext{}) ==
               {:error, :not_found}

      refute Repo.one(UserToken)
    end
  end

  describe "request_invitation_code/2" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      {:ok, ^email, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Invited Name"})

      %{account: account, subject: subject, invitation: invitation, intent: intent, email: email}
    end

    test "sends the code to the invited address only and the code carries the acceptance", %{
      account: account,
      invitation: invitation,
      intent: intent,
      email: email
    } do
      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
               Auth.request_invitation_code(intent, %RequestContext{})

      assert_received {:email, sent}
      assert sent.to == [{"", email}]
      assert sent.text_body =~ "sign in to #{account.name}"
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      code = Repo.get!(UserToken, token_id)
      assert code.membership_id == invitation.id
      assert code.metadata["invitation_token_digest"] == intent.token_digest
      assert code.metadata["invitation_display_name"] == "Invited Name"

      # Requesting accepts nothing.
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, invitation.id}
    end

    test "is not refused where the workspace requires SSO", %{
      account: account,
      intent: intent
    } do
      Fixtures.Accounts.create_subscription(account, "team")
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      assert {:ok, %{delivery: {:ok, :sent}}} =
               Auth.request_invitation_code(intent, %RequestContext{})
    end

    test "a rotated, accepted or expired invitation and a disabled workspace issue nothing", %{
      account: account,
      subject: subject,
      invitation: invitation,
      intent: intent
    } do
      assert {:ok, %{membership: refreshed}} =
               Accounts.resend_account_invitation(invitation, subject)

      assert Auth.request_invitation_code(intent, %RequestContext{}) == {:error, :not_found}

      Fixtures.Accounts.disable_account(account)

      assert Auth.request_invitation_code(
               %{intent | token_digest: refreshed.invitation_token_digest},
               %RequestContext{}
             ) == {:error, :not_found}

      refute_received {:email, _}
      refute Repo.one(UserToken.Query.by_contexts(["magic_link", "magic_link_verified"]))
    end
  end

  describe "resend_email_code/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      %{member: owner, account: account}
    end

    test "re-issues a sign-in code for the same Member, replacing the prior one", %{
      member: member,
      account: account
    } do
      {first_id, first_nonce, first_secret} = request_magic_link(account, member.email)

      assert {:ok, %{token_id: second_id, nonce: second_nonce, delivery: {:ok, :sent}}} =
               Auth.resend_email_code(first_id, %RequestContext{})

      assert second_id != first_id
      assert_received {:email, sent}

      [_, ^second_id, second_secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      assert Auth.verify_magic_link(first_id, first_secret, first_nonce) ==
               {:error, :invalid_or_expired}

      assert Auth.verify_magic_link(second_id, second_secret, second_nonce) == {:ok, member.id}
    end

    test "re-issues an invitation code with its stored acceptance", %{
      member: owner,
      account: account
    } do
      {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
      subject = Fixtures.Subjects.subject_for(owner)
      email = "resent-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      {:ok, ^email, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Resent"})

      {:ok, %{token_id: first_id}} = Auth.request_invitation_code(intent, %RequestContext{})
      assert_received {:email, _first}

      assert {:ok, %{token_id: second_id}} = Auth.resend_email_code(first_id, %RequestContext{})
      assert_received {:email, sent}
      assert sent.to == [{"", email}]

      code = Repo.get!(UserToken, second_id)
      assert code.membership_id == invitation.id
      assert code.metadata["invitation_token_digest"] == intent.token_digest
      refute Repo.get(UserToken, first_id)
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
    end

    test "a verified code still inside its window can be re-issued; an expired or unknown one cannot",
         %{member: member, account: account} do
      verified_id = verify_magic_link(member)

      Fixtures.Auth.backdate_token_inserted_at!(
        verified_id,
        DateTime.add(DateTime.utc_now(), -20, :minute)
      )

      assert {:ok, %{token_id: _fresh}} = Auth.resend_email_code(verified_id, %RequestContext{})
      assert_received {:email, _}

      {stale_id, _nonce, _secret} = request_magic_link(account, member.email)

      Fixtures.Auth.backdate_token_inserted_at!(
        stale_id,
        DateTime.add(DateTime.utc_now(), -16, :minute)
      )

      assert Auth.resend_email_code(stale_id, %RequestContext{}) == {:error, :not_found}

      assert Auth.resend_email_code(Ecto.UUID.generate(), %RequestContext{}) ==
               {:error, :not_found}

      assert Auth.resend_email_code("not-a-uuid", %RequestContext{}) == {:error, :not_found}
      refute_received {:email, _}
    end

    test "a Member that no longer qualifies gets nothing", %{member: member, account: account} do
      {token_id, _nonce, _secret} = request_magic_link(account, member.email)
      Fixtures.Memberships.suspend_membership(member)

      assert Auth.resend_email_code(token_id, %RequestContext{}) == {:error, :not_found}
      refute_received {:email, _}
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
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      %{member: owner, account: account}
    end

    test "promotes the exact row and correct retries remain idempotent", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}

      assert %UserToken{
               id: ^token_id,
               context: "magic_link_verified",
               sent_to: sent_to,
               metadata: %{"verified_at" => verified_at}
             } = code = Repo.get!(UserToken, token_id)

      assert {code.account_id, code.membership_id} == {account.id, member.id}
      assert sent_to == member.email
      assert is_binary(verified_at)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}
      assert Repo.get!(UserToken, token_id).metadata["verified_at"] == verified_at
      assert events_of_type("user.signed_in") == []
    end

    test "the email half alone can't sign in — a wrong nonce is rejected (anti-hijack)", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)
      context = %RequestContext{ip_address: "198.51.100.9"}

      # An intercepted email gives token_id + secret but NOT the originating
      # browser's nonce → the core anti-hijack guarantee: no sign-in.
      assert Auth.verify_magic_link(token_id, secret, "wrong-nonce", context) ==
               {:error, :invalid_or_expired}

      assert [event] = events_of_type("user.sign_in_failed")
      assert {event.account_id, event.actor_id} == {account.id, member.id}
      assert event.ip_address == "198.51.100.9"
      assert event.payload == %{"reason" => "invalid_or_expired", "method" => "magic_link"}

      # …and the real browser still signs in — one wrong attempt only spent one
      # of the budget, it didn't burn the token.
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}
    end

    test "a token past the 15-minute window no longer verifies", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)
      age_tokens(member, 16)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}
    end

    test "a malformed or unknown token id is invalid, writes no audit row and is the same error" do
      before = Repo.aggregate(Audit.Event, :count)

      assert Auth.verify_magic_link("not-a-uuid", "secret", "nonce") ==
               {:error, :invalid_or_expired}

      assert Auth.verify_magic_link(Ecto.UUID.generate(), "secret", "nonce") ==
               {:error, :invalid_or_expired}

      assert Repo.aggregate(Audit.Event, :count) == before
    end

    test "a removed or suspended code owner is uniformly invalid", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)
      Fixtures.Memberships.suspend_membership(member)
      # A suspended Member still owns its code; completion decides.
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}

      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert Auth.verify_magic_link(token_id, secret, nonce) ==
               {:error, :invalid_or_expired}
    end

    test "a pending factor sent to an old address is uniformly invalid", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)
      Fixtures.Memberships.change_email(member, "moved-#{Ecto.UUID.generate()}@example.test")

      assert Auth.verify_magic_link(token_id, secret, nonce) ==
               {:error, :invalid_or_expired}

      assert %UserToken{context: "magic_link"} = Repo.get!(UserToken, token_id)
    end

    test "five wrong attempts lock the token — even the correct half then fails", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)

      # Burn all five attempts (a wrong nonce always mismatches the high-entropy one).
      for _ <- 1..5 do
        assert Auth.verify_magic_link(token_id, secret, "wrong-nonce") ==
                 {:error, :invalid_or_expired}
      end

      # Locked: the correct (nonce, secret) no longer works.
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}
    end

    test "promotion does not reset the public five-attempt budget", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, member.id}

      for _ <- 1..5 do
        assert Auth.verify_magic_link(token_id, secret, "wrong-nonce") ==
                 {:error, :invalid_or_expired}
      end

      assert %UserToken{context: "magic_link_verified", remaining_attempts: 0} =
               Repo.get!(UserToken, token_id)

      assert Auth.verify_magic_link(token_id, secret, nonce) == {:error, :invalid_or_expired}

      # The already-issued completion handoff remains valid; public retry abuse
      # cannot turn the attempt budget into a denial of the authorized browser.
      assert {:ok, %Membership{}, _raw} =
               Auth.complete_magic_link_sign_in(
                 member.id,
                 token_id,
                 browser_id(),
                 %RequestContext{}
               )
    end
  end

  describe "complete_magic_link_sign_in/4" do
    setup do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject, member: owner}
    end

    test "mints a magic_link session for the Member with no second factor, records the activity and audits once",
         %{account: account, member: member} do
      verified_token_id = verify_magic_link(member)
      browser = browser_id()
      context = %RequestContext{request_id: "req-magic"}

      assert {:ok, %Membership{account: %Account{id: account_id}} = signed_in, token} =
               Auth.complete_magic_link_sign_in(member.id, verified_token_id, browser, context)

      assert {signed_in.id, account_id} == {member.id, account.id}

      assert {:ok, %UserToken{auth_method: :magic_link, mfa_verified_at: nil} = session} =
               Auth.fetch_session_by_token(token, account.id)

      assert session.membership_id == member.id
      assert session.browser_digest == Crypto.hash(browser)
      refute Repo.get(UserToken, verified_token_id)
      assert %DateTime{} = Repo.reload!(member).last_active_at

      assert [event] = events_of_type("user.signed_in")
      assert {event.account_id, event.actor_id} == {account.id, member.id}
      assert event.payload == %{"method" => "magic_link"}
      assert event.request_id == "req-magic"

      # The consumed factor cannot mint a second session.
      assert Auth.complete_magic_link_sign_in(member.id, verified_token_id, browser, context) ==
               {:error, :invalid_or_expired}
    end

    test "an enrollment made since the link was issued still owes a second factor", %{
      subject: subject,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_sign_in(
               member.id,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) == {:error, :mfa_required}

      assert session_rows() == sessions_before
    end

    test "a verified factor cannot sign in after the Member's address changes", %{member: member} do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)
      Fixtures.Memberships.change_email(member, Fixtures.Random.unique_email())

      assert Auth.complete_magic_link_sign_in(
               member.id,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      assert session_rows() == sessions_before
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"
    end

    test "a verified factor expires ten minutes after promotion", %{member: member} do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)
      verified_at = DateTime.utc_now() |> DateTime.add(-601, :second) |> DateTime.to_iso8601()

      UserToken.Query.by_id(verified_token_id)
      |> Repo.update_all(set: [metadata: %{"verified_at" => verified_at}])

      assert Auth.complete_magic_link_sign_in(
               member.id,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      assert session_rows() == sessions_before
    end

    test "missing or malformed promotion time fails closed", %{member: member} do
      sessions_before = session_rows()

      for metadata <- [%{}, %{"verified_at" => "not-a-time"}] do
        verified_token_id = verify_magic_link(member)

        UserToken.Query.by_id(verified_token_id)
        |> Repo.update_all(set: [metadata: metadata])

        assert Auth.complete_magic_link_sign_in(
                 member.id,
                 verified_token_id,
                 browser_id(),
                 %RequestContext{}
               ) == {:error, :invalid_or_expired}
      end

      assert session_rows() == sessions_before
    end

    test "a disabled workspace mints nothing and hands back the account", %{
      account: account,
      subject: subject,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)

      {:ok, _account} =
        Accounts.set_account_disabled_for_support(account.id, true, "support incident", subject)

      assert {:error, {:account_disabled, disabled}} =
               Auth.complete_magic_link_sign_in(
                 member.id,
                 verified_token_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert disabled.id == account.id
      assert session_rows() == sessions_before
    end

    test "a workspace that started requiring SSO after the code was sent refuses it", %{
      account: account,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)
      Fixtures.Accounts.create_subscription(account, "team")
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      assert Auth.complete_magic_link_sign_in(
               member.id,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) == {:error, :sso_required}

      assert session_rows() == sessions_before
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"
    end

    test "a failed sign-in audit rolls the activity, the factor and the session back", %{
      member: member
    } do
      sessions_before = session_rows()
      # A non-string request_id fails the audit changeset, so the one minting
      # transaction aborts — no activity, no session, no consumed code, no audit row.
      context = %RequestContext{request_id: %{invalid: true}}
      verified_token_id = verify_magic_link(member)

      assert {:error, changeset} =
               Auth.complete_magic_link_sign_in(
                 member.id,
                 verified_token_id,
                 browser_id(),
                 context
               )

      assert "is invalid" in errors_on(changeset).request_id

      assert Repo.reload!(member).last_active_at == member.last_active_at
      assert Repo.get!(UserToken, verified_token_id).context == "magic_link_verified"
      assert session_rows() == sessions_before
      assert events_of_type("user.signed_in") == []
    end

    test "a code verified for one Member cannot complete for another, and nothing unknown completes",
         %{account: account, member: member} do
      sessions_before = session_rows()
      other = Fixtures.Memberships.create_membership(account_id: account.id)
      verified_token_id = verify_magic_link(member)

      assert Auth.complete_magic_link_sign_in(
               other.id,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invalid_or_expired}

      assert Auth.complete_magic_link_sign_in(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               browser_id(),
               %RequestContext{}
             ) == {:error, :invalid_or_expired}

      assert session_rows() == sessions_before
    end
  end

  describe "complete_magic_link_sign_in/4 — invitation" do
    # A pending invitation and the intent its name form carries.
    defp invitation_fixture(account_attrs \\ %{}) do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(account_attrs)
      email = "invited-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      {:ok, ^email, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Invited Name"})

      %{account: account, subject: subject, invitation: invitation, intent: intent, email: email}
    end

    defp verify_invitation_code(intent) do
      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Auth.request_invitation_code(intent, %RequestContext{})

      assert_received {:email, sent}
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, intent.membership_id}
      token_id
    end

    defp accepted_events(account) do
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Audit.Event.Query.by_event_type("user.invitation_accepted")
      |> Repo.all()
    end

    test "a suspended invitation gets no code, and a code proved before the suspension accepts nothing" do
      %{account: account, invitation: invitation, subject: subject} =
        fixture = invitation_fixture()

      factor_id = verify_invitation_code(fixture.intent)
      {:ok, _suspended} = Accounts.suspend_membership(invitation, subject)

      assert Auth.request_invitation_code(fixture.intent, %RequestContext{}) ==
               {:error, :not_found}

      refute_received {:email, _sent}

      assert {:error, _refused} =
               Auth.complete_magic_link_sign_in(
                 invitation.id,
                 factor_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
      assert accepted_events(account) == []
      assert events_of_type("user.signed_in") == []
    end

    test "requesting and verifying accept nothing; completion accepts once, verifies the address and grants the seat" do
      %{account: account, invitation: invitation} = fixture = invitation_fixture()
      factor_id = verify_invitation_code(fixture.intent)
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
      refute Repo.reload!(invitation).email_verified_at

      assert {:ok, %Membership{account: %Account{id: account_id}} = accepted, raw} =
               Auth.complete_magic_link_sign_in(
                 invitation.id,
                 factor_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert {accepted.id, account_id} == {invitation.id, account.id}
      assert accepted.display_name == "Invited Name"
      assert %DateTime{} = accepted.email_verified_at
      assert %DateTime{} = accepted.invitation_accepted_at
      assert is_nil(accepted.invitation_token_digest)

      assert {:ok, session} = Auth.fetch_session_by_token(raw, account.id)
      assert session.membership_id == invitation.id
      assert length(accepted_events(account)) == 1
      assert [_signed_in] = events_of_type("user.signed_in")

      assert Auth.complete_magic_link_sign_in(
               invitation.id,
               factor_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invalid_or_expired}

      assert length(accepted_events(account)) == 1
    end

    test "an invitation rotated before completion fails closed, with no session" do
      %{account: account, subject: subject, invitation: invitation} =
        fixture = invitation_fixture()

      factor_id = verify_invitation_code(fixture.intent)
      assert {:ok, _resent} = Accounts.resend_account_invitation(invitation, subject)
      sessions_before = session_rows()

      assert Auth.complete_magic_link_sign_in(
               invitation.id,
               factor_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invitation_invalid}

      assert session_rows() == sessions_before
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
      refute Repo.reload!(invitation).email_verified_at
      assert accepted_events(account) == []
    end

    test "a same-browser resend keeps the invitation" do
      %{invitation: invitation, intent: intent} = invitation_fixture()
      {:ok, %{token_id: first_id}} = Auth.request_invitation_code(intent, %RequestContext{})
      assert_received {:email, _first}

      assert {:ok, %{token_id: second_id, nonce: nonce}} =
               Auth.resend_email_code(first_id, %RequestContext{})

      assert_received {:email, sent}

      [_, ^second_id, secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      assert Auth.verify_magic_link(second_id, secret, nonce) == {:ok, invitation.id}

      assert {:ok, %Membership{}, _raw} =
               Auth.complete_magic_link_sign_in(
                 invitation.id,
                 second_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert Repo.reload!(invitation).invitation_accepted_at
    end

    test "where the workspace refuses email sign-in nothing is accepted, consumed or minted; the proof continues the acceptance at the IdP" do
      %{account: account, invitation: invitation} = fixture = invitation_fixture(%{plan: "team"})
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      factor_id = verify_invitation_code(fixture.intent)
      sessions_before = session_rows()
      browser = browser_id()

      assert {:ok, :sso_required,
              %{account: %Account{id: account_id}, membership: pending, proof: proof}} =
               Auth.complete_magic_link_sign_in(
                 invitation.id,
                 factor_id,
                 browser,
                 %RequestContext{}
               )

      assert {account_id, pending.id} == {account.id, invitation.id}
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
      refute Repo.reload!(invitation).email_verified_at
      assert Repo.get!(UserToken, factor_id).context == "magic_link_verified"
      assert session_rows() == sessions_before
      assert accepted_events(account) == []
      assert events_of_type("user.signed_in") == []

      assert {:ok, continuation} = Auth.verify_invitation_sso_proof(proof, browser)

      # The proof is ids only; the name and address stay on the proved code.
      assert continuation == %{
               account_id: account.id,
               membership_id: invitation.id,
               token_digest: fixture.intent.token_digest,
               code_id: factor_id
             }
    end
  end

  describe "complete_magic_link_mfa_sign_in/4" do
    setup do
      %{account: account, member: member, secret: secret, codes: codes, subject: subject} =
        mfa_owner()

      %{account: account, codes: codes, secret: secret, subject: subject, member: member}
    end

    test "a verified TOTP proof mints a magic_link session stamping the proof time", %{
      account: account,
      secret: secret,
      member: member
    } do
      verified_token_id = verify_magic_link(member)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, %Membership{} = signed_in, token} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert signed_in.id == member.id

      assert {:ok, %UserToken{auth_method: :magic_link, mfa_verified_at: %DateTime{}} = session} =
               Auth.fetch_session_by_token(token, account.id)

      assert session.membership_id == member.id
      assert session.mfa_enrollment_verified_at == Repo.reload!(member).mfa_enabled_at
    end

    test "a verified recovery-code proof mints the same session", %{
      account: account,
      codes: [code | _],
      member: member
    } do
      verified_token_id = verify_magic_link(member)
      assert {:ok, proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, code})

      assert {:ok, _member, token} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert {:ok, %UserToken{auth_method: :magic_link, mfa_verified_at: %DateTime{}}} =
               Auth.fetch_session_by_token(token, account.id)
    end

    test "a completed proof cannot be replayed into a second session", %{
      account: account,
      secret: secret,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, _member, token} =
               Auth.complete_magic_link_mfa_sign_in(
                 proof,
                 verified_token_id,
                 browser_id(),
                 %RequestContext{}
               )

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invalid_or_expired}

      assert {:ok, minted} = Auth.fetch_session_by_token(token, account.id)
      assert session_rows() == Enum.sort_by([Repo.reload!(minted) | sessions_before], & &1.id)
    end

    test "a proof for one Member is refused for another Member's verified code", %{
      account: account,
      secret: secret,
      member: member
    } do
      sessions_before = session_rows()
      other = Fixtures.Memberships.create_membership(account_id: account.id)
      other_factor_id = verify_magic_link(other)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               other_factor_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invalid_or_expired}

      assert session_rows() == sessions_before
    end

    test "a verified inbox factor cannot finish MFA after the address changes", %{
      secret: secret,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      Fixtures.Memberships.change_email(member, Fixtures.Random.unique_email())

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :invalid_or_expired}

      assert session_rows() == sessions_before
    end

    test "a proof no longer matches once MFA was disabled after the challenge", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, _member} = Auth.disable_mfa(code, subject)

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :mfa_proof_stale}

      assert session_rows() == sessions_before
    end

    test "a proof no longer matches once the secret was rotated (disable, re-enable)", %{
      codes: [code | _],
      secret: secret,
      subject: subject,
      member: member
    } do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, _member} = Auth.disable_mfa(code, subject)
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_magic_link_mfa_sign_in(
               proof,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :mfa_proof_stale}

      assert session_rows() == sessions_before
    end

    test "current Member fields are not an MFA proof", %{member: member} do
      sessions_before = session_rows()
      verified_token_id = verify_magic_link(member)
      current = Repo.reload!(member)

      forged = %{
        membership_id: current.id,
        mfa_enabled_at: current.mfa_enabled_at,
        updated_at: current.updated_at
      }

      assert Auth.complete_magic_link_mfa_sign_in(
               forged,
               verified_token_id,
               browser_id(),
               %RequestContext{}
             ) ==
               {:error, :mfa_proof_stale}

      assert session_rows() == sessions_before
    end
  end

  describe "verify_invitation_sso_proof/2" do
    test "accepts only the signed continuation, from the same browser, inside its window" do
      assert Auth.verify_invitation_sso_proof("garbage", browser_id()) ==
               {:error, :invitation_sso_invalid}

      assert Auth.verify_invitation_sso_proof(nil, browser_id()) ==
               {:error, :invitation_sso_invalid}

      signing_secret = Application.fetch_env!(:emisar, :email_link_secret)
      browser = browser_id()

      payload =
        {:invitation_sso,
         %{
           account_id: Ecto.UUID.generate(),
           membership_id: Ecto.UUID.generate(),
           token_digest: "digest",
           code_id: Ecto.UUID.generate(),
           browser_digest: Crypto.hash(browser)
         }}

      fresh = Phoenix.Token.sign(signing_secret, "invitation sso proof", payload)

      assert {:ok, %{token_digest: "digest"} = continuation} =
               Auth.verify_invitation_sso_proof(fresh, browser)

      refute Map.has_key?(continuation, :browser_digest)

      assert Auth.verify_invitation_sso_proof(fresh, browser_id()) ==
               {:error, :invitation_sso_invalid}

      expired =
        Phoenix.Token.sign(signing_secret, "invitation sso proof", payload,
          signed_at: System.system_time(:second) - 601
        )

      assert Auth.verify_invitation_sso_proof(expired, browser) ==
               {:error, :invitation_sso_invalid}
    end
  end

  describe "peek_invitation_sso_acceptance/1" do
    test "reads the name and address from the proved code of that invitation only" do
      %{account: account, invitation: invitation, email: email} = fixture = invitation_fixture()
      code_id = verify_invitation_code(fixture.intent)

      proved = %{
        account_id: account.id,
        membership_id: invitation.id,
        token_digest: fixture.intent.token_digest,
        code_id: code_id
      }

      assert Auth.peek_invitation_sso_acceptance(proved) ==
               {:ok, Map.merge(proved, %{display_name: "Invited Name", sent_to: email})}

      for wrong <- [
            %{proved | code_id: Ecto.UUID.generate()},
            %{proved | membership_id: Ecto.UUID.generate()},
            %{proved | token_digest: "another-invitation"}
          ] do
        assert Auth.peek_invitation_sso_acceptance(wrong) == {:error, :invalid_or_expired}
      end
    end

    test "refuses a code past its verified window" do
      %{account: account, invitation: invitation} = fixture = invitation_fixture()
      code_id = verify_invitation_code(fixture.intent)
      code = Repo.get!(UserToken, code_id)
      stale = DateTime.utc_now() |> DateTime.add(-11 * 60) |> DateTime.to_iso8601()

      code
      |> Ecto.Changeset.change(metadata: Map.put(code.metadata, "verified_at", stale))
      |> Repo.update!()

      assert Auth.peek_invitation_sso_acceptance(%{
               account_id: account.id,
               membership_id: invitation.id,
               token_digest: fixture.intent.token_digest,
               code_id: code_id
             }) == {:error, :invalid_or_expired}
    end
  end

  describe "put_invitation_sso_session/5" do
    test "consumes the exact proved code and mints the accepted Member's SSO session for the bound identity" do
      %{account: account, email: email} = fixture = invitation_fixture(%{plan: "team"})
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      factor_id = verify_invitation_code(fixture.intent)
      {raw, digest} = Crypto.session_token()
      browser = browser_id()
      context = %RequestContext{request_id: "req-invitation-sso"}

      assert {:ok, %{accepted: accepted, token: session}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:account, fn repo, _changes ->
                 Accounts.fetch_and_lock_account(account.id, repo: repo)
               end)
               |> Ecto.Multi.put(:locked_provider, provider)
               |> Accounts.put_invitation_acceptance(fixture.intent, email)
               |> Ecto.Multi.run(:identity, fn repo, %{accepted: member} ->
                 account.id
                 |> Emisar.SSO.UserIdentity.Changeset.create(provider.id, member, %{
                   provider_identifier: "okta|invitee",
                   created_by: :user,
                   provisioned_via: :oidc_link
                 })
                 |> repo.insert()
               end)
               |> Auth.put_invitation_sso_session(
                 %{code_id: factor_id, token_digest: fixture.intent.token_digest},
                 digest,
                 browser,
                 context
               )
               |> Repo.commit_multi()

      assert session.membership_id == accepted.id
      assert session.auth_method == :sso
      assert session.sso_issuer == provider.issuer
      assert session.sso_provider_identifier == "okta|invitee"
      assert session.browser_digest == Crypto.hash(browser)
      assert {:ok, %UserToken{id: session_id}} = Auth.fetch_session_by_token(raw, account.id)
      assert session_id == session.id
      refute Repo.get(UserToken, factor_id)
      assert %DateTime{} = Repo.reload!(accepted).last_active_at

      assert [%{payload: %{"method" => "sso"}, request_id: "req-invitation-sso"}] =
               events_of_type("user.signed_in")
    end

    test "a code that is not the accepted Member's own invitation code fails the whole transaction" do
      %{account: account, email: email} = fixture = invitation_fixture(%{plan: "team"})
      other = invitation_fixture(%{plan: "team"})
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      _own_factor = verify_invitation_code(fixture.intent)
      other_factor = verify_invitation_code(other.intent)
      {_raw, digest} = Crypto.session_token()

      assert Ecto.Multi.new()
             |> Ecto.Multi.run(:account, fn repo, _changes ->
               Accounts.fetch_and_lock_account(account.id, repo: repo)
             end)
             |> Ecto.Multi.put(:locked_provider, provider)
             |> Accounts.put_invitation_acceptance(fixture.intent, email)
             |> Ecto.Multi.run(:identity, fn repo, %{accepted: member} ->
               account.id
               |> Emisar.SSO.UserIdentity.Changeset.create(provider.id, member, %{
                 provider_identifier: "okta|invitee",
                 created_by: :user,
                 provisioned_via: :oidc_link
               })
               |> repo.insert()
             end)
             |> Auth.put_invitation_sso_session(
               %{code_id: other_factor, token_digest: fixture.intent.token_digest},
               digest,
               browser_id(),
               %RequestContext{}
             )
             |> Repo.commit_multi() == {:error, :invalid_or_expired}

      assert is_nil(Repo.reload!(fixture.invitation).invitation_accepted_at)
      assert Repo.get!(UserToken, other_factor).context == "magic_link_verified"

      refute Repo.exists?(
               UserToken.Query.by_membership(account.id, fixture.invitation.id)
               |> UserToken.Query.by_context("session")
             )
    end
  end

  describe "begin_email_change/2" do
    setup :email_member

    test "sends a code to the current address, bound to the address asked for", %{
      member: member,
      subject: subject
    } do
      assert Auth.begin_email_change(" new@example.test ", subject) == {:ok, :email}

      assert_received {:email, mail}
      assert mail.to == [{"", member.email}]
      assert mail.text_body =~ "new@example.test"
      assert [event] = events_of_type("user.email_change_requested")
      assert event.payload == %{}
      assert Repo.reload!(member).email == member.email
    end

    test "a member with an authenticator proves it there instead", %{subject: subject} do
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.begin_email_change("new@example.test", subject) == {:ok, :mfa}
      refute Repo.one(UserToken.Query.by_context("email_change"))
    end

    test "refuses an address that is malformed, unchanged or held in this workspace", %{
      account: account,
      member: member,
      subject: subject
    } do
      colleague = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:error, changeset} = Auth.begin_email_change("not an address", subject)
      assert "must have the @ sign and no spaces" in errors_on(changeset).email

      assert {:error, changeset} = Auth.begin_email_change(member.email, subject)
      assert "is already your email" in errors_on(changeset).email

      assert {:error, changeset} =
               Auth.begin_email_change(String.upcase(colleague.email), subject)

      assert "is already used by a member of this workspace" in errors_on(changeset).email

      refute_received {:email, _mail}
    end

    test "an address another workspace uses is free here", %{subject: subject} do
      elsewhere = Fixtures.Memberships.create_membership()

      assert Auth.begin_email_change(elsewhere.email, subject) == {:ok, :email}
    end

    test "a member whose address no code proved can't change it" do
      account = Fixtures.Accounts.create_account()

      member =
        Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false)

      subject = Fixtures.Subjects.subject_for(member)

      assert Auth.begin_email_change("new@example.test", subject) ==
               {:error, :email_change_unavailable}
    end

    test "a member a directory provisioned can't change it" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "enterprise")
      owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      owner_subject = Fixtures.Subjects.subject_for(owner)
      {:ok, provider, _token} = Emisar.SSO.enable_scim(provider, owner_subject)

      {:ok, %{identity: identity, membership: member}} =
        Emisar.SSO.scim_provision_user(provider, %{
          external_id: "directory-person",
          email: "directory@example.test",
          full_name: "Directory Name"
        })

      subject = Fixtures.Subjects.subject_for(member, user_identity_id: identity.id)

      assert Auth.begin_email_change("new@example.test", subject) ==
               {:error, :email_change_unavailable}
    end

    test "a bounced current address stops the change before it starts", %{
      member: member,
      subject: subject
    } do
      assert {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")

      assert Auth.begin_email_change("new@example.test", subject) ==
               {:error, :delivery_suppressed}
    end

    test "sending codes is capped per member", %{subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _attempt <- 1..5,
          do: assert(Auth.begin_email_change("new@example.test", subject) == {:ok, :email})

      assert Auth.begin_email_change("new@example.test", subject) == {:error, :rate_limited}
      assert [event] = events_of_type("user.email_change_rate_limited")
      assert event.payload["scope"] == "email_change_issue"
    end
  end

  describe "resend_email_change_code/2" do
    setup :email_member

    test "replaces the code already sent", %{subject: subject} do
      first = begin_email_change_code(subject, "new@example.test")

      assert Auth.resend_email_change_code("new@example.test", subject) == {:ok, :sent}
      assert_received {:email, mail}
      second = Fixtures.Auth.code_from_email(mail)

      assert Auth.confirm_email_change("new@example.test", first, subject) == {:error, :invalid}
      assert {:ok, _proof} = Auth.confirm_email_change("new@example.test", second, subject)
    end

    test "a member who enrolled an authenticator must use it", %{subject: subject} do
      begin_email_change_code(subject, "new@example.test")
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.resend_email_change_code("new@example.test", subject) ==
               {:error, :factor_changed}
    end
  end

  describe "confirm_email_change/3" do
    setup :email_member

    test "the current-inbox code sends a split code to the new address", %{
      member: member,
      subject: subject
    } do
      code = begin_email_change_code(subject, "new@example.test")

      assert {:ok, %{token_id: _id, nonce: nonce, email: "new@example.test"}} =
               Auth.confirm_email_change("new@example.test", code, subject)

      assert_received {:email, mail}
      assert mail.to == [{"", "new@example.test"}]
      refute mail.text_body =~ nonce
      refute Repo.one(UserToken.Query.by_context("email_change"))
      assert Repo.reload!(member).email == member.email
    end

    test "an authenticator code confirms a member with MFA", %{subject: subject} do
      secret = Auth.generate_mfa_secret()
      Fixtures.Memberships.enable_mfa!(secret, subject)
      assert {:ok, :mfa} = Auth.begin_email_change("new@example.test", subject)

      assert {:ok, %{email: "new@example.test"}} =
               Auth.confirm_email_change(
                 "new@example.test",
                 Fixtures.Auth.totp_code(secret),
                 subject
               )
    end

    test "a wrong code is refused, spends an attempt and is recorded", %{subject: subject} do
      code = begin_email_change_code(subject, "new@example.test")
      wrong = if code == "000000", do: "111111", else: "000000"

      assert Auth.confirm_email_change("new@example.test", wrong, subject) == {:error, :invalid}
      assert Repo.one(UserToken.Query.by_context("email_change")).remaining_attempts == 4
      assert [_event] = events_of_type("user.email_change_code_failed")
    end

    test "a code only confirms the address it was sent for", %{subject: subject} do
      code = begin_email_change_code(subject, "first@example.test")

      assert Auth.confirm_email_change("second@example.test", code, subject) ==
               {:error, :invalid}
    end

    test "a member that changes after its step-up must start again", %{
      member: member,
      subject: subject
    } do
      code = begin_email_change_code(subject, "new@example.test")
      handler = "email-change-race-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:emisar, :repo, :query],
          &__MODULE__.enroll_mfa_once_code_spent/4,
          {self(), handler, member}
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Auth.confirm_email_change("new@example.test", code, subject) ==
               {:error, :email_change_stale}

      refute Repo.one(UserToken.Query.by_context("email_change_new"))
      refute_received {:email, _mail}
    end

    test "another member's code can't confirm", %{account: account, subject: subject} do
      colleague = Fixtures.Memberships.create_membership(account_id: account.id)
      colleague_subject = Fixtures.Subjects.subject_for(colleague)
      code = begin_email_change_code(subject, "new@example.test")

      assert Auth.confirm_email_change("new@example.test", code, colleague_subject) ==
               {:error, :invalid}
    end
  end

  describe "complete_email_change/4" do
    setup :email_member

    test "proves the new inbox and changes the address once", %{
      account: account,
      member: member,
      subject: subject
    } do
      {proof, code} = pending_email_change(subject, "new@example.test")
      Accounts.subscribe_account_team(account.id)

      assert {:ok, changed} =
               Auth.complete_email_change(proof.token_id, proof.nonce, code, subject)

      assert changed.email == "new@example.test"
      assert changed.email_verified_at
      assert [event] = events_of_type("user.email_changed")
      assert event.payload == %{"from" => member.email, "to" => "new@example.test"}

      assert_received {:email, notice}
      assert notice.to == [{"", member.email}]
      assert notice.subject == "Your sign-in email changed"

      member_id = member.id
      assert_receive {:list_changed, :team, "user.email_changed", ^member_id}

      assert Auth.complete_email_change(proof.token_id, proof.nonce, code, subject) ==
               {:error, :invalid}
    end

    test "the emailed half is useless without this browser's nonce", %{subject: subject} do
      {proof, code} = pending_email_change(subject, "new@example.test")

      assert Auth.complete_email_change(proof.token_id, "another-browser", code, subject) ==
               {:error, :invalid}

      assert Repo.get!(UserToken, proof.token_id).remaining_attempts == 4
      assert [_event] = events_of_type("user.email_change_code_failed")

      assert {:ok, _changed} =
               Auth.complete_email_change(
                 proof.token_id,
                 proof.nonce,
                 String.downcase(code),
                 subject
               )
    end

    test "codes sent to the old address stop working", %{
      account: account,
      member: member,
      subject: subject
    } do
      assert {:ok, _sent} = Auth.request_magic_link(account, member.email, %RequestContext{})
      assert_received {:email, _sign_in_mail}
      {proof, code} = pending_email_change(subject, "new@example.test")

      assert {:ok, _changed} =
               Auth.complete_email_change(proof.token_id, proof.nonce, code, subject)

      refute UserToken.Query.by_membership(account.id, member.id)
             |> UserToken.Query.by_context("magic_link")
             |> Repo.one()
    end

    test "another member can't finish it", %{account: account, subject: subject} do
      colleague = Fixtures.Memberships.create_membership(account_id: account.id)
      colleague_subject = Fixtures.Subjects.subject_for(colleague)
      {proof, code} = pending_email_change(subject, "new@example.test")

      assert Auth.complete_email_change(proof.token_id, proof.nonce, code, colleague_subject) ==
               {:error, :invalid}
    end

    test "a change to the member since the code was sent voids it", %{
      member: member,
      subject: subject
    } do
      {proof, code} = pending_email_change(subject, "new@example.test")
      Fixtures.Memberships.sync_display_name(member, "Renamed")

      assert Auth.complete_email_change(proof.token_id, proof.nonce, code, subject) ==
               {:error, :invalid}

      assert Repo.reload!(member).email == member.email
    end

    test "an address another member took meanwhile changes nothing", %{
      account: account,
      member: member,
      subject: subject
    } do
      {proof, code} = pending_email_change(subject, "taken@example.test")
      Fixtures.Memberships.create_membership(account_id: account.id, email: "taken@example.test")

      assert {:error, %Ecto.Changeset{}} =
               Auth.complete_email_change(proof.token_id, proof.nonce, code, subject)

      assert Repo.reload!(member).email == member.email
    end
  end

  describe "mfa_facts/1" do
    test "an unenrolled Member with a verified address proves itself by email" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      assert Auth.mfa_facts(subject) ==
               {:ok,
                %Auth.MfaFacts{
                  enabled?: false,
                  recovery_codes_remaining: 0,
                  enrollment_proof: :email
                }}
    end

    test "an enrolled Member is on with its remaining recovery codes" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {enrolled, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      # The live row is the answer, not the pre-enrollment actor on `subject`.
      assert Auth.mfa_facts(subject) ==
               {:ok,
                %Auth.MfaFacts{
                  enabled?: true,
                  recovery_codes_remaining: 10,
                  enrollment_proof: :email
                }}

      assert Auth.mfa_facts(Fixtures.Subjects.subject_for(enrolled)) ==
               {:ok,
                %Auth.MfaFacts{
                  enabled?: true,
                  recovery_codes_remaining: 10,
                  enrollment_proof: :email
                }}
    end

    test "an SSO-only Member proves itself at its IdP, and nowhere once the workspace loses SSO" do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{member: member, identity: identity} = sso_route(account)

      sso =
        Fixtures.Subjects.subject_for(member, auth_method: :sso, user_identity_id: identity.id)

      assert {:ok, %Auth.MfaFacts{enrollment_proof: :sso}} = Auth.mfa_facts(sso)

      email_code = Fixtures.Subjects.subject_for(member)
      assert {:ok, %Auth.MfaFacts{enrollment_proof: :unavailable}} = Auth.mfa_facts(email_code)

      Fixtures.Accounts.create_subscription(account, "team", status: "canceled")
      assert {:ok, %Auth.MfaFacts{enrollment_proof: :unavailable}} = Auth.mfa_facts(sso)
    end

    test "facts belong to one Member: a namesake elsewhere stays unenrolled" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      {enrolled, _codes} = Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)
      elsewhere = Fixtures.Memberships.create_membership(email: enrolled.email)

      assert {:ok, %Auth.MfaFacts{enabled?: false}} =
               Auth.mfa_facts(Fixtures.Subjects.subject_for(elsewhere))
    end

    test "refuses a non-Member subject" do
      account = Fixtures.Accounts.create_account()
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)

      assert Auth.mfa_facts(Auth.Subject.for_api_key(api_key, account)) ==
               {:error, :unauthorized}
    end
  end

  describe "issue_mfa_enrollment_code/1" do
    setup do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      %{member: owner, subject: subject}
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
      member: member,
      subject: subject
    } do
      assert {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")

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
      member: member,
      subject: subject
    } do
      delivered_code = issue_mfa_enrollment_code(subject)
      assert {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")

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

    test "a Member without a verified address or already enrolled gets no code" do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{member: member, identity: identity} = sso_route(account)

      sso =
        Fixtures.Subjects.subject_for(member, auth_method: :sso, user_identity_id: identity.id)

      assert Auth.issue_mfa_enrollment_code(sso) == {:error, :email_unavailable}
      assert Auth.verify_mfa_enrollment_code("ABCDEF", sso) == {:error, :email_unavailable}

      %{subject: enrolled_subject} = mfa_owner()
      assert Auth.issue_mfa_enrollment_code(enrolled_subject) == {:error, :mfa_already_enabled}
      refute_received {:email, _}
    end
  end

  describe "verify_mfa_enrollment_code/2" do
    setup do
      {owner, _account, _subject} = Fixtures.Subjects.owner_subject()
      session_token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      %{
        member: owner,
        subject: Fixtures.Subjects.subject_for(owner, session: session_token),
        secret: Auth.generate_mfa_secret(),
        session_token: session_token
      }
    end

    test "the emailed code is single-use and enables only its Member", %{
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      code = issue_mfa_enrollment_code(subject)

      assert Auth.verify_mfa_enrollment_code("000000", subject) == {:error, :invalid}

      # The miss is audited so grinding a hijacked session toward MFA is visible.
      assert [%Audit.Event{event_type: "user.mfa_enrollment_failed"}] =
               events_of_type("user.mfa_enrollment_failed")

      assert {:ok, proof} = Auth.verify_mfa_enrollment_code(code, subject)
      assert Auth.verify_mfa_enrollment_code(code, subject) == {:error, :invalid}

      assert {:ok, %Membership{id: id, mfa_enabled_at: %DateTime{}}, codes} =
               Auth.enable_mfa(
                 secret,
                 Fixtures.Auth.totp_code(secret),
                 proof,
                 Crypto.hash(session_token),
                 subject
               )

      assert id == member.id
      assert length(codes) == 10
    end

    test "a forged proof cannot enroll", %{
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               "forged",
               Crypto.hash(session_token),
               subject
             ) == {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(member).mfa_enabled_at
    end

    test "a code sent before the address changed proves nothing", %{
      member: member,
      subject: subject
    } do
      code = issue_mfa_enrollment_code(subject)
      Fixtures.Memberships.change_email(member, Fixtures.Random.unique_email())

      assert Auth.verify_mfa_enrollment_code(code, subject) == {:error, :invalid}

      refute Repo.one(
               UserToken.Query.by_membership(member.account_id, member.id)
               |> UserToken.Query.by_context("mfa_enrollment")
             )
    end

    test "a proof becomes stale after any intervening Member-row change", %{
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      Fixtures.Memberships.sync_display_name(member, "Changed")

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               proof,
               Crypto.hash(session_token),
               subject
             ) == {:error, :mfa_enrollment_proof_stale}
    end

    test "a proof minted for one Member is refused for another", %{
      subject: subject,
      secret: secret
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      {other, _account, _subject} = Fixtures.Subjects.owner_subject()
      other_token = Fixtures.Auth.create_session_token!(other, :magic_link, nil)
      other_subject = Fixtures.Subjects.subject_for(other, session: other_token)

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               proof,
               Crypto.hash(other_token),
               other_subject
             ) == {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(other).mfa_enabled_at
    end

    test "an expired proof is refused", %{
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      signing_secret = Application.fetch_env!(:emisar, :email_link_secret)

      assert {:ok, payload} =
               Phoenix.Token.verify(signing_secret, "mfa enrollment proof", proof, max_age: 300)

      expired =
        Phoenix.Token.sign(signing_secret, "mfa enrollment proof", payload,
          signed_at: System.system_time(:second) - 301
        )

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               expired,
               Crypto.hash(session_token),
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

    test "verification shares the Member's inbox budget with connection verification", %{
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      enrollment_code = issue_mfa_enrollment_code(subject)
      provider = Fixtures.SSO.create_identity_provider(account_id: subject.account.id)

      for _ <- 1..3 do
        assert Auth.verify_mfa_enrollment_code("000000", subject) == {:error, :invalid}
      end

      for _ <- 1..2 do
        assert Auth.confirm_oidc_identity_step_up(provider.id, "000000", subject) ==
                 {:error, :invalid}
      end

      assert Auth.verify_mfa_enrollment_code(enrollment_code, subject) == {:error, :rate_limited}
      assert [_event] = events_of_type("user.inbox_step_up_rate_limited")
    end
  end

  describe "issue_mfa_enrollment_proof_for_sso/3" do
    setup do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{provider: provider, member: member, identity: identity} = sso_route(account)

      raw =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      subject = Fixtures.Subjects.subject_for(member, session: raw)

      %{
        account: account,
        provider: provider,
        member: member,
        identity: identity,
        raw: raw,
        digest: Crypto.hash(raw),
        subject: subject,
        reauthentication: reauthentication(provider, identity, Crypto.hash(raw))
      }
    end

    defp reauthentication(provider, identity, session_digest, overrides \\ %{}) do
      Map.merge(
        %{
          provider_id: provider.id,
          identity_id: identity.id,
          provider_identifier: identity.provider_identifier,
          namespace: {provider.issuer, provider.client_id, provider.identifier_claim},
          auth_time: System.system_time(:second),
          session_digest: session_digest
        },
        overrides
      )
    end

    test "binds the fresh IdP sign-in to this exact SSO session and the Member's row version", %{
      member: member,
      digest: digest,
      subject: subject,
      reauthentication: reauthentication
    } do
      assert {:ok, proof} =
               Auth.issue_mfa_enrollment_proof_for_sso(reauthentication, digest, subject)

      secret = Auth.generate_mfa_secret()

      assert {:ok, %Membership{id: id, mfa_enabled_at: %DateTime{}}, codes} =
               Auth.enable_mfa(secret, Fixtures.Auth.totp_code(secret), proof, digest, subject)

      assert id == member.id
      assert length(codes) == 10
      assert [event] = events_of_type("user.mfa_enabled")
      assert event.actor_id == member.id
    end

    test "refuses another digest, a non-SSO or other-identity session, an enrolled Member and an ended session",
         %{
           account: account,
           member: member,
           digest: digest,
           subject: subject,
           reauthentication: reauth
         } do
      other_raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert Auth.issue_mfa_enrollment_proof_for_sso(reauth, Crypto.hash(other_raw), subject) ==
               {:error, :mfa_enrollment_proof_stale}

      assert Auth.issue_mfa_enrollment_proof_for_sso(
               %{reauth | session_digest: Crypto.hash(other_raw)},
               digest,
               subject
             ) == {:error, :mfa_enrollment_proof_stale}

      email_subject = Fixtures.Subjects.subject_for(member, session: other_raw)

      assert Auth.issue_mfa_enrollment_proof_for_sso(
               %{reauth | session_digest: Crypto.hash(other_raw)},
               Crypto.hash(other_raw),
               email_subject
             ) == {:error, :mfa_enrollment_proof_stale}

      %{identity: other_identity} = sso_route(account, kind: :openid_connect)

      assert Auth.issue_mfa_enrollment_proof_for_sso(
               %{reauth | identity_id: other_identity.id},
               digest,
               subject
             ) == {:error, :mfa_enrollment_proof_stale}

      assert Auth.issue_mfa_enrollment_proof_for_sso(%{}, digest, subject) ==
               {:error, :mfa_enrollment_proof_stale}

      Fixtures.Memberships.set_mfa_state(member,
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now()
      )

      assert Auth.issue_mfa_enrollment_proof_for_sso(reauth, digest, subject) ==
               {:error, :mfa_already_enabled}

      Fixtures.Memberships.suspend_membership(member)

      assert Auth.issue_mfa_enrollment_proof_for_sso(reauth, digest, subject) ==
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

  describe "enable_mfa/5" do
    setup do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      session_token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(owner, session: session_token)

      %{
        account: account,
        member: owner,
        subject: subject,
        secret: Auth.generate_mfa_secret(),
        session_token: session_token
      }
    end

    test "spends the code that proved the enrollment: it cannot answer a challenge next", %{
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      otp = Fixtures.Auth.totp_code(secret)

      assert {:ok, enrolled, _codes} =
               Auth.enable_mfa(secret, otp, proof, Crypto.hash(session_token), subject)

      assert Auth.verify_mfa_challenge(enrolled.id, {:totp, otp}) == {:error, :replay}
    end

    test "with the correct OTP persists the secret + returns recovery codes, stamping only this session",
         %{
           account: account,
           member: member,
           secret: secret,
           subject: subject,
           session_token: session_token
         } do
      sibling_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      # The fixture retries once across a 30-second TOTP step boundary, so this
      # success-contract assertion can't flake on a microsecond boundary.
      assert {:ok, %Membership{mfa_secret: ^secret, mfa_enabled_at: %DateTime{}} = updated, codes} =
               Fixtures.Memberships.enroll_mfa(secret, subject, session_token: session_token)

      assert is_list(codes) and length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
      # The stored set is the digests, not the plaintext.
      assert length(updated.mfa_recovery_codes) == 10
      refute Enum.any?(codes, &(&1 in updated.mfa_recovery_codes))

      assert {:ok, current_session} = Auth.fetch_session_by_token(session_token, account.id)
      assert current_session.membership.mfa_enabled_at == updated.mfa_enabled_at
      assert current_session.mfa_enrollment_verified_at == updated.mfa_enabled_at

      assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
      assert sibling_session.mfa_enrollment_verified_at == nil
    end

    test "with the wrong OTP returns :invalid_otp (nothing persisted)", %{
      member: member,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)

      assert Auth.enable_mfa(secret, "000000", proof, Crypto.hash(session_token), subject) ==
               {:error, :invalid_otp}

      refute Repo.reload!(member).mfa_enabled_at
    end

    test "a revoked, expired, foreign or non-session presented credential rolls enrollment and its audit back",
         %{
           account: account,
           member: member,
           secret: secret,
           subject: subject,
           session_token: session_token
         } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      otp = Fixtures.Auth.totp_code(secret)

      foreign = Fixtures.Memberships.create_membership(account_id: account.id)
      foreign_token = Fixtures.Auth.create_session_token!(foreign, :magic_link, nil)
      code = Fixtures.Auth.create_aged_token!(member, "magic_link", DateTime.utc_now())

      assert Auth.enable_mfa(secret, otp, proof, Crypto.hash(foreign_token), subject) ==
               {:error, :session_not_found}

      assert Auth.enable_mfa(secret, otp, proof, code.token, subject) ==
               {:error, :session_not_found}

      :ok = Auth.revoke_session_tokens([session_token], :dead_entry, %RequestContext{})

      assert Auth.enable_mfa(secret, otp, proof, Crypto.hash(session_token), subject) ==
               {:error, :session_not_found}

      refute Repo.reload!(member).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "an expired presented session rolls enrollment and its audit back", %{
      member: member,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)

      Fixtures.Auth.backdate_session_token!(
        session_token,
        DateTime.add(DateTime.utc_now(), -61, :day)
      )

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               proof,
               Crypto.hash(session_token),
               subject
             ) == {:error, :session_not_found}

      refute Repo.reload!(member).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "an address that lost its verification since the proof cannot enroll", %{
      member: member,
      secret: secret,
      subject: subject,
      session_token: session_token
    } do
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)
      member |> Ecto.Changeset.change(email_verified_at: nil) |> Repo.update!()

      assert Auth.enable_mfa(
               secret,
               Fixtures.Auth.totp_code(secret),
               proof,
               Crypto.hash(session_token),
               subject
             ) == {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(member).mfa_enabled_at
    end

    # recovery codes are shown once in plaintext, and only their SHA-256
    # digests are persisted (never the plaintext).
    test "recovery codes are stored as SHA-256 digests, never plaintext", %{
      secret: secret,
      subject: subject
    } do
      {member, codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      # Each plaintext code's stored form is exactly its SHA-256 digest.
      assert Enum.all?(codes, &(Crypto.hash(&1) in member.mfa_recovery_codes))
      # And no plaintext leaks into the at-rest set.
      refute Enum.any?(codes, &(&1 in member.mfa_recovery_codes))
    end
  end

  describe "enable_mfa/5 — SSO proof" do
    setup do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{provider: provider, member: member, identity: identity} = sso_route(account)

      raw =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      digest = Crypto.hash(raw)
      subject = Fixtures.Subjects.subject_for(member, session: raw)
      reauth = reauthentication(provider, identity, digest)
      {:ok, proof} = Auth.issue_mfa_enrollment_proof_for_sso(reauth, digest, subject)
      secret = Auth.generate_mfa_secret()

      %{
        account: account,
        provider: provider,
        member: member,
        identity: identity,
        raw: raw,
        digest: digest,
        subject: subject,
        reauth: reauth,
        proof: proof,
        secret: secret
      }
    end

    defp enable(context, proof \\ nil, digest \\ nil, subject \\ nil) do
      Auth.enable_mfa(
        context.secret,
        Fixtures.Auth.totp_code(context.secret),
        proof || context.proof,
        digest || context.digest,
        subject || context.subject
      )
    end

    test "a provider that does not satisfy MFA still enrolls, stamping only the ceremony's session",
         %{account: account, member: member, raw: raw} = context do
      assert {:ok, %Membership{mfa_enabled_at: %DateTime{}} = enrolled, codes} = enable(context)
      assert enrolled.id == member.id
      assert length(codes) == 10

      assert {:ok, session} = Auth.fetch_session_by_token(raw, account.id)
      assert session.mfa_enrollment_verified_at == enrolled.mfa_enabled_at
      assert Fixtures.Subjects.subject_for(member, session: raw).mfa
    end

    test "is refused once the provider is disabled, deleted or renamespaced",
         %{member: member, provider: provider} = context do
      Fixtures.SSO.disable_provider(provider)
      assert enable(context) == {:error, :mfa_enrollment_proof_stale}

      provider
      |> Ecto.Changeset.change(enabled: true, client_id: "another-client")
      |> Repo.update!()

      assert enable(context) == {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(member).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "is refused once the identity is retired, rebound, moved or deleted",
         %{account: account, member: member} = context do
      for change <- [:retired, :rebound, :moved, :deleted] do
        identity = Repo.reload!(context.identity)

        case change do
          :retired ->
            Fixtures.SSO.retire_identity(identity)

          :rebound ->
            identity
            |> Ecto.Changeset.change(provider_identifier: "someone-else")
            |> Repo.update!()

          :moved ->
            other = Fixtures.Memberships.create_membership(account_id: account.id)
            identity |> Ecto.Changeset.change(membership_id: other.id) |> Repo.update!()

          :deleted ->
            identity |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
        end

        assert enable(context) == {:error, :mfa_enrollment_proof_stale},
               "#{change} still enrolled"

        identity
        |> Ecto.Changeset.change(
          provider_identifier: context.identity.provider_identifier,
          provider_identifier_retired_at: nil,
          membership_id: member.id,
          deleted_at: nil
        )
        |> Repo.update!()
      end

      refute Repo.reload!(member).mfa_enabled_at
    end

    test "is refused once the workspace loses its SSO entitlement",
         %{account: account, member: member} = context do
      Fixtures.Accounts.create_subscription(account, "team", status: "canceled")
      assert enable(context) == {:error, :mfa_enrollment_proof_stale}
      refute Repo.reload!(member).mfa_enabled_at
    end

    test "is refused once the Member row was written or enrolled since the proof",
         %{member: member} = context do
      Fixtures.Memberships.sync_display_name(member, "Renamed")
      assert enable(context) == {:error, :mfa_enrollment_proof_stale}

      Fixtures.Memberships.set_mfa_state(member,
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now()
      )

      assert enable(context) == {:error, :mfa_already_enabled}
    end

    test "is refused when the IdP sign-in is older than ten minutes",
         %{digest: digest, member: member, reauth: reauth, subject: subject} = context do
      stale = %{reauth | auth_time: System.system_time(:second) - 700}

      {:ok, proof} =
        Auth.issue_mfa_enrollment_proof_for_sso(stale, digest, subject)

      assert enable(context, proof) == {:error, :mfa_enrollment_proof_stale}
      refute Repo.reload!(member).mfa_enabled_at
    end

    test "is refused from another session of the Member, an email-code session or another identity's session",
         %{account: account, identity: identity, member: member} = context do
      other_sso =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      other_subject = Fixtures.Subjects.subject_for(member, session: other_sso)

      assert enable(context, nil, Crypto.hash(other_sso), other_subject) ==
               {:error, :mfa_enrollment_proof_stale}

      email_raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      email_subject = Fixtures.Subjects.subject_for(member, session: email_raw)

      assert enable(context, nil, Crypto.hash(email_raw), email_subject) ==
               {:error, :mfa_enrollment_proof_stale}

      other_provider =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :openid_connect
        )

      other_identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: other_provider.id,
          membership: member
        })

      other_identity_raw =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{},
          user_identity_id: other_identity.id
        )

      other_identity_subject =
        Fixtures.Subjects.subject_for(member, session: other_identity_raw)

      assert enable(context, nil, Crypto.hash(other_identity_raw), other_identity_subject) ==
               {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(member).mfa_enabled_at
      assert events_of_type("user.mfa_enabled") == []
    end

    test "a proof minted for Member A is refused for Member B", %{account: account} = context do
      %{member: other, identity: other_identity} =
        sso_route(account, kind: :openid_connect)

      other_raw =
        Fixtures.Auth.create_session_token!(other, :sso, nil, %{},
          user_identity_id: other_identity.id
        )

      other_subject = Fixtures.Subjects.subject_for(other, session: other_raw)

      assert enable(context, nil, Crypto.hash(other_raw), other_subject) ==
               {:error, :mfa_enrollment_proof_stale}

      refute Repo.reload!(other).mfa_enabled_at
    end
  end

  describe "disable_mfa/2" do
    setup do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "uses the fresh Member row to clear MFA", %{secret: secret, subject: subject} do
      {_member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      refute subject.actor.mfa_enabled_at

      assert {:ok, %Membership{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(Fixtures.Auth.totp_code(secret), subject)

      assert [event] = events_of_type("user.mfa_disabled")
      assert event.actor_id == subject.membership_id
    end

    test "accepts a valid recovery code", %{secret: secret, subject: subject} do
      {_member, [code | _]} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, %Membership{mfa_secret: nil, mfa_enabled_at: nil, mfa_recovery_codes: []}} =
               Auth.disable_mfa(code, subject)
    end

    test "leaves the caller's sessions signed in", %{secret: secret, subject: subject} do
      {member, [code | _]} = Fixtures.Memberships.enable_mfa!(secret, subject)
      token = Fixtures.Auth.create_session_token!(member, :magic_link, DateTime.utc_now())

      assert {:ok, %Membership{mfa_enabled_at: nil}} = Auth.disable_mfa(code, subject)

      # Turning your own factor off is not a compromise signal, so it does not
      # sign you out. The claim it stripped is the local enrollment epoch, which
      # binds the session's proof to the enrollment it was taken against. The
      # sockets ARE dropped so each re-decides — proven end-to-end in
      # `EmisarWeb.MfaDisableDisconnectTest`, since the disconnect handler lives
      # in `emisar_web` and is a no-op in this `:emisar`-only test process.
      assert {:ok, %UserToken{}} = Auth.fetch_session_by_token(token, member.account_id)
      refute Fixtures.Subjects.subject_for(member, session: token).mfa
    end

    test "rejects a wrong or missing code and leaves MFA enabled", %{
      secret: secret,
      subject: subject
    } do
      {_member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert Auth.disable_mfa("not-a-real-code", subject) == {:error, :invalid_code}
      assert Auth.disable_mfa(nil, subject) == {:error, :invalid_code}
      assert %Membership{mfa_enabled_at: %DateTime{}} = Repo.reload!(subject.actor)
    end

    test "shares the MFA attempt cap with sign-in without consuming a recovery code", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {member, [code | _]} = Fixtures.Memberships.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(member.id, {:totp, "000000"}) == {:error, :invalid}
      end

      # The sign-in misses spent the window, so a genuine recovery code is
      # refused before the consume — MFA stays on and the code stays usable.
      assert Auth.disable_mfa(code, subject) == {:error, :rate_limited}

      reloaded = Repo.reload!(member)
      assert %DateTime{} = reloaded.mfa_enabled_at
      assert reloaded.mfa_recovery_codes == member.mfa_recovery_codes
    end

    test "a Member without MFA has nothing to disable", %{subject: subject} do
      assert Auth.disable_mfa("000000", subject) == {:error, :invalid_code}
    end
  end

  describe "regenerate_mfa_recovery_codes/2" do
    setup do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "issues a fresh set and invalidates the old (MFA stays enabled)", %{
      secret: secret,
      subject: subject
    } do
      {_member, [old_code | _]} = Fixtures.Memberships.enable_mfa!(secret, subject)
      otp = Fixtures.Auth.totp_code(secret)

      assert {:ok, %Membership{mfa_enabled_at: %DateTime{}} = member, new_codes} =
               Auth.regenerate_mfa_recovery_codes(otp, subject)

      assert length(new_codes) == 10
      # MFA stays enabled; the old plaintext code no longer matches, a new one does.
      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, old_code}) ==
               {:error, :invalid}

      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, hd(new_codes)})
    end

    test "an existing recovery code can prove a lost-authenticator regeneration", %{
      secret: secret,
      subject: subject
    } do
      {:ok, _member, [proof_code | old_codes]} = Fixtures.Memberships.enroll_mfa(secret, subject)

      assert {:ok, updated, new_codes} =
               Auth.regenerate_mfa_recovery_codes(proof_code, subject)

      assert length(new_codes) == 10
      refute Enum.any?([proof_code | old_codes], &(Crypto.hash(&1) in updated.mfa_recovery_codes))
    end

    test "two concurrent recovery proofs produce one authoritative replacement", %{
      secret: secret,
      subject: subject
    } do
      {:ok, member, [proof_a, proof_b | _]} = Fixtures.Memberships.enroll_mfa(secret, subject)

      results =
        [proof_a, proof_b]
        |> Enum.map(&regenerate_recovery_codes_task(&1, subject))
        |> Enum.map(&Task.await(&1, 5_000))

      assert [{:ok, _updated, winner_codes}] =
               Enum.filter(results, &match?({:ok, %Membership{}, _codes}, &1))

      assert Enum.count(results, &(&1 == {:error, :invalid_code})) == 1
      assert Repo.reload!(member).mfa_recovery_codes == Enum.map(winner_codes, &Crypto.hash/1)
    end

    test "two concurrent submissions of one TOTP produce one success and one replay", %{
      secret: secret,
      subject: subject
    } do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      otp = Fixtures.Auth.totp_code(secret)

      results =
        otp
        |> List.duplicate(2)
        |> Enum.map(&regenerate_recovery_codes_task(&1, subject))
        |> Enum.map(&Task.await(&1, 5_000))

      assert [{:ok, _updated, winner_codes}] =
               Enum.filter(results, &match?({:ok, %Membership{}, _codes}, &1))

      assert Enum.count(results, &(&1 == {:error, :replay})) == 1
      assert Repo.reload!(member).mfa_recovery_codes == Enum.map(winner_codes, &Crypto.hash/1)
    end

    test "wrong or missing proof leaves the old code set unchanged", %{
      secret: secret,
      subject: subject
    } do
      {:ok, member, _codes} = Fixtures.Memberships.enroll_mfa(secret, subject)
      old_digests = member.mfa_recovery_codes

      assert Auth.regenerate_mfa_recovery_codes("not-a-recovery-code", subject) ==
               {:error, :invalid_code}

      assert Auth.regenerate_mfa_recovery_codes(nil, subject) == {:error, :invalid_code}
      assert Repo.reload!(member).mfa_recovery_codes == old_digests

      assert [event] = events_of_type("user.mfa_failed")
      assert event.payload["reason"] == "invalid_recovery_code"
      assert events_of_type("user.mfa_recovery_codes_regenerated") == []
    end

    test "the shared attempt cap refuses even a valid proof without replacing codes", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {:ok, member, _codes} = Fixtures.Memberships.enroll_mfa(secret, subject)
      old_digests = member.mfa_recovery_codes
      stale_otp = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 90)

      for _ <- 1..5 do
        assert Auth.regenerate_mfa_recovery_codes(stale_otp, subject) == {:error, :invalid_code}
      end

      assert Auth.regenerate_mfa_recovery_codes(
               Fixtures.Auth.totp_code(secret),
               subject
             ) == {:error, :rate_limited}

      assert Repo.reload!(member).mfa_recovery_codes == old_digests
      assert [_event] = events_of_type("user.mfa_rate_limited")
      assert events_of_type("user.mfa_recovery_codes_regenerated") == []
    end

    test "a stale enabled subject is refused after the locked row is disabled", %{
      secret: secret,
      subject: subject
    } do
      {:ok, member, _codes} = Fixtures.Memberships.enroll_mfa(secret, subject)

      Fixtures.Memberships.set_mfa_state(member,
        mfa_secret: nil,
        mfa_enabled_at: nil,
        mfa_recovery_codes: []
      )

      assert Auth.regenerate_mfa_recovery_codes(
               Fixtures.Auth.totp_code(secret),
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

  describe "check_security_attempt/5" do
    setup do
      {owner, _account, _subject} = Fixtures.Subjects.owner_subject()
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      %{member: owner}
    end

    test "resets from database time and saturates after the first rejection", %{member: member} do
      for _ <- 1..5 do
        assert Auth.check_security_attempt(member, :mfa_challenge, 5, 300_000) == :ok
      end

      assert Auth.check_security_attempt(member, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :exhausted}

      assert Auth.check_security_attempt(member, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :capped}

      window =
        Repo.get_by!(SecurityAttemptWindow, membership_id: member.id, scope: :mfa_challenge)

      assert window.attempt_count == 6

      expired = ~U[2001-01-01 00:05:00.000000Z]

      window
      |> Ecto.Changeset.change(
        window_started_at: DateTime.add(expired, -300, :second),
        window_expires_at: expired
      )
      |> Repo.update!()

      assert Auth.check_security_attempt(member, :mfa_challenge, 5, 300_000) == :ok

      reset = Repo.reload!(window)
      assert reset.attempt_count == 1
      assert DateTime.compare(reset.window_started_at, expired) == :gt
      assert DateTime.compare(reset.window_expires_at, reset.window_started_at) == :gt
    end

    test "the window is per Member: a namesake elsewhere has its own", %{member: member} do
      elsewhere = Fixtures.Memberships.create_membership(email: member.email)

      for _ <- 1..6, do: Auth.check_security_attempt(member, :mfa_challenge, 5, 300_000)
      assert Auth.check_security_attempt(elsewhere, :mfa_challenge, 5, 300_000) == :ok
    end

    test "a persistence failure rejects the credential attempt", %{member: member} do
      missing_member = %{member | id: Repo.generate_id()}

      assert Auth.check_security_attempt(missing_member, :mfa_challenge, 5, 300_000) ==
               {:error, :rate_limited, :store_unavailable}
    end

    test "carries request provenance onto the first over-limit audit signal", %{member: member} do
      context = %RequestContext{request_id: "req-direct-security-attempt"}

      assert Auth.check_security_attempt(member, :mfa_challenge, 1, 300_000, context) == :ok

      assert Auth.check_security_attempt(member, :mfa_challenge, 1, 300_000, context) ==
               {:error, :rate_limited, :exhausted}

      assert [event] = events_of_type("user.mfa_rate_limited")
      assert {event.account_id, event.actor_id} == {member.account_id, member.id}
      assert event.request_id == "req-direct-security-attempt"
    end

    test "logs each credential limit under its accurate event type", %{member: member} do
      for scope <- [:inbox_step_up, :oidc_identity_step_up_issue, :mfa_enrollment_issue] do
        context = %RequestContext{request_id: "req-#{scope}"}

        assert Auth.check_security_attempt(member, scope, 1, 300_000, context) == :ok

        assert Auth.check_security_attempt(member, scope, 1, 300_000, context) ==
                 {:error, :rate_limited, :exhausted}

        assert Auth.check_security_attempt(member, scope, 1, 300_000, context) ==
                 {:error, :rate_limited, :capped}
      end

      assert [verify_event] = events_of_type("user.inbox_step_up_rate_limited")
      assert verify_event.payload["scope"] == "inbox_step_up"
      assert verify_event.request_id == "req-inbox_step_up"

      assert [step_up_event] = events_of_type("user.oidc_identity_step_up_rate_limited")
      assert step_up_event.payload["scope"] == "oidc_identity_step_up_issue"
      assert step_up_event.request_id == "req-oidc_identity_step_up_issue"

      assert [enrollment_event] = events_of_type("user.mfa_rate_limited")
      assert enrollment_event.payload["scope"] == "mfa_enrollment_issue"
    end
  end

  describe "verify_mfa_challenge/3" do
    setup do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      %{subject: subject, secret: Auth.generate_mfa_secret()}
    end

    test "accepts a valid OTP once and rejects an immediate replay", %{
      secret: secret,
      subject: subject
    } do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      otp = Fixtures.Auth.totp_code(secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:totp, otp})
      assert Auth.verify_mfa_challenge(member.id, {:totp, otp}) == {:error, :replay}

      assert [event] = events_of_type("user.mfa_verified")
      assert event.payload["factor"] == "totp"
    end

    test "rejects an invalid OTP and audits the miss", %{secret: secret, subject: subject} do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(member.id, {:totp, "000000"}) == {:error, :invalid}
      assert [event] = events_of_type("user.mfa_failed")
      assert event.actor_id == member.id
    end

    test "a malformed factor, an unknown, unenrolled, suspended or removed Member is the catch-all :invalid",
         %{secret: secret, subject: subject} do
      unenrolled = Fixtures.Memberships.create_membership()
      assert Auth.verify_mfa_challenge(unenrolled.id, {:totp, "000000"}) == {:error, :invalid}

      assert Auth.verify_mfa_challenge(Ecto.UUID.generate(), {:totp, "000000"}) ==
               {:error, :invalid}

      assert Auth.verify_mfa_challenge("not-a-uuid", {:totp, "000000"}) == {:error, :invalid}

      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      assert Auth.verify_mfa_challenge(member.id, {:totp, nil}) == {:error, :invalid}
      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, nil}) == {:error, :invalid}
      assert Auth.verify_mfa_challenge(member.id, {:sms, "000000"}) == {:error, :invalid}

      Fixtures.Memberships.suspend_membership(member)

      assert Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)}) ==
               {:error, :invalid}
    end

    # a non-numeric OTP is rejected, and because the replay guard only stamps
    # on a *valid* code, the real code still works right after (the bad attempt
    # didn't burn the current bucket).
    test "rejects a non-numeric OTP without burning the live code", %{
      secret: secret,
      subject: subject
    } do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(member.id, {:totp, "abcdef"}) == {:error, :invalid}

      # The genuine current code is untouched by the failed attempt.
      otp = Fixtures.Auth.totp_code(secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:totp, otp})
    end

    test "an OTP can't complete sign-in after MFA was disabled mid-verify (MAJOR-4)", %{
      secret: secret,
      subject: subject
    } do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      otp = Fixtures.Auth.totp_code(secret)

      {:ok, _} = Auth.disable_mfa(otp, subject)

      # The locked verify reads the CURRENT row (MFA now disabled) and refuses.
      assert Auth.verify_mfa_challenge(member.id, {:totp, otp}) == {:error, :invalid}
    end

    test "an OTP for a rotated secret can't complete sign-in (MAJOR-4)", %{subject: subject} do
      secret1 = Auth.generate_mfa_secret()
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret1, subject)
      otp1 = Fixtures.Auth.totp_code(secret1)

      # Rotate the secret out from under the in-flight verify (disable + re-enable).
      {:ok, _} = Auth.disable_mfa(otp1, subject)
      secret2 = Auth.generate_mfa_secret()
      {_member2, _codes} = Fixtures.Memberships.enable_mfa!(secret2, subject)

      # `otp1` is for the OLD secret; the locked verify validates against the
      # current secret2 and refuses.
      assert Auth.verify_mfa_challenge(member.id, {:totp, otp1}) == {:error, :invalid}
    end

    test "accepts a fresh recovery code once, rejects reuse, leaves siblings valid", %{
      secret: secret,
      subject: subject
    } do
      {member, [code, other_code | _]} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, code})
      assert [event] = events_of_type("user.mfa_recovery_code_used")
      assert event.payload["remaining"] == 9

      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, code}) == {:error, :invalid}

      # Consuming one code doesn't invalidate the rest of the set.
      assert {:ok, _proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, other_code})
    end

    test "rejects an unknown recovery code as :invalid", %{secret: secret, subject: subject} do
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, "not-a-real-code"}) ==
               {:error, :invalid}

      assert [event] = events_of_type("user.mfa_failed")
      assert event.payload["reason"] == "invalid_recovery_code"
    end

    test "counts both factors against one per-Member window and refuses the sixth attempt", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(member.id, {:totp, "000000"}) == {:error, :invalid}
      end

      # The window is exhausted: even the genuine current code is refused, and
      # switching to the recovery factor doesn't buy more attempts.
      otp = Fixtures.Auth.totp_code(secret)
      assert Auth.verify_mfa_challenge(member.id, {:totp, otp}) == {:error, :rate_limited}

      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, "not-a-real-code"}) ==
               {:error, :rate_limited}

      # The capped attempt never reached verification: the genuine code was
      # refused without being consumed (a verify would have stamped the row).
      assert Repo.reload!(member).mfa_last_used_at == member.mfa_last_used_at
    end

    test "the cap is per Member — an exhausted window doesn't throttle another Member", %{
      secret: secret,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      {_other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      other_secret = Auth.generate_mfa_secret()
      {other_member, _other_codes} = Fixtures.Memberships.enable_mfa!(other_secret, other_subject)

      for _ <- 1..6, do: Auth.verify_mfa_challenge(member.id, {:totp, "000000"})

      other_otp = Fixtures.Auth.totp_code(other_secret)
      assert {:ok, _proof} = Auth.verify_mfa_challenge(other_member.id, {:totp, other_otp})
    end

    test "concurrent attempts can't overshoot the window", %{secret: secret, subject: subject} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> Auth.verify_mfa_challenge(member.id, {:totp, "000000"}) end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &(&1 == {:error, :invalid})) == 5
      assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 5
    end
  end

  describe "verify_current_session_mfa_challenge/2" do
    test "uses the session's Member and rejects a non-Member actor or an ended session" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_current_session_mfa_challenge(
                 {:totp, Fixtures.Auth.totp_code(secret)},
                 subject
               )

      assert Auth.mfa_proof_membership_id(proof) == member.id

      assert Auth.verify_current_session_mfa_challenge(
               {:recovery_code, "not-a-real-code"},
               %Subject{}
             ) == {:error, :unauthorized}

      Fixtures.Memberships.suspend_membership(member)

      assert Auth.verify_current_session_mfa_challenge(
               {:totp, Fixtures.Auth.totp_code(secret)},
               subject
             ) == {:error, :unauthorized}
    end
  end

  describe "issue_member_mfa_reset_proof/4" do
    test "binds a verified local source to the actor, its session, the account, the target and its epoch" do
      reset = member_mfa_reset_auth_fixture()

      assert {:ok, payload} = Auth.verify_member_mfa_reset_proof(reset.reset_proof)
      assert payload.actor_membership_id == reset.actor.id
      assert payload.account_id == reset.account.id
      assert payload.target_membership_id == reset.target.id
      assert payload.target_mfa_enabled_at == reset.target.mfa_enabled_at
      assert payload.target_updated_at == reset.target.updated_at
      assert payload.actor_session_token_digest == reset.actor_session_token_digest
      assert payload.source == {:local, reset.local_proof}

      assert Auth.issue_member_mfa_reset_proof(
               %{reset.target | mfa_enabled_at: nil},
               {:local, reset.local_proof},
               reset.actor_session_token_digest,
               reset.subject
             ) == {:error, :mfa_reset_proof_stale}

      {_other, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Auth.issue_member_mfa_reset_proof(
               reset.target,
               {:local, reset.local_proof},
               reset.actor_session_token_digest,
               other_subject
             ) == {:error, :mfa_reset_proof_stale}

      assert Auth.issue_member_mfa_reset_proof(
               reset.target,
               {:sms, %{}},
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

      assert Auth.verify_member_mfa_reset_proof(nil) == {:error, :mfa_reset_proof_stale}

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

      changed = Fixtures.Memberships.sync_display_name(reset.actor, "Changed after verification")

      assert Auth.verify_local_member_mfa_reset_source(
               {:local, reset.local_proof},
               changed
             ) == {:error, :mfa_reset_proof_stale}

      assert Auth.verify_local_member_mfa_reset_source({:sso, %{}}, reset.actor) ==
               {:error, :mfa_reset_proof_stale}
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
    test "accepts only a live session of the acting Member, and for SSO only on the proved identity" do
      reset = member_mfa_reset_auth_fixture()

      assert {:ok, %UserToken{membership_id: actor_id}} =
               Auth.lock_member_mfa_reset_session(
                 Repo,
                 reset.actor_session_token_digest,
                 reset.actor,
                 {:local, reset.local_proof}
               )

      assert actor_id == reset.actor.id

      assert Auth.lock_member_mfa_reset_session(
               Repo,
               reset.actor_session_token_digest,
               reset.actor,
               {:sso, %{identity_id: Repo.generate_id()}}
             ) == {:error, :mfa_reset_proof_stale}

      assert Auth.lock_member_mfa_reset_session(
               Repo,
               reset.actor_session_token_digest,
               reset.target,
               {:local, reset.local_proof}
             ) == {:error, :mfa_reset_proof_stale}

      :ok =
        Auth.revoke_session_tokens([reset.actor_session_token], :dead_entry, %RequestContext{})

      assert Auth.lock_member_mfa_reset_session(
               Repo,
               reset.actor_session_token_digest,
               reset.actor,
               {:local, reset.local_proof}
             ) == {:error, :mfa_reset_proof_stale}
    end
  end

  describe "complete_current_session_mfa/3" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      secret = Auth.generate_mfa_secret()
      {enrolled, recovery_codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      session_token = Fixtures.Auth.create_session_token!(enrolled, :magic_link, nil)

      %{
        account: account,
        subject: Fixtures.Subjects.subject_for(enrolled, session: session_token),
        secret: secret,
        member: enrolled,
        recovery_codes: recovery_codes,
        session_token: session_token
      }
    end

    test "a TOTP proof stamps only the presented live session and audits the upgrade", %{
      account: account,
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      sibling_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      generated_at = System.os_time(:second)
      code = NimbleTOTP.verification_code(secret, time: generated_at)

      result =
        case Auth.verify_mfa_challenge(member.id, {:totp, code}) do
          {:error, :invalid} ->
            # This test exercises session stamping, not clock rollover. Retry
            # only when generating and consuming the code straddled a bucket;
            # an invalid code within the same bucket must still fail the test.
            assert div(System.os_time(:second), 30) != div(generated_at, 30)
            Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

          result ->
            result
        end

      assert {:ok, proof} = result

      assert {:ok, %UserToken{id: updated_id}} =
               Auth.complete_current_session_mfa(proof, Crypto.hash(session_token), subject)

      assert {:ok, current_session} = Auth.fetch_session_by_token(session_token, account.id)
      assert current_session.id == updated_id

      assert current_session.mfa_enrollment_verified_at ==
               current_session.membership.mfa_enabled_at

      assert Fixtures.Subjects.subject_for(member, session: session_token).mfa

      assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
      assert sibling_session.mfa_enrollment_verified_at == nil

      # Two rows: the factor was accepted, then the live session's assurance
      # was actually upgraded.
      assert [session_event, factor_event] =
               Enum.sort_by(events_of_type("user.mfa_verified"), & &1.id, :desc)

      assert factor_event.payload["factor"] == "totp"
      assert session_event.payload["session_verified"] == true
    end

    test "a recovery proof adds local assurance without rewriting SSO provenance", %{
      account: account,
      member: member,
      recovery_codes: [recovery_code | _]
    } do
      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      idp_verified_at = DateTime.utc_now()

      sso_token =
        Fixtures.Auth.create_session_token!(member, :sso, idp_verified_at, %{},
          user_identity_id: identity.id
        )

      sibling_token =
        Fixtures.Auth.create_session_token!(member, :sso, idp_verified_at, %{},
          user_identity_id: identity.id
        )

      sso_subject = Fixtures.Subjects.subject_for(member, session: sso_token)
      refute sso_subject.mfa

      assert {:ok, proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, recovery_code})

      assert {:ok, _session} =
               Auth.complete_current_session_mfa(proof, Crypto.hash(sso_token), sso_subject)

      assert {:ok, session} = Auth.fetch_session_by_token(sso_token, account.id)
      assert session.auth_method == :sso
      assert session.user_identity_id == identity.id
      assert session.mfa_verified_at == idp_verified_at
      assert session.mfa_enrollment_verified_at == session.membership.mfa_enabled_at
      assert Fixtures.Subjects.subject_for(member, session: sso_token).mfa

      assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
      assert sibling_session.mfa_enrollment_verified_at == nil

      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, recovery_code}) ==
               {:error, :invalid}
    end

    test "proof, subject, and token must all name the same Member", %{
      account: account,
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      {other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()
      other_token = Fixtures.Auth.create_session_token!(other_owner, :magic_link, nil)

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(session_token), other_subject) ==
               {:error, :mfa_proof_stale}

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(other_token), subject) ==
               {:error, :session_not_found}

      assert {:ok, session} = Auth.fetch_session_by_token(session_token, account.id)
      assert session.mfa_enrollment_verified_at == nil
    end

    test "a revoked session grants nothing while the recovery code stays consumed", %{
      member: member,
      subject: subject,
      recovery_codes: [recovery_code | _],
      session_token: session_token
    } do
      assert {:ok, proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, recovery_code})

      :ok = Auth.revoke_session_tokens([session_token], :dead_entry, %RequestContext{})

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(session_token), subject) ==
               {:error, :session_not_found}

      assert Auth.verify_mfa_challenge(member.id, {:recovery_code, recovery_code}) ==
               {:error, :invalid}
    end

    test "an expired or wrong-context token cannot be upgraded", %{
      member: member,
      subject: subject,
      secret: secret,
      session_token: session_token
    } do
      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      code = Fixtures.Auth.create_aged_token!(member, "magic_link", DateTime.utc_now())

      assert Auth.complete_current_session_mfa(proof, code.token, subject) ==
               {:error, :session_not_found}

      Fixtures.Auth.backdate_session_token!(
        session_token,
        DateTime.add(DateTime.utc_now(), -61, :day)
      )

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(session_token), subject) ==
               {:error, :session_not_found}

      session =
        UserToken.Query.by_token_digest(Crypto.hash(session_token))
        |> Repo.one!()

      assert session.mfa_enrollment_verified_at == nil
    end

    test "a disable and re-enroll makes an in-flight proof stale", %{
      account: account,
      member: member,
      subject: subject,
      recovery_codes: [proof_code, disable_code | _],
      session_token: session_token
    } do
      assert {:ok, proof} = Auth.verify_mfa_challenge(member.id, {:recovery_code, proof_code})
      assert {:ok, _disabled} = Auth.disable_mfa(disable_code, subject)

      {_re_enrolled, _codes} =
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert Auth.complete_current_session_mfa(proof, Crypto.hash(session_token), subject) ==
               {:error, :mfa_proof_stale}

      assert {:ok, session} = Auth.fetch_session_by_token(session_token, account.id)
      assert session.mfa_enrollment_verified_at == nil
    end
  end

  describe "mfa_proof_membership_id/1" do
    test "names the Member a verified proof was minted for" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {member, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert {:ok, proof} =
               Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert Auth.mfa_proof_membership_id(proof) == member.id
    end

    test "anything that isn't a proof names no one" do
      member = Fixtures.Memberships.create_membership()

      assert Auth.mfa_proof_membership_id(Ecto.UUID.generate()) == nil
      assert Auth.mfa_proof_membership_id(%{membership_id: member.id}) == nil
      assert Auth.mfa_proof_membership_id(nil) == nil

      incomplete_enrollment = %{
        membership_id: member.id,
        mfa_enabled_at: nil,
        updated_at: DateTime.utc_now()
      }

      assert Auth.mfa_proof_membership_id(incomplete_enrollment) == nil
    end
  end

  defp member_mfa_reset_auth_fixture do
    {_actor, account, subject} = Fixtures.Subjects.owner_subject()
    secret = Auth.generate_mfa_secret()
    {actor, _recovery_codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

    target =
      Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      |> Fixtures.Memberships.set_mfa_state(
        mfa_secret: Auth.generate_mfa_secret(),
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: []
      )

    {:ok, local_proof} =
      Auth.verify_current_session_mfa_challenge(
        {:totp, Fixtures.Auth.totp_code(secret)},
        subject
      )

    actor = Repo.reload!(actor)
    actor_session_token = Fixtures.Auth.create_session_token!(actor, :magic_link, nil)
    subject = Fixtures.Subjects.subject_for(actor, session: actor_session_token)
    actor_session_token_digest = Crypto.hash(actor_session_token)

    {:ok, reset_proof} =
      Auth.issue_member_mfa_reset_proof(
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
      target: target
    }
  end
end
