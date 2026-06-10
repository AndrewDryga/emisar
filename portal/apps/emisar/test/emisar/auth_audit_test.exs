defmodule Emisar.AuthAuditTest do
  @moduledoc """
  Asserts that every security-relevant operation in the Auth + Accounts
  contexts emits the expected `Audit.Event` row. Covers sign-in / out,
  password reset, MFA, magic link, account/membership lifecycle, and
  per-user profile edits.

  Each test seeds an owner and asserts the matching event_type appears
  in `Audit.list_events/1` scoped to that account.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, Audit, Auth, Runners, Users}

  defp events_of(account, event_type) do
    subject = subject_for(user_fixture(), account, role: :owner)

    {:ok, events, _} =
      Audit.list_events(subject, filter: [event_type: [event_type]])

    events
  end

  describe "sign-in / sign-out / failed sign-in" do
    setup do
      {user, account, _subject} = owner_subject_fixture()
      %{user: user, account: account}
    end

    test "record_failed_sign_in audits when email is known", %{user: user, account: account} do
      assert :ok = Auth.record_failed_sign_in(user.email, "bad_credentials")

      assert [event] = events_of(account, "user.sign_in_failed")
      assert event.actor_id == user.id
      assert event.payload["reason"] == "bad_credentials"
    end

    test "record_failed_sign_in silently drops unknown emails (anti-enumeration)" do
      assert :ok =
               Auth.record_failed_sign_in("ghost-#{System.unique_integer()}@nowhere.test", "x")

      # Nothing to assert against — the absence of a crash + the audit-log
      # silence is the contract. If it leaked into ANY account we'd have a
      # security bug; harder to prove a negative cheaply here.
    end

    test "record_sign_out audits", %{user: user, account: account} do
      assert :ok = Auth.record_sign_out(user)
      assert [event] = events_of(account, "user.signed_out")
      assert event.actor_id == user.id
    end
  end

  describe "MFA lifecycle" do
    setup do
      {user, account, subject} = owner_subject_fixture()
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

      assert {:ok, _} = Auth.disable_mfa(subject)
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

  describe "magic link + password reset + confirmation" do
    setup do
      {user, account, _} = owner_subject_fixture()
      %{user: user, account: account}
    end

    test "issue_magic_link_token! audits", %{user: user, account: account} do
      _raw = Auth.issue_magic_link_token!(user)
      assert [event] = events_of(account, "user.magic_link_issued")
      assert event.actor_id == user.id
    end

    test "consume_magic_link_token audits user.signed_in with magic_link method", %{
      user: user,
      account: account
    } do
      raw = Auth.issue_magic_link_token!(user)

      assert {:ok, _u} = Auth.consume_magic_link_token(raw)
      assert [event] = events_of(account, "user.signed_in")
      assert event.payload["method"] == "magic_link"
    end

    test "issue_password_reset_token! audits", %{user: user, account: account} do
      _raw = Auth.issue_password_reset_token!(user)
      assert [event] = events_of(account, "user.password_reset_requested")
      assert event.actor_id == user.id
    end

    test "reset_user_password audits user.password_reset_completed", %{
      user: user,
      account: account
    } do
      raw = Auth.issue_password_reset_token!(user)

      assert {:ok, _} = Auth.reset_user_password(raw, "fresh-12-chars-now")
      assert [event] = events_of(account, "user.password_reset_completed")
      assert event.actor_id == user.id
    end

    test "confirm_user_by_token audits user.email_confirmed", %{account: account} do
      # Unconfirmed user — bypass owner_subject_fixture which auto-confirms.
      unconfirmed = user_fixture(confirmed?: false)

      _ = membership_fixture(account_id: account.id, user_id: unconfirmed.id, role: "operator")

      raw = Auth.issue_confirmation_token!(unconfirmed)
      assert {:ok, _} = Auth.confirm_user_by_token(raw)

      assert [event] = events_of(account, "user.email_confirmed")
      assert event.actor_id == unconfirmed.id
    end
  end

  describe "session self-revocation" do
    setup do
      {user, account, subject} = owner_subject_fixture()
      # Mint two sessions for the user.
      _ = Auth.create_session_token!(user)
      keep = Auth.create_session_token!(user)
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

  describe "Accounts profile / email / password" do
    setup do
      {user, account, subject} = owner_subject_fixture()
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

      {:ok, _} = Users.update_user_email(new, "password-with-12-chars", subject)

      assert [event] = events_of(account, "user.email_changed")
      assert event.payload["from"] == user.email
      assert event.payload["to"] == new
    end

    test "update_user_email with wrong current password audits user.email_change_failed", %{
      account: account,
      subject: subject
    } do
      assert {:error, :invalid_current_password} =
               Users.update_user_email("new@example.test", "wrong", subject)

      assert [event] = events_of(account, "user.email_change_failed")
      assert event.payload["reason"] == "invalid_current_password"
    end

    test "change_user_password success audits user.password_changed", %{
      user: user,
      account: account,
      subject: subject
    } do
      {:ok, _} =
        Users.change_user_password("password-with-12-chars", "new-password-12c", subject)

      assert [event] = events_of(account, "user.password_changed")
      assert event.actor_id == user.id
    end

    test "change_user_password with wrong current audits user.password_change_failed", %{
      account: account,
      subject: subject
    } do
      assert {:error, :invalid_current_password} =
               Users.change_user_password("wrong-password", "new-pw-12-char", subject)

      assert [event] = events_of(account, "user.password_change_failed")
      assert event.payload["reason"] == "invalid_current_password"
    end

    test "change_user_password rejects passwords below the length minimum", %{
      subject: subject
    } do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Users.change_user_password("password-with-12-chars", "short", subject)

      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end
  end

  describe "Accounts membership lifecycle" do
    setup do
      {owner, account, owner_subject} = owner_subject_fixture()
      member = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: member.id, role: "operator")

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
      assert event.subject_id == member.id
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
      assert event.subject_id == member.id
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
        |> Ecto.Changeset.change(invitation_token: "tok-#{System.unique_integer()}")
        |> Emisar.Repo.update()

      {:ok, _} = Accounts.mark_invitation_accepted(with_token, member)

      assert [event] = events_of(account, "membership.invitation_accepted")
      assert event.payload["role"] == "operator"
    end
  end

  describe "Runbook lifecycle" do
    test "create_runbook audits runbook.created with name + version" do
      {_user, account, subject} = owner_subject_fixture()

      attrs = %{
        name: "ops-#{System.unique_integer()}",
        slug: "ops-#{System.unique_integer()}",
        title: "Restart ops",
        description: "Restart the ops services",
        definition: %{"steps" => []}
      }

      {:ok, rb} = Emisar.Runbooks.create_runbook(attrs, subject)

      assert [event] = events_of(account, "runbook.created")
      assert event.subject_id == rb.id
      assert event.payload["name"] == attrs.name
      assert event.payload["version"] == 1
    end

    test "save_new_version audits runbook.updated with version bump" do
      {_user, account, subject} = owner_subject_fixture()

      {:ok, rb} =
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
        Emisar.Runbooks.save_new_version(rb, %{description: "tweaked"}, subject)

      assert [event] = events_of(account, "runbook.updated")
      assert event.subject_id == v2.id
      assert event.payload["from_version"] == 1
      assert event.payload["to_version"] == 2
    end

    test "save_new_version accepts string-keyed form params" do
      {_user, _account, subject} = owner_subject_fixture()

      {:ok, rb} =
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
                 rb,
                 %{"description" => "tweaked", "definition" => %{"steps" => []}},
                 subject
               )

      assert v2.version == 2
    end

    test "publish audits runbook.published" do
      {_user, account, subject} = owner_subject_fixture()

      {:ok, rb} =
        Emisar.Runbooks.create_runbook(
          %{
            name: "ops-#{System.unique_integer()}",
            slug: "ops-#{System.unique_integer()}",
            title: "Restart",
            description: "go",
            definition: %{"steps" => []}
          },
          subject
        )

      {:ok, published} = Emisar.Runbooks.publish(rb, subject)

      assert [event] = events_of(account, "runbook.published")
      assert event.subject_id == published.id
      assert event.payload["version"] == published.version
    end
  end

  describe "Accounts account lifecycle" do
    test "create_account_with_owner audits account.created and user.signed_up" do
      user = user_fixture()
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
      {_user, account, subject} = owner_subject_fixture()

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
    test "a failing changeset in update_account rolls back the audit row too" do
      {_user, account, subject} = owner_subject_fixture()

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

    test "a failed Multi step rolls back both the row update and the audit" do
      {_user, account, subject} = owner_subject_fixture()

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
            subject_kind: "policy",
            subject_id: p.id,
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

  # Admin-driven helpers must attribute the actor to the ADMIN, not the
  # target — and must not leak through to self-service primitives that
  # would re-record the action with the target as actor. The exact bug
  # this guards against: prior to the fix,
  # `Accounts.force_password_reset/2` called
  # `Auth.issue_password_reset_token!/1` whose inline
  # `user.password_reset_requested` audit attributed the request to the
  # target user (sam@…) rather than the admin who clicked the button.
  describe "admin-path attribution" do
    setup do
      {admin, account, admin_subject} = owner_subject_fixture()
      target = user_fixture()

      target_membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      %{
        admin: admin,
        admin_subject: admin_subject,
        account: account,
        target: target,
        target_membership: target_membership
      }
    end

    test "force_password_reset audits exactly ONE event, with admin as actor and target as subject",
         %{
           admin: admin,
           admin_subject: admin_subject,
           account: account,
           target: target,
           target_membership: m
         } do
      :ok = Accounts.force_password_reset(m, admin_subject)

      forced = events_of(account, "user.password_reset_forced")
      assert [forced_ev] = forced
      assert forced_ev.actor_id == admin.id, "actor should be the admin"
      assert forced_ev.subject_id == target.id, "subject should be the target"
      assert forced_ev.subject_label == target.email

      # The misattributed event must NOT leak through — the inline
      # `issue_password_reset_token!` call inside the admin path used to
      # emit it with target=actor=target, which is the exact bug.
      assert [] = events_of(account, "user.password_reset_requested")
    end

    test "self-service Auth.issue_password_reset_token!/1 still audits (forgot-password flow)",
         %{target: target, account: account} do
      # Default behavior — caller is the user requesting their own reset.
      _ = Auth.issue_password_reset_token!(target)

      assert [ev] = events_of(account, "user.password_reset_requested")
      assert ev.actor_id == target.id
      assert ev.subject_id == target.id
    end

    test "the :audit false override suppresses the inline event without affecting token issuance",
         %{target: target, account: account} do
      raw = Auth.issue_password_reset_token!(target, audit: false)

      # Token still works — the token row was inserted, only the audit
      # was suppressed.
      assert is_binary(raw) and byte_size(raw) > 0
      assert [] = events_of(account, "user.password_reset_requested")
    end
  end

  # Proves `Repo.commit_multi` auto-broadcasts every audit row to the
  # account-wide `:audit` topic so AuditLive (and any other subscriber)
  # can refresh without each context having to remember to broadcast.
  describe "audit fan-out broadcast" do
    test "every audited mutation reaches subscribers of the account audit topic" do
      {_user, account, subject} = owner_subject_fixture()

      :ok = Emisar.Audit.subscribe_account_audit(account.id)

      {:ok, _} = Emisar.Accounts.update_account(account, %{name: "Reloaded"}, subject)

      # The audit row inserted in the same Multi as the account update
      # is broadcast verbatim — assert the event_type matches.
      assert_receive {:audit_event, %Emisar.Audit.Event{event_type: "account.updated"}}, 1_000
    end

    test "broadcast does NOT fire when the transaction rolls back" do
      {_user, account, subject} = owner_subject_fixture()

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
end
