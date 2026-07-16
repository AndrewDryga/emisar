defmodule Emisar.AuthAuditTest do
  @moduledoc """
  Asserts that every security-relevant operation in the Auth + Accounts
  contexts emits the expected `Audit.Event` row. Covers sign-in / out,
  MFA, magic link, account/membership lifecycle, and per-user profile
  edits.

  Each test seeds an owner and asserts the matching event_type appears
  in `Audit.list_events/1` scoped to that account.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Crypto, RequestContext, Runners, Users}
  alias Emisar.Fixtures

  defp events_of(account, event_type) do
    subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

    {:ok, events, _} =
      Audit.list_events(subject, filter: [event_type: [event_type]])

    events
  end

  describe "sign-out" do
    setup do
      {user, account, _subject} = Fixtures.Subjects.owner_subject()
      %{user: user, account: account}
    end

    test "record_sign_out audits", %{user: user, account: account} do
      assert :ok = Auth.record_sign_out(user)
      assert [event] = events_of(account, "user.signed_out")
      assert event.actor_id == user.id
    end
  end

  describe "MFA lifecycle" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      %{user: user, account: account, secret: secret, subject: subject}
    end

    test "enable_mfa audits on success", %{account: account, secret: secret, subject: subject} do
      otp = NimbleTOTP.verification_code(secret)
      assert {:ok, updated, _codes} = Auth.enable_mfa(secret, otp, subject)

      assert [event] = events_of(account, "user.mfa_enabled")
      assert event.actor_id == updated.id
    end

    test "disable_mfa audits", %{account: account, secret: secret, subject: subject} do
      {:ok, enabled, _} = Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      assert {:ok, _} = Auth.disable_mfa(NimbleTOTP.verification_code(secret), subject)
      assert [event] = events_of(account, "user.mfa_disabled")
      assert event.actor_id == enabled.id
    end

    test "verify_mfa with bad code audits user.mfa_failed", %{
      account: account,
      secret: secret,
      subject: subject
    } do
      {:ok, enabled, _} = Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      assert {:error, :invalid} = Auth.verify_mfa(enabled, "000000")

      assert [event] = events_of(account, "user.mfa_failed")
      assert event.payload["reason"] == "invalid_otp"
    end

    test "consume_mfa_recovery_code success audits with remaining count", %{
      account: account,
      secret: secret,
      subject: subject
    } do
      {:ok, enabled, codes} =
        Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      assert :ok = Auth.consume_mfa_recovery_code(enabled, hd(codes))

      assert [event] = events_of(account, "user.mfa_recovery_code_used")
      assert event.payload["remaining"] == length(codes) - 1
    end

    test "consume_mfa_recovery_code with bad code audits user.mfa_failed", %{
      account: account,
      secret: secret,
      subject: subject
    } do
      {:ok, enabled, _} = Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      assert {:error, :invalid} = Auth.consume_mfa_recovery_code(enabled, "not-a-real-code")

      assert [event] = events_of(account, "user.mfa_failed")
      assert event.payload["reason"] == "invalid_recovery_code"
    end

    test "regenerate_mfa_recovery_codes audits", %{
      account: account,
      secret: secret,
      subject: subject
    } do
      {:ok, enabled, _} = Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      {:ok, _, _codes} = Auth.regenerate_mfa_recovery_codes(subject)

      assert [event] = events_of(account, "user.mfa_recovery_codes_regenerated")
      assert event.actor_id == enabled.id
    end
  end

  describe "magic link + confirmation" do
    setup do
      {user, account, _} = Fixtures.Subjects.owner_subject()
      %{user: user, account: account}
    end

    test "issue_magic_link audits", %{user: user, account: account} do
      _ = Auth.issue_magic_link(user)
      assert [event] = events_of(account, "user.magic_link_issued")
      assert event.actor_id == user.id
    end

    test "verify_magic_link writes NO user.signed_in — session establishment owns it", %{
      user: user,
      account: account
    } do
      {token_id, nonce, secret} = Auth.issue_magic_link(user)

      assert {:ok, _u} = Auth.verify_magic_link(token_id, secret, nonce)
      # Verifying a factor is not signing in — Users.record_sign_in (the
      # session layer) is the single writer, so a login audits exactly once
      # and an MFA factor-one alone audits nothing.
      assert events_of(account, "user.signed_in") == []
    end

    test "a wrong secret on a live token audits user.sign_in_failed for that user", %{
      user: user,
      account: account
    } do
      {token_id, nonce, _secret} = Auth.issue_magic_link(user)
      context = %RequestContext{ip_address: "198.51.100.9", user_agent: "Firefox"}

      # Wrong secret on a valid, un-consumed token → digest mismatch → the token
      # survives (attempt spent), so the failure still resolves to its owner.
      assert {:error, :invalid_or_expired} =
               Auth.verify_magic_link(token_id, "wrong-secret", nonce, context)

      assert [event] = events_of(account, "user.sign_in_failed")
      assert event.actor_id == user.id
      assert event.ip_address == "198.51.100.9"
      assert event.payload["reason"] == "invalid_or_expired"
    end

    test "an unresolvable token writes no audit row and returns the same error (no oracle)" do
      context = %RequestContext{ip_address: "203.0.113.1"}
      before = Repo.aggregate(Emisar.Audit.Event, :count)

      # A random token id → no token → no user → nothing to hang an audit row on,
      # and the SAME error a known-user failure returns (no enumeration oracle).
      assert Auth.verify_magic_link(Ecto.UUID.generate(), "secret", "nonce", context) ==
               {:error, :invalid_or_expired}

      assert Repo.aggregate(Emisar.Audit.Event, :count) == before
    end

    test "confirm_user_by_token audits user.email_confirmed", %{account: account} do
      # Unconfirmed user — bypass Fixtures.Subjects.owner_subject which auto-confirms.
      unconfirmed = Fixtures.Users.create_user(confirmed?: false)

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: unconfirmed.id,
          role: "operator"
        )

      raw = Auth.issue_confirmation_token!(unconfirmed)
      assert {:ok, _} = Auth.confirm_user_by_token(raw)

      assert [event] = events_of(account, "user.email_confirmed")
      assert event.actor_id == unconfirmed.id
    end
  end

  describe "session self-revocation" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      # Mint two sessions for the user.
      _ = Auth.create_session_token!(user, :magic_link, false)
      keep = Auth.create_session_token!(user, :magic_link, false)
      %{user: user, account: account, keep: keep, subject: subject}
    end

    test "revoke_other_sessions! audits user.other_sessions_revoked with the count", %{
      user: user,
      account: account,
      keep: keep
    } do
      assert n = Auth.revoke_other_sessions!(user, keep)
      assert n >= 1

      assert [event] = events_of(account, "user.other_sessions_revoked")
      assert event.payload["count"] == n
    end

    test "revoke_session audits user.session_revoked", %{
      subject: subject,
      account: account,
      keep: _keep
    } do
      {:ok, [%{id: token_id} | _], _} = Auth.list_sessions_for_user(subject)

      assert :ok = Auth.revoke_session(token_id, subject)
      assert [event] = events_of(account, "user.session_revoked")
      assert event.payload["session_id"] == token_id
    end
  end

  describe "Accounts profile / email" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, account: account, subject: subject}
    end

    test "update_user_profile audits user.profile_updated", %{
      account: account,
      subject: subject
    } do
      {:ok, _} = Users.update_user_profile(%{full_name: "New Name"}, subject)

      assert [event] = events_of(account, "user.profile_updated")
      assert event.payload["full_name"] == "New Name"
    end

    test "update_user_email success audits with from/to addresses", %{
      user: user,
      account: account,
      subject: subject
    } do
      new = "renamed-#{System.unique_integer()}@example.test"

      {:ok, _} = Users.update_user_email(new, subject)

      assert [event] = events_of(account, "user.email_changed")
      assert event.payload["from"] == user.email
      assert event.payload["to"] == new
    end
  end

  describe "Accounts membership lifecycle" do
    setup do
      {owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      %{
        owner: owner,
        account: account,
        owner_subject: owner_subject,
        member: member,
        membership: membership
      }
    end

    test "update_membership_role audits with from/to", %{
      owner: owner,
      owner_subject: owner_subject,
      account: account,
      member: member,
      membership: membership
    } do
      {:ok, _} = Accounts.update_membership_role(membership, "admin", owner_subject)

      assert [event] = events_of(account, "membership.role_changed")
      assert event.actor_id == owner.id
      assert event.target_id == member.id
      assert event.payload["from"] == "operator"
      assert event.payload["to"] == "admin"
    end

    test "delete_membership audits with the deleted role", %{
      owner_subject: owner_subject,
      account: account,
      member: member,
      membership: membership
    } do
      {:ok, _} = Accounts.delete_membership(membership, owner_subject)

      assert [event] = events_of(account, "membership.removed")
      assert event.target_id == member.id
      assert event.payload["role"] == "operator"
    end

    test "replace_runner_scopes audits with scope payload", %{
      owner_subject: owner_subject,
      account: account,
      membership: membership
    } do
      {:ok, _} =
        Runners.replace_runner_scopes(
          membership,
          [{"group", "prod"}, {"group", "stage"}],
          owner_subject
        )

      assert [event] = events_of(account, "membership.runner_scopes_changed")
      assert event.payload["scope_count"] == 2
    end

    test "mark_invitation_accepted (self-accept of existing user) audits", %{
      account: account,
      member: member,
      membership: membership
    } do
      # Stamp the membership as pending an invitation, then accept it.
      {:ok, with_token} =
        membership
        |> Ecto.Changeset.change(invitation_token_digest: "tok-#{System.unique_integer()}")
        |> Emisar.Repo.update()

      {:ok, _} = Accounts.mark_invitation_accepted(with_token, member)

      assert [event] = events_of(account, "membership.invitation_accepted")
      assert event.payload["role"] == "operator"
    end
  end

  describe "Runbook lifecycle" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "create_runbook audits runbook.created with name + version", %{
      account: account,
      subject: subject
    } do
      attrs = %{
        name: "ops-#{System.unique_integer()}",
        slug: "ops-#{System.unique_integer()}",
        title: "Restart ops",
        description: "Restart the ops services",
        definition: %{"steps" => []}
      }

      {:ok, runbook} = Emisar.Runbooks.create_runbook(attrs, subject)

      assert [event] = events_of(account, "runbook.created")
      assert event.target_id == runbook.id
      assert event.payload["name"] == attrs.name
      assert event.payload["version"] == 1
    end

    test "save_new_version audits runbook.updated with version bump", %{
      account: account,
      subject: subject
    } do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            name: "ops-#{System.unique_integer()}",
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            description: "first cut",
            definition: %{"steps" => []}
          },
          subject
        )

      {:ok, v2} =
        Emisar.Runbooks.save_new_version(runbook, %{description: "tweaked"}, subject)

      assert [event] = events_of(account, "runbook.updated")
      assert event.target_id == v2.id
      assert event.payload["from_version"] == 1
      assert event.payload["to_version"] == 2
    end

    test "save_new_version accepts string-keyed form params", %{subject: subject} do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            name: "ops-#{System.unique_integer()}",
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            definition: %{"steps" => []}
          },
          subject
        )

      # String keys from the editor form must not collide with the
      # programmatic version bump (this combination crashed cast on mixed keys).
      assert {:ok, v2} =
               Emisar.Runbooks.save_new_version(
                 runbook,
                 %{"description" => "tweaked", "definition" => %{"steps" => []}},
                 subject
               )

      assert v2.version == 2
    end

    test "publish audits runbook.published", %{account: account, subject: subject} do
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            name: "ops-#{System.unique_integer()}",
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            description: "go",
            definition: %{
              "steps" => [
                %{
                  "id" => "s1",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"group" => ["default"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, published} = Emisar.Runbooks.publish(runbook, subject)

      assert [event] = events_of(account, "runbook.published")
      assert event.target_id == published.id
      assert event.payload["version"] == published.version
    end
  end

  describe "Accounts account lifecycle" do
    test "create_account_with_owner audits account.created and user.signed_up" do
      user = Fixtures.Users.create_user()
      slug = "tenant-#{System.unique_integer()}"

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Tenant", slug: slug, plan: "free"},
          user
        )

      assert [created] = events_of(account, "account.created")
      assert created.payload["plan"] == "free"
      assert created.payload["slug"] == slug

      assert [signup] = events_of(account, "user.signed_up")
      assert signup.actor_id == user.id
    end

    test "update_account audits account.updated with snapshot" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, updated} = Accounts.update_account(account, %{name: "Renamed"}, subject)

      assert [event] = events_of(updated, "account.updated")
      assert event.payload["name"] == "Renamed"
    end
  end

  # Proves the audit row commits together with its parent mutation — if
  # a constraint failure later in the multi rolls back the row, no
  # audit row is left behind (and conversely, neither rolls back without
  # the other).
  describe "transactional rollback semantics" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
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
        |> Ecto.Multi.update(
          :policy,
          Emisar.Policies.Policy.Changeset.update(
            policy,
            %{rules: new_rules, updated_by_id: subject.actor.id}
          )
        )
        |> Ecto.Multi.insert(:audit, fn %{policy: p} ->
          Audit.changeset(p.account_id, "policy.updated",
            actor_kind: "user",
            actor_id: subject.actor.id,
            target_kind: "policy",
            target_id: p.id,
            payload: %{noop: true}
          )
        end)
        |> Ecto.Multi.run(:simulated_downstream_failure, fn _, _ ->
          {:error, :forced_rollback}
        end)
        |> Emisar.Repo.commit_multi()

      assert {:error, :forced_rollback} = result

      # Audit row should NOT exist — multi rolled back.
      assert audit_count(account, "policy.updated") == before_count

      # Policy row should NOT have the new rules — also rolled back.
      {:ok, reloaded} = Emisar.Policies.fetch_policy(subject)
      assert reloaded.rules == policy.rules
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
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
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

  describe "identity-event fan-out across memberships" do
    test "a user-scoped event lands one row in EACH of the user's active accounts" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_a.id,
          user_id: user.id,
          role: "owner"
        )

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: user.id,
          role: "admin"
        )

      # The fetch_and_update :audit path (the hardest — its callback returns the
      # per-membership list, inserted atomically in the mutation's transaction).
      {:ok, _} =
        Users.update_user_mfa(user.id, "JBSWY3DPEHPK3PXP", DateTime.utc_now(), [Crypto.hash("x")],
          audit: &Audit.user_changesets(&1, "user.mfa_enabled")
        )

      {:ok, _} =
        Users.update_user_mfa(user.id, nil, nil, [],
          audit: &Audit.user_changesets(&1, "user.mfa_disabled")
        )

      # One row in each account…
      assert [row_a] = events_of(account_a, "user.mfa_disabled")
      assert [row_b] = events_of(account_b, "user.mfa_disabled")
      # …and each account sees ONLY its own copy (cross-account isolation).
      assert row_a.account_id == account_a.id
      assert row_b.account_id == account_b.id
      assert row_a.actor_id == user.id
    end

    test "a single-account user still gets exactly one row (no duplicates)" do
      {user, account, _} = Fixtures.Subjects.owner_subject()

      assert :ok = Audit.log_for_user(user, "user.mfa_failed")
      assert [_only] = events_of(account, "user.mfa_failed")
    end

    test "a user with no active membership produces no row (unchanged drop)" do
      user = Fixtures.Users.create_user()
      before = Repo.aggregate(Emisar.Audit.Event, :count)

      assert :ok = Audit.log_for_user(user, "user.mfa_failed")
      assert Repo.aggregate(Emisar.Audit.Event, :count) == before
    end
  end
end
