defmodule Emisar.AuthAuditTest do
  @moduledoc """
  Asserts that every security-relevant operation in the Auth + Accounts
  contexts emits the expected `Audit.Event` row, in the Member's own
  workspace. Covers sign-in / out, MFA, the emailed code, SSO sign-in, session
  revocation, and the account and membership lifecycle.

  Each test seeds an owner and asserts the matching event_type appears in
  `Audit.list_events/1` scoped to that account.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, RequestContext}
  alias Emisar.Auth.SecurityAttemptWindow
  alias Emisar.Fixtures

  # A PERSISTED owner, because audit reads narrow by the reader's runner access
  # and a membership that doesn't resolve reads as `none` — which withholds the
  # runner/group identity these assertions are about.
  defp events_of(account, event_type) do
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    subject = Fixtures.Subjects.subject_for(membership)

    {:ok, events, _} =
      Audit.list_events(subject, filter: [event_type: [event_type]])

    events
  end

  # The raw secret only leaves Auth by email, so a magic-link test drives the
  # real request workflow and reads the 6-character code back out of the
  # delivered message.
  defp request_magic_link(account, email) do
    assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
             Auth.request_magic_link(account, email, %RequestContext{})

    assert_received {:email, sent}
    [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
    {token_id, nonce, secret}
  end

  defp browser_id, do: Crypto.random_secret()

  describe "sign-out" do
    test "complete_browser_sign_out audits each ended session in its workspace, once" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      browser = browser_id()

      token =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{}, browser_id: browser)

      context = %RequestContext{ip_address: "198.51.100.7", request_id: "req-sign-out"}

      assert {:ok, [%Accounts.Membership{id: owner_id}]} =
               Auth.complete_browser_sign_out([token], browser, context)

      assert owner_id == owner.id
      assert [event] = events_of(account, "user.signed_out")
      assert {event.actor_kind, event.actor_id} == {"membership", owner.id}
      assert event.request_id == "req-sign-out"

      # The second submit finds nothing live and records nothing.
      assert {:ok, []} = Auth.complete_browser_sign_out([token], browser, context)
      assert [_same] = events_of(account, "user.signed_out")
    end
  end

  describe "MFA lifecycle" do
    setup do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      session_token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(owner, session: session_token)
      secret = Auth.generate_mfa_secret()
      proof = Fixtures.Memberships.mfa_enrollment_proof(subject)

      %{
        member: owner,
        account: account,
        secret: secret,
        subject: subject,
        proof: proof,
        session_token: session_token
      }
    end

    test "issuing the enrollment challenge audits the request without the code or address", %{
      account: account,
      subject: subject
    } do
      assert [event] = events_of(account, "user.mfa_enrollment_requested")
      assert event.actor_id == subject.membership_id
      assert event.payload == %{}
    end

    test "enable_mfa audits on success", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      otp = Fixtures.Auth.totp_code(secret)

      assert {:ok, _updated, _codes} =
               Auth.enable_mfa(secret, otp, proof, Crypto.hash(session_token), subject)

      assert [event] = events_of(account, "user.mfa_enabled")
      assert event.actor_id == subject.membership_id
    end

    test "disable_mfa audits", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      Fixtures.Memberships.enrolled_a_step_ago(enabled)

      :ok = Audit.subscribe_account_audit(account.id)
      assert {:ok, _} = Auth.disable_mfa(Fixtures.Auth.totp_code(secret), subject)
      assert [event] = events_of(account, "user.mfa_disabled")
      assert event.actor_id == subject.membership_id
      assert_receive {:audit_event, ^event}
      assert [_verified] = events_of(account, "user.mfa_verified")
    end

    test "verify_mfa_challenge with bad code audits user.mfa_failed", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      assert Auth.verify_mfa_challenge(enabled.id, {:totp, "000000"}) == {:error, :invalid}

      assert [event] = events_of(account, "user.mfa_failed")
      assert event.payload["reason"] == "invalid_otp"
    end

    test "verify_mfa_challenge TOTP success audits user.mfa_verified", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      enabled = Fixtures.Memberships.enrolled_a_step_ago(enabled)

      assert {:ok, _proof} =
               Auth.verify_mfa_challenge(enabled.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert [event] = events_of(account, "user.mfa_verified")
      assert event.actor_id == subject.membership_id
      assert event.payload["factor"] == "totp"
    end

    test "completing a session step-up audits when the session became MFA-verified", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      enabled = Fixtures.Memberships.enrolled_a_step_ago(enabled)

      assert {:ok, mfa_proof} =
               Auth.verify_mfa_challenge(enabled.id, {:totp, Fixtures.Auth.totp_code(secret)})

      assert {:ok, _session} =
               Auth.complete_current_session_mfa(mfa_proof, Crypto.hash(session_token), subject)

      # Two rows: the factor was accepted, then the live session's assurance
      # was actually upgraded. The stamp lives on a session row the retention
      # sweep deletes, so the trail is the only durable record of the second.
      assert [session_event, factor_event] = events_of(account, "user.mfa_verified")
      assert factor_event.payload["factor"] == "totp"
      assert session_event.payload["session_verified"] == true
    end

    test "verify_mfa_challenge recovery success audits with remaining count", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, codes} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      assert {:ok, _proof} = Auth.verify_mfa_challenge(enabled.id, {:recovery_code, hd(codes)})

      assert [event] = events_of(account, "user.mfa_recovery_code_used")
      assert event.payload["remaining"] == length(codes) - 1
    end

    test "verify_mfa_challenge with bad recovery code audits user.mfa_failed", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      assert Auth.verify_mfa_challenge(enabled.id, {:recovery_code, "not-a-real-code"}) ==
               {:error, :invalid}

      assert [event] = events_of(account, "user.mfa_failed")
      assert event.payload["reason"] == "invalid_recovery_code"
    end

    test "a capped step-up audits neither a miss nor a recovery-code use", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      subject = %{subject | context: %RequestContext{request_id: "req-mfa-rate-limit"}}

      {:ok, enabled, codes} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enabled.id, {:totp, "000000"}) == {:error, :invalid}
      end

      assert length(events_of(account, "user.mfa_failed")) == 5
      assert events_of(account, "user.mfa_rate_limited") == []

      # The window is spent, so disable_mfa refuses a genuine recovery code
      # before verification — it can neither record a miss the operator didn't
      # make nor spend the code. Its first rejection emits one durable signal.
      assert Auth.disable_mfa(hd(codes), subject) == {:error, :rate_limited}

      assert length(events_of(account, "user.mfa_failed")) == 5
      assert events_of(account, "user.mfa_recovery_code_used") == []

      assert [event] = events_of(account, "user.mfa_rate_limited")
      assert event.actor_id == subject.membership_id
      assert event.target_id == subject.membership_id
      assert event.request_id == "req-mfa-rate-limit"
      assert event.payload["scope"] == "mfa_challenge"
      assert event.payload["attempt_limit"] == 5
      assert event.payload["window_seconds"] == 300

      window =
        Repo.get_by!(SecurityAttemptWindow,
          membership_id: enabled.id,
          scope: :mfa_challenge
        )

      assert window.attempt_count == 6

      # Sustained traffic after exhaustion is a pure rejection: no limiter
      # update and no extra audit row.
      assert Auth.disable_mfa(hd(codes), subject) == {:error, :rate_limited}
      assert Repo.reload!(window).updated_at == window.updated_at
      assert [same_event] = events_of(account, "user.mfa_rate_limited")
      assert same_event.id == event.id
    end

    test "regenerate_mfa_recovery_codes audits", %{
      account: account,
      secret: secret,
      subject: subject,
      proof: proof,
      session_token: session_token
    } do
      {:ok, enabled, _} =
        Auth.enable_mfa(
          secret,
          Fixtures.Auth.totp_code(secret),
          proof,
          Crypto.hash(session_token),
          subject
        )

      Fixtures.Memberships.enrolled_a_step_ago(enabled)

      :ok = Audit.subscribe_account_audit(account.id)

      {:ok, _, _codes} =
        Auth.regenerate_mfa_recovery_codes(Fixtures.Auth.totp_code(secret), subject)

      assert [event] = events_of(account, "user.mfa_recovery_codes_regenerated")
      assert event.actor_id == subject.membership_id
      assert event.payload == %{}
      assert_receive {:audit_event, ^event}
    end

    for operation <- [:disable_mfa, :regenerate_mfa_recovery_codes] do
      @operation operation
      test "#{operation} audit failure preserves the factor and emits no success broadcast", %{
        account: account,
        secret: secret,
        subject: subject,
        proof: proof,
        session_token: session_token
      } do
        assert {:ok, enabled, [code | _]} =
                 Auth.enable_mfa(
                   secret,
                   Fixtures.Auth.totp_code(secret),
                   proof,
                   Crypto.hash(session_token),
                   subject
                 )

        before = Repo.reload!(enabled)
        audit_count = Repo.aggregate(Audit.Event, :count)
        :ok = Audit.subscribe_account_audit(account.id)
        Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
        invalid = %{subject | context: %RequestContext{request_id: %{invalid: true}}}

        assert {:error, _reason} = apply(Auth, @operation, [code, invalid])
        assert Repo.reload!(enabled) == before
        assert Repo.aggregate(Audit.Event, :count) == audit_count

        assert Repo.get_by!(SecurityAttemptWindow,
                 membership_id: enabled.id,
                 scope: :mfa_challenge
               ).attempt_count == 1

        refute_received {:audit_event, _}
      end
    end
  end

  describe "the emailed code" do
    setup do
      {owner, account, _} = Fixtures.Subjects.owner_subject()
      %{member: owner, account: account}
    end

    test "request_magic_link audits", %{member: member, account: account} do
      request_magic_link(account, member.email)
      assert [event] = events_of(account, "user.magic_link_issued")
      assert event.actor_id == member.id
    end

    test "verify_magic_link writes NO user.signed_in — session establishment owns it", %{
      member: member,
      account: account
    } do
      {token_id, nonce, secret} = request_magic_link(account, member.email)

      assert {:ok, _membership_id} = Auth.verify_magic_link(token_id, secret, nonce)
      # Verifying a factor is not signing in — the session transaction is the
      # single writer, so a login audits exactly once and an MFA factor-one
      # alone audits nothing.
      assert events_of(account, "user.signed_in") == []
    end

    test "a wrong secret on a live token audits user.sign_in_failed for that Member", %{
      member: member,
      account: account
    } do
      {token_id, nonce, _secret} = request_magic_link(account, member.email)
      context = %RequestContext{ip_address: "198.51.100.9", user_agent: "Firefox"}

      # Wrong secret on a valid, un-consumed token → digest mismatch → the token
      # survives (attempt spent), so the failure still resolves to its owner.
      assert Auth.verify_magic_link(token_id, "wrong-secret", nonce, context) ==
               {:error, :invalid_or_expired}

      assert [event] = events_of(account, "user.sign_in_failed")
      assert event.actor_id == member.id
      assert event.ip_address == "198.51.100.9"
      assert event.payload["reason"] == "invalid_or_expired"
    end

    test "an unresolvable token writes no audit row and returns the same error (no oracle)" do
      context = %RequestContext{ip_address: "203.0.113.1"}
      before = Repo.aggregate(Emisar.Audit.Event, :count)

      # A random token id → no token → no Member → nothing to hang an audit row
      # on, and the SAME error a known-Member failure returns (no enumeration
      # oracle).
      assert Auth.verify_magic_link(Ecto.UUID.generate(), "secret", "nonce", context) ==
               {:error, :invalid_or_expired}

      assert Repo.aggregate(Emisar.Audit.Event, :count) == before
    end
  end

  describe "SSO sign-in" do
    test "records the workspace's Member and leaves a Member elsewhere untouched" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = Fixtures.SSO.create_identity_provider(%{account_id: account.id})

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: owner
        })

      sibling = Fixtures.Accounts.create_account()

      sibling_member =
        Fixtures.Memberships.create_membership(account_id: sibling.id, email: owner.email)

      context = %RequestContext{ip_address: "203.0.113.20", request_id: "req-sso-sign-in"}

      assert {:ok, _token, false} =
               Auth.complete_sso_sign_in(owner, identity, provider, browser_id(), context)

      assert [event] = events_of(account, "user.signed_in")
      assert {event.actor_kind, event.actor_id} == {"membership", owner.id}
      assert {event.target_kind, event.target_id} == {"membership", owner.id}
      assert event.target_label == Accounts.member_display_name(owner)
      assert event.payload == %{"method" => "sso"}
      assert event.request_id == "req-sso-sign-in"
      assert events_of(sibling, "user.signed_in") == []
      assert %DateTime{} = Repo.reload!(owner).last_active_at
      refute Repo.reload!(sibling_member).last_active_at
    end
  end

  describe "session self-revocation" do
    setup do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      keep = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(owner, session: keep)
      %{member: owner, account: account, keep: keep, subject: subject}
    end

    test "revoke_and_disconnect_other_sessions audits user.other_sessions_revoked with the count",
         %{
           subject: subject,
           account: account,
           keep: keep
         } do
      assert {:ok, n} = Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject)
      assert n == 2

      assert [event] = events_of(account, "user.other_sessions_revoked")
      assert event.payload["count"] == n
    end

    test "revoke_session audits user.session_revoked", %{
      subject: subject,
      account: account,
      keep: keep
    } do
      {:ok, sessions, _} = Auth.list_sessions_for_member(Crypto.hash(keep), subject)
      %{id: token_id} = Enum.find(sessions, &(not &1.current?))

      assert Auth.revoke_session(token_id, subject) == :ok
      assert [event] = events_of(account, "user.session_revoked")
      assert event.payload["session_id"] == token_id
    end
  end

  describe "Accounts membership lifecycle" do
    setup do
      {owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator"
        )

      %{
        owner: owner,
        account: account,
        owner_subject: owner_subject,
        membership: membership
      }
    end

    test "update_membership_role audits with from/to", %{
      owner_subject: owner_subject,
      account: account,
      membership: membership
    } do
      {:ok, _} = Accounts.update_membership_role(membership, "admin", owner_subject)

      assert [event] = events_of(account, "membership.role_changed")
      assert {event.actor_kind, event.actor_id} == {"membership", owner_subject.membership_id}
      assert {event.target_kind, event.target_id} == {"membership", membership.id}
      assert event.payload["from"] == "operator"
      assert event.payload["to"] == "admin"
    end

    test "delete_membership audits with the deleted role", %{
      owner_subject: owner_subject,
      account: account,
      membership: membership
    } do
      {:ok, _} = Accounts.delete_membership(membership, owner_subject)

      assert [event] = events_of(account, "membership.removed")
      assert event.target_id == membership.id
      assert event.payload["role"] == "operator"
    end

    test "update_membership_runner_access audits the explicit transition", %{
      owner_subject: owner_subject,
      account: account,
      membership: membership
    } do
      {:ok, access} = Accounts.RunnerAccess.restricted(["prod", "stage"], [])

      {:ok, _} = Accounts.update_membership_runner_access(membership, access, owner_subject)

      assert [event] = events_of(account, "membership.runner_access_changed")
      assert event.payload["before"]["mode"] == "all"
      assert event.payload["after"]["mode"] == "restricted"
      assert event.payload["after"]["groups"] == ["prod", "stage"]
    end

    test "accepting an invitation audits user.invitation_accepted with the role", %{
      owner_subject: owner_subject,
      account: account
    } do
      email = Fixtures.Random.unique_email()

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          owner_subject
        )

      {:ok, ^email, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Accepted"})

      {:ok, _changes} =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:account, fn repo, _changes ->
          Accounts.fetch_and_lock_account(account.id, repo: repo)
        end)
        |> Accounts.put_invitation_acceptance(intent, email)
        |> Repo.commit_multi()

      assert [event] = events_of(account, "user.invitation_accepted")
      assert {event.actor_kind, event.actor_id} == {"membership", invitation.id}
      assert {event.target_kind, event.target_id} == {"membership", invitation.id}
      assert event.payload["role"] == "operator"
    end
  end

  describe "Runbook lifecycle" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "create_runbook audits runbook.created with its name", %{
      account: account,
      subject: subject
    } do
      attrs = %{
        slug: "ops-#{System.unique_integer()}",
        title: "Restart ops",
        description: "Restart the ops services",
        draft_definition: Fixtures.Runbooks.default_definition()
      }

      {:ok, runbook} = Emisar.Runbooks.create_runbook(attrs, subject)

      assert [event] = events_of(account, "runbook.created")
      assert event.target_id == runbook.id
      assert event.payload["name"] == attrs.title
    end

    test "save_draft audits runbook.updated on the same row", %{
      account: account,
      subject: subject
    } do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            description: "first cut",
            draft_definition: Fixtures.Runbooks.default_definition()
          },
          subject
        )

      base_sha = Emisar.Runbooks.definition_digest(runbook.draft_definition)

      {:ok, saved} =
        Emisar.Runbooks.save_draft(runbook, %{description: "tweaked"}, base_sha, subject)

      assert [event] = events_of(account, "runbook.updated")
      assert event.target_id == saved.id
      assert event.payload["from_title"] == "Restart"
      assert event.payload["version"] == nil
    end

    test "save_draft accepts string-keyed form params", %{subject: subject} do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            draft_definition: Fixtures.Runbooks.default_definition()
          },
          subject
        )

      base_sha = Emisar.Runbooks.definition_digest(runbook.draft_definition)

      assert {:ok, saved} =
               Emisar.Runbooks.save_draft(
                 runbook,
                 %{
                   "description" => "tweaked",
                   "draft_definition" => Fixtures.Runbooks.default_definition()
                 },
                 base_sha,
                 subject
               )

      assert saved.description == "tweaked"
    end
  end

  describe "Accounts account lifecycle" do
    test "a completed sign-up records one signup and the creation; a replay records none" do
      email = Fixtures.Random.unique_email()
      context = %RequestContext{}

      attrs = %{
        "email" => email,
        "full_name" => "New Owner",
        "account_name" => "New owner account #{System.unique_integer([:positive])}"
      }

      assert {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
               Auth.request_sign_up_code(attrs, context)

      assert_received {:email, sent}
      [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      assert Auth.verify_magic_link(token_id, secret, nonce) == {:ok, nil}

      assert {:ok, %Accounts.Membership{account: account} = owner, _raw} =
               Auth.complete_sign_up(token_id, browser_id(), context)

      assert [signup] = events_of(account, "user.signed_up")
      assert {signup.actor_kind, signup.actor_id} == {"membership", owner.id}
      assert {signup.target_kind, signup.target_id} == {"membership", owner.id}

      assert [created] = events_of(account, "account.created")
      assert created.actor_id == owner.id
      assert created.payload == %{"plan" => "free", "slug" => account.slug}
      assert [_signed_in] = events_of(account, "user.signed_in")

      assert Auth.complete_sign_up(token_id, browser_id(), context) ==
               {:error, :invalid_or_expired}

      assert [_same] = events_of(account, "user.signed_up")
    end

    test "create_account_with_invited_owner records the creation and the owner's invitation, no signup" do
      slug = "tenant-#{System.unique_integer([:positive])}"
      email = Fixtures.Random.unique_email()

      assert {:ok, %{account: account, membership: owner, delivery: {:ok, :sent}}} =
               Accounts.create_account_with_invited_owner(
                 %{name: "Tenant", slug: slug},
                 email,
                 %{full_name: "Emisar Support"}
               )

      # The invitee has done nothing yet: the platform created the workspace.
      assert [created] = events_of(account, "account.created")
      assert created.payload == %{"plan" => "free", "slug" => slug}
      assert created.actor_kind == "system"
      assert created.actor_id == nil

      assert [invited] = events_of(account, "user.invited")
      assert invited.target_id == owner.id
      assert invited.payload["role"] == "owner"

      assert events_of(account, "user.signed_up") == []
    end

    test "update_account audits its changed fields with before and after values" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, updated} = Accounts.update_account(account, %{name: "Renamed"}, subject)

      assert [event] = events_of(updated, "account.updated")

      assert event.payload == %{
               "changes" => %{"name" => %{"before" => account.name, "after" => "Renamed"}}
             }
    end
  end

  # Proves the audit row commits together with its parent mutation — if
  # a constraint failure later in the multi rolls back the row, no
  # audit row is left behind (and conversely, neither rolls back without
  # the other).
  describe "transactional rollback semantics" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "a failing changeset in update_account rolls back the audit row too", %{
      account: account,
      subject: subject
    } do
      # Try to rename to a slug that's too long — Account.Changeset.update
      # rejects this, so the whole multi rolls back. The contract: the
      # account row is unchanged AND no audit row exists.
      before_count = audit_count(account, "account.updated")

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Accounts.update_account(account, %{slug: String.duplicate("x", 1000)}, subject)

      after_count = audit_count(account, "account.updated")
      assert after_count == before_count, "audit row leaked through failed update"

      # Account row untouched.
      {:ok, reloaded} = Emisar.Accounts.fetch_account_by_id(account.id)
      assert reloaded.slug == account.slug
    end

    test "a failed Multi step rolls back both the row update and the audit", %{
      account: account,
      subject: subject
    } do
      # Wedge a `Multi.run` that always fails after the policy update +
      # audit. Both should roll back together.
      {:ok, policy} = Emisar.Policies.fetch_policy(subject)
      before_count = audit_count(account, "policy.updated")

      new_rules =
        Emisar.Policies.default_rules()
        |> Map.update!("defaults", &Map.put(&1, "critical", "require_approval"))

      result =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :policy,
          Emisar.Policies.Policy.Changeset.create(%{
            account_id: policy.account_id,
            updated_by_membership_id: subject.membership_id,
            rules: new_rules
          }),
          on_conflict: Emisar.Policies.Policy.Query.rules_upsert_conflict(),
          conflict_target:
            {:unsafe_fragment, "(account_id, scope_type, scope_value) WHERE deleted_at IS NULL"},
          returning: true
        )
        |> Ecto.Multi.insert(:audit, fn %{policy: p} ->
          Audit.changeset(p.account_id, "policy.updated",
            actor_kind: "membership",
            actor_id: subject.membership_id,
            target_kind: "policy",
            target_id: p.id,
            payload: %{noop: true}
          )
        end)
        |> Ecto.Multi.run(:simulated_downstream_failure, fn _, _ ->
          {:error, :forced_rollback}
        end)
        |> Emisar.Repo.commit_multi()

      assert result == {:error, :forced_rollback}

      # Audit row should NOT exist — multi rolled back.
      assert audit_count(account, "policy.updated") == before_count

      # Policy row should NOT have the new rules — also rolled back.
      {:ok, reloaded} = Emisar.Policies.fetch_policy(subject)
      assert reloaded.rules == policy.rules
      assert reloaded.updated_by_membership_id == policy.updated_by_membership_id
    end

    defp audit_count(account, event_type) do
      account |> events_of(event_type) |> length()
    end
  end

  # Proves `Repo.commit_multi` auto-broadcasts every audit row to the
  # account-wide `:audit` topic so AuditLive (and any other subscriber)
  # can refresh without each context having to remember to broadcast.
  describe "audit fan-out broadcast" do
    setup do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "every audited mutation reaches subscribers of the account audit topic", %{
      account: account,
      subject: subject
    } do
      :ok = Emisar.Audit.subscribe_account_audit(account.id)

      {:ok, _} = Emisar.Accounts.update_account(account, %{name: "Reloaded"}, subject)

      # The audit row inserted in the same Multi as the account update
      # is broadcast verbatim — assert the event_type matches.
      assert_receive {:audit_event, %Emisar.Audit.Event{event_type: "account.updated"}}, 1_000
    end

    test "broadcast does NOT fire when the transaction rolls back", %{
      account: account,
      subject: subject
    } do
      :ok = Emisar.Audit.subscribe_account_audit(account.id)

      # A too-long slug rolls the whole multi back — no audit row commits,
      # no broadcast.
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Emisar.Accounts.update_account(
                 account,
                 %{slug: String.duplicate("x", 1000)},
                 subject
               )

      refute_receive {:audit_event, %Emisar.Audit.Event{event_type: "account.updated"}}, 100
    end
  end

  describe "Member-scoped security events" do
    test "land only in the Member's own workspace — a same-address Member elsewhere sees nothing" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      elsewhere = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: elsewhere.id,
        email: owner.email,
        role: "owner"
      )

      {_member, [code | _]} =
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

      assert {:ok, _disabled} = Auth.disable_mfa(code, subject)

      assert [row] = events_of(account, "user.mfa_disabled")
      assert row.account_id == account.id
      assert {row.actor_id, row.target_id} == {owner.id, owner.id}
      assert events_of(elsewhere, "user.mfa_disabled") == []
    end
  end
end
