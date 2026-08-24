defmodule Emisar.AccountsTest do
  use Emisar.DataCase, async: true
  alias Ecto.Multi
  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership, RunnerAccess}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Audit
  alias Emisar.Audit.Event, as: AuditEvent
  alias Emisar.Auth
  alias Emisar.Crypto
  alias Emisar.Fixtures
  alias Emisar.Mail
  alias Emisar.Policies.Policy
  alias Emisar.RequestContext
  alias Emisar.Runbooks.Runbook
  alias Emisar.Runs.ActionRun
  alias Emisar.Users
  alias Emisar.Users.User

  defp filtered_membership_ids(account, subject, filter) do
    {:ok, facts, _metadata} =
      Accounts.list_team_member_facts(account, subject, filter: filter)

    facts
    |> Enum.map(& &1.membership.id)
    |> MapSet.new()
  end

  describe "fetch_account_by_id/1" do
    test "resolves a live account by its id" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{id: id}} = Accounts.fetch_account_by_id(account.id)
      assert id == account.id
    end

    test "unused UUID returns :not_found" do
      assert Accounts.fetch_account_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "a soft-deleted account returns :not_found" do
      # The read starts at `not_deleted`, so a tombstoned account is
      # indistinguishable from one that never existed — both :not_found.
      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.mark_account_as_deleted()

      assert Accounts.fetch_account_by_id(account.id) == {:error, :not_found}
    end

    test "a non-UUID id returns :not_found" do
      assert Accounts.fetch_account_by_id("not-a-uuid") == {:error, :not_found}
    end
  end

  describe "delete_by_id/1" do
    test "hard-deletes a tombstoned account and its owned records" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      runbook = Fixtures.Runbooks.create_runbook(account_id: account.id, created_by_id: owner.id)
      action_run = Fixtures.Runs.create_run(account_id: account.id)
      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      account = Fixtures.Accounts.mark_account_as_deleted(account)
      account_id = account.id

      assert {:ok, %Account{id: ^account_id}} = Accounts.delete_by_id(account_id)

      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_id)) == nil

      assert Repo.one(Membership.Query.all() |> Membership.Query.by_account_id(account_id)) == nil

      assert Repo.one(Policy.Query.all() |> Policy.Query.by_account_id(account_id)) == nil
      assert Repo.one(Runbook.Query.all() |> Runbook.Query.by_id(runbook.id)) == nil
      assert Repo.one(ActionRun.Query.all() |> ActionRun.Query.by_id(action_run.id)) == nil
      assert Repo.one(ApiKey.Query.all() |> ApiKey.Query.by_id(api_key.id)) == nil
      assert Repo.one(AuditEvent.Query.all() |> AuditEvent.Query.by_account_id(account_id)) == nil
    end

    test "returns not_found for malformed or unknown ids" do
      assert Accounts.delete_by_id("not-a-uuid") == {:error, :not_found}
      assert Accounts.delete_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "erase_user_and_owned_accounts/1" do
    test "deletes an account when the user is its sole live owner" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      user_id = user.id
      account_id = account.id

      assert {:ok, %User{id: ^user_id}} = Accounts.erase_user_and_owned_accounts(user_id)

      assert Repo.one(User.Query.all() |> User.Query.by_id(user_id)) == nil
      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_id)) == nil

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_id, user_id)
             ) == nil
    end

    test "keeps an account when another live owner exists and removes this membership" do
      user = Fixtures.Users.create_user()
      other_owner = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: other_owner.id,
        role: "owner"
      )

      user_id = user.id
      account_id = account.id

      assert {:ok, %User{id: ^user_id}} = Accounts.erase_user_and_owned_accounts(user_id)

      assert Repo.one(User.Query.all() |> User.Query.by_id(user_id)) == nil
      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_id)).id == account_id

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_id, user_id)
             ) == nil

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_id, other_owner.id)
             ).user_id == other_owner.id
    end

    test "keeps an account when the user is a non-owner member and removes this membership" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "operator"
      )

      user_id = user.id
      account_id = account.id

      assert {:ok, %User{id: ^user_id}} = Accounts.erase_user_and_owned_accounts(user_id)

      assert Repo.one(User.Query.all() |> User.Query.by_id(user_id)) == nil
      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_id)).id == account_id

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_id, user_id)
             ) == nil
    end

    test "deletes the sole-owner account and keeps the co-owned account" do
      user = Fixtures.Users.create_user()
      other_owner = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account_a.id,
        user_id: user.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        user_id: user.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        user_id: other_owner.id,
        role: "owner"
      )

      user_id = user.id
      account_a_id = account_a.id
      account_b_id = account_b.id

      assert {:ok, %User{id: ^user_id}} = Accounts.erase_user_and_owned_accounts(user_id)

      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_a_id)) == nil
      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_b_id)).id == account_b_id

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_b_id, user_id)
             ) == nil

      assert Repo.one(
               Membership.Query.all()
               |> Membership.Query.by_account_and_user(account_b_id, other_owner.id)
             ).user_id == other_owner.id
    end

    test "counts only non-deleted owner memberships" do
      user = Fixtures.Users.create_user()
      former_owner = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      former_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: former_owner.id,
          role: "owner"
        )

      Fixtures.Memberships.mark_membership_as_deleted(former_membership)
      user_id = user.id
      account_id = account.id

      assert {:ok, %User{id: ^user_id}} = Accounts.erase_user_and_owned_accounts(user_id)
      assert Repo.one(Account.Query.all() |> Account.Query.by_id(account_id)) == nil
    end

    test "returns not_found for malformed or unknown ids" do
      assert Accounts.erase_user_and_owned_accounts("not-a-uuid") == {:error, :not_found}
      assert Accounts.erase_user_and_owned_accounts(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "fetch_and_lock_account/2" do
    test "returns the account when called standalone" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{id: id}} = Accounts.fetch_and_lock_account(account.id)
      assert id == account.id
    end

    test "a soft-deleted account returns :not_found" do
      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.mark_account_as_deleted()

      assert Accounts.fetch_and_lock_account(account.id) == {:error, :not_found}
    end

    test "an unknown or malformed uuid returns :not_found" do
      assert Accounts.fetch_and_lock_account(Ecto.UUID.generate()) == {:error, :not_found}
      assert Accounts.fetch_and_lock_account("not-a-uuid") == {:error, :not_found}
    end

    test "accepts :repo as an option" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{locked: %Account{id: id}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 Accounts.fetch_and_lock_account(account.id, repo: repo)
               end)
               |> Repo.transaction()

      assert id == account.id
    end
  end

  describe "fetch_and_lock_membership/3" do
    test "returns an active membership in its account" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, %Membership{id: id}} =
               Accounts.fetch_and_lock_membership(account.id, membership.id)

      assert id == membership.id
    end

    test "returns :not_found for a suspended or removed membership" do
      account = Fixtures.Accounts.create_account()
      suspended = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.suspend_membership(suspended)

      assert Accounts.fetch_and_lock_membership(account.id, suspended.id) == {:error, :not_found}

      removed = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.mark_membership_as_deleted(removed)

      assert Accounts.fetch_and_lock_membership(account.id, removed.id) == {:error, :not_found}
    end

    test "does not return a membership from another account" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: other_account.id)

      assert Accounts.fetch_and_lock_membership(account.id, membership.id) == {:error, :not_found}
    end

    test "accepts :repo as an option inside a transaction" do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, %{locked: %Membership{id: id}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 Accounts.fetch_and_lock_membership(account.id, membership.id, repo: repo)
               end)
               |> Repo.transaction()

      assert id == membership.id
    end
  end

  describe "fetch_account_settings/1" do
    test "returns the account's embedded settings value" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.set_max_grant_lifetime_seconds(account, 3_600)

      assert {:ok, account_settings} = Accounts.fetch_account_settings(account.id)
      assert %Account.Settings{max_grant_lifetime_seconds: 3_600} = account_settings
    end

    test "a soft-deleted account is :not_found" do
      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.mark_account_as_deleted()

      assert Accounts.fetch_account_settings(account.id) == {:error, :not_found}
    end

    test "an unknown or malformed id is :not_found" do
      assert Accounts.fetch_account_settings(Ecto.UUID.generate()) == {:error, :not_found}
      assert Accounts.fetch_account_settings("not-a-uuid") == {:error, :not_found}
    end
  end

  describe "ensure_account_compliant/2" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      %{user: user, account: account, subject: subject}
    end

    test "an account mandating neither control is compliant", %{
      account: account,
      subject: subject
    } do
      assert Accounts.ensure_account_compliant(account, subject) == :ok
    end

    test "require_sso rejects a session that did not authenticate through it", %{
      account: account,
      subject: subject
    } do
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      assert Accounts.ensure_account_compliant(account, subject) == {:error, :sso_required}
    end

    test "require_sso fails open while the account has no enabled provider left", %{
      account: account,
      subject: subject
    } do
      # An out-of-band provider removal must leave the account recoverable, not
      # bricked behind a step-up nobody can complete.
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      assert Accounts.ensure_account_compliant(account, subject) == :ok
    end

    test "require_sso is not satisfied by another account's identity provider", %{
      user: user,
      account: account,
      subject: subject
    } do
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

      other_account = Fixtures.Accounts.create_account()
      other_provider = Fixtures.SSO.create_identity_provider(account_id: other_account.id)

      foreign_identity =
        Fixtures.SSO.create_user_identity(
          account_id: other_account.id,
          provider_id: other_provider.id,
          user_id: user.id
        )

      foreign_sso_subject = %{
        subject
        | auth_method: :sso,
          user_identity_id: foreign_identity.id
      }

      assert Accounts.ensure_account_compliant(account, foreign_sso_subject) ==
               {:error, :sso_required}
    end

    test "require_mfa rejects an operator who has not enrolled", %{
      account: account,
      subject: subject
    } do
      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      assert Accounts.ensure_account_compliant(account, subject) == {:error, :mfa_required}
    end

    test "enrollment alone is insufficient; this session must prove the current enrollment", %{
      account: account,
      subject: subject
    } do
      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})
      {user, _recovery_codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      enrolled_only = %{subject | actor: user, mfa: false}

      assert Accounts.ensure_account_compliant(account, enrolled_only) ==
               {:error, :mfa_required}

      proved = %{
        enrolled_only
        | mfa: true,
          mfa_enrollment_verified_at: user.mfa_enabled_at
      }

      assert Accounts.ensure_account_compliant(account, proved) == :ok
    end

    test "a session replayed across disable and re-enroll cannot reuse the old proof epoch",
         %{account: account, subject: subject} do
      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      {enrolled, [recovery_code | _]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      proved_subject = %{
        subject
        | actor: enrolled,
          mfa: true,
          mfa_enrollment_verified_at: enrolled.mfa_enabled_at
      }

      assert Accounts.ensure_account_compliant(account, proved_subject) == :ok

      {:ok, disabled} = Auth.disable_mfa(recovery_code, proved_subject)
      disabled_subject = %{proved_subject | actor: disabled, mfa: false}

      assert Accounts.ensure_account_compliant(account, disabled_subject) ==
               {:error, :mfa_required}

      {re_enrolled, _codes} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), disabled_subject)

      replayed_subject = %{disabled_subject | actor: re_enrolled, mfa: true}

      assert Accounts.ensure_account_compliant(account, replayed_subject) ==
               {:error, :mfa_required}
    end

    test "this account's MFA-satisfying SSO identity clears both controls", %{
      user: user,
      account: account,
      subject: subject
    } do
      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      account =
        Fixtures.Accounts.set_account_settings(account, %{require_sso: true, require_mfa: true})

      sso_subject = %{subject | auth_method: :sso, user_identity_id: identity.id}

      assert Accounts.ensure_account_compliant(account, sso_subject) == :ok
    end

    test "generic SSO MFA never substitutes for current account-scoped provider trust", %{
      user: user,
      account: account,
      subject: subject
    } do
      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
        )

      account = Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      sso_subject = %{
        subject
        | auth_method: :sso,
          mfa: true,
          user_identity_id: identity.id
      }

      assert Accounts.ensure_account_compliant(account, sso_subject) ==
               {:error, :mfa_required}
    end

    test "a subject without account-view permission is unauthorized", %{
      user: user,
      account: account
    } do
      subject = Fixtures.Subjects.build_subject(user: user, account: account)

      assert Accounts.ensure_account_compliant(account, subject) == {:error, :unauthorized}
    end

    test "an account the subject doesn't belong to is :not_found", %{subject: subject} do
      other_account = Fixtures.Accounts.create_account()

      assert Accounts.ensure_account_compliant(other_account, subject) == {:error, :not_found}
    end
  end

  describe "fetch_account_by_id_or_slug/1" do
    test "resolves a live account by slug or id" do
      account = Fixtures.Accounts.create_account()
      account_id = account.id

      assert {:ok, %Account{id: ^account_id}} = Accounts.fetch_account_by_id_or_slug(account.slug)
      assert {:ok, %Account{id: ^account_id}} = Accounts.fetch_account_by_id_or_slug(account.id)
    end

    test "a soft-deleted account is :not_found" do
      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.mark_account_as_deleted()

      assert Accounts.fetch_account_by_id_or_slug(account.slug) == {:error, :not_found}
      assert Accounts.fetch_account_by_id_or_slug(account.id) == {:error, :not_found}
    end

    test "an unknown ref is :not_found" do
      assert Accounts.fetch_account_by_id_or_slug("no-such-team") == {:error, :not_found}
      assert Accounts.fetch_account_by_id_or_slug(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "fetch_account_by_id_or_slug_including_disabled/1" do
    test "includes a disabled account by id and slug" do
      {_actor, _management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      assert {:ok, disabled} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Customer requested a temporary hold",
                 subject
               )

      assert Accounts.fetch_account_by_id(account.id) == {:error, :not_found}

      assert {:ok, %Account{id: id}} =
               Accounts.fetch_account_by_id_or_slug_including_disabled(account.id)

      assert id == disabled.id

      assert {:ok, %Account{id: ^id}} =
               Accounts.fetch_account_by_id_or_slug_including_disabled(account.slug)
    end

    test "does not include a soft-deleted account" do
      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.mark_account_as_deleted()

      assert Accounts.fetch_account_by_id_or_slug_including_disabled(account.id) ==
               {:error, :not_found}
    end
  end

  describe "close_account/3" do
    test "cancels the subscription, tombstones the account, and audits it" do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_closing"
      )

      assert {:ok, closed} = Accounts.close_account(account.id, "Customer left", support_subject)
      assert closed.deleted_at

      # Soft delete: gone from every default scope, history intact.
      assert Accounts.fetch_account_by_id_or_slug(account.id) == {:error, :not_found}

      assert [%{event_type: "account.closed"}] =
               Emisar.Repo.all(
                 Emisar.Audit.Event.Query.all()
                 |> Emisar.Audit.Event.Query.by_account_id(account.id)
                 |> Emisar.Audit.Event.Query.by_event_types(["account.closed"])
               )
    end

    test "the hourly reconcile leaves a closed account's subscription alone" do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      Fixtures.Accounts.create_subscription(account, "team",
        paddle_subscription_id: "sub_closed_no_resync"
      )

      assert {:ok, _closed} = Accounts.close_account(account.id, "Left", support_subject)

      # Without the not-deleted filter this sweep pulls the plan straight back
      # from Paddle and the closed account bills again.
      Emisar.Billing.Jobs.SyncSubscriptions.execute([])

      refute Enum.any?(
               Emisar.Repo.all(Emisar.Billing.Subscription.Query.with_live_account()),
               &(&1.account_id == account.id)
             )
    end

    test "a blank reason is refused, and an unknown account is not found" do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      assert Accounts.close_account(account.id, "", support_subject) == {:error, :invalid_reason}

      assert Accounts.close_account(Ecto.UUID.generate(), "gone", support_subject) ==
               {:error, :not_found}
    end

    test "a member cannot close their own account" do
      {_user, account, _owner} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :viewer
        )

      subject = Fixtures.Subjects.membership_subject(membership)

      assert Accounts.close_account(account.id, "nope", subject) == {:error, :unauthorized}
    end
  end

  describe "set_account_disabled_for_support/4" do
    # This function's own @doc says the permission check "is the only thing
    # standing between a future caller and disabling any account by id. It is not
    # decoration." Nothing tested it, across ~50 call sites that all pass owner
    # subjects. Swap the gate to view_own_account_permission() — held by every
    # membership role AND :api_client — and any authenticated principal locks any
    # tenant out by UUID, with the suite green.
    test "denies a principal without manage_own_account" do
      {_user, management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      viewer =
        Fixtures.Subjects.membership_subject(
          Fixtures.Memberships.create_membership(
            account_id: management_account.id,
            role: "viewer"
          )
        )

      assert Accounts.set_account_disabled_for_support(
               account.id,
               true,
               "read-only principal should not disable an account",
               viewer
             ) == {:error, :unauthorized}

      assert {:ok, %Account{disabled_at: nil}} =
               Accounts.fetch_account_by_id_or_slug_including_disabled(account.id)

      # ...and the real support path still works, so the gate is the difference.
      assert {:ok, %Account{disabled_at: %DateTime{}}} =
               Accounts.set_account_disabled_for_support(account.id, true, "abuse", subject)
    end

    test "disables and re-enables an account with atomic audit attribution" do
      {actor, _management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()
      :ok = Accounts.subscribe_account_lifecycle(account.id)

      assert {:ok, %Account{disabled_at: %DateTime{}}} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Abuse investigation",
                 subject
               )

      assert_receive {:account_disabled, account_id}
      assert account_id == account.id
      assert Accounts.fetch_account_by_id(account.id) == {:error, :not_found}

      disabled_audit =
        AuditEvent.Query.all()
        |> AuditEvent.Query.by_account_id(account.id)
        |> AuditEvent.Query.by_event_type("account.disabled")
        |> Repo.one()

      assert disabled_audit.actor_id == actor.id
      assert disabled_audit.payload["reason"] == "Abuse investigation"

      assert {:ok, %Account{disabled_at: nil}} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 false,
                 "Investigation resolved",
                 subject
               )

      assert {:ok, %Account{id: ^account_id}} = Accounts.fetch_account_by_id(account.id)
    end

    test "repeating the current state is a no-op" do
      {_actor, _management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()
      :ok = Accounts.subscribe_account_lifecycle(account.id)

      assert {:ok, disabled} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert_receive {:account_disabled, account_id}
      assert account_id == account.id

      assert {:ok, repeated} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Repeated delivery",
                 subject
               )

      assert repeated.disabled_at == disabled.disabled_at
      assert_receive {:account_disabled, ^account_id}

      count =
        AuditEvent.Query.all()
        |> AuditEvent.Query.by_account_id(account.id)
        |> AuditEvent.Query.by_event_type("account.disabled")
        |> Repo.aggregate(:count)

      assert count == 1
    end

    test "rejects an invalid reason and an unknown account" do
      {_actor, _management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()

      assert Accounts.set_account_disabled_for_support(account.id, true, "", subject) ==
               {:error, :invalid_reason}

      assert Accounts.set_account_disabled_for_support(
               Ecto.UUID.generate(),
               true,
               "Temporary hold",
               subject
             ) == {:error, :not_found}
    end

    test "locks members out of the disabled account without touching their other accounts" do
      {_actor, _management_account, support_subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()
      outsider = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)
      Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: member.id)
      member_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      outsider_token = Fixtures.Auth.create_session_token!(outsider, :magic_link, nil)

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 support_subject
               )

      # The member stays signed in, and keeps the account that was NOT disabled —
      # a session token is per-user, so revoking it here would sign them out of
      # every tenant they belong to.
      assert {:ok, %User{id: member_id}, _session} =
               Emisar.Auth.fetch_user_and_token_by_session_token(member_token)

      assert member_id == member.id

      assert {:ok, %Membership{}} =
               Accounts.fetch_membership_by_account_id_or_slug(member, other_account.id)

      # ...but the disabled account itself is gone on the next navigation, which
      # re-resolves the membership from the URL.
      assert Accounts.fetch_membership_by_account_id_or_slug(member, account.id) ==
               {:error, :not_found}

      assert {:ok, %User{id: outsider_id}, _session} =
               Emisar.Auth.fetch_user_and_token_by_session_token(outsider_token)

      assert outsider_id == outsider.id
    end
  end

  describe "subscribe_account_lifecycle/1" do
    test "subscribes only to the named account lifecycle topic" do
      {_actor, _management_account, subject} = Fixtures.Subjects.owner_subject()
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      :ok = Accounts.subscribe_account_lifecycle(account.id)

      assert {:ok, _other_account} =
               Accounts.set_account_disabled_for_support(
                 other_account.id,
                 true,
                 "Other account hold",
                 subject
               )

      refute_receive {:account_disabled, _account_id}
    end
  end

  describe "list_accounts_for_user/2" do
    test "lists every account the user is a non-suspended member of, name-ordered" do
      user = Fixtures.Users.create_user()
      zebra = Fixtures.Accounts.create_account(name: "Zebra Co")
      apple = Fixtures.Accounts.create_account(name: "Apple Co")
      Fixtures.Memberships.create_membership(account_id: zebra.id, user_id: user.id)
      Fixtures.Memberships.create_membership(account_id: apple.id, user_id: user.id)

      subject = Fixtures.Subjects.subject_for(user, apple)

      assert {:ok, accounts, _meta} = Accounts.list_accounts_for_user(subject)
      assert Enum.map(accounts, & &1.name) == ["Apple Co", "Zebra Co"]

      assert MapSet.equal?(
               MapSet.new(accounts, & &1.id),
               MapSet.new([zebra.id, apple.id])
             )
    end

    test "excludes a suspended membership's account" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      membership_a =
        Fixtures.Memberships.create_membership(
          account_id: account_a.id,
          user_id: user.id,
          role: "owner"
        )

      _membership_b =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: user.id,
          role: "owner"
        )
        |> Fixtures.Memberships.suspend_membership()

      subject = Fixtures.Subjects.membership_subject(membership_a)

      assert {:ok, accounts, _} = Accounts.list_accounts_for_user(subject)

      ids = Enum.map(accounts, & &1.id)
      assert account_a.id in ids
      refute account_b.id in ids
    end

    test "returns an empty list for a user with no memberships" do
      user = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.build_subject(user: user)

      assert {:ok, [], _} = Accounts.list_accounts_for_user(subject)
    end
  end

  describe "register_owner/2" do
    test "creates the user, the workspace and their owner membership" do
      user_attrs = %{email: Fixtures.Random.unique_email(), full_name: "New Owner"}
      account_attrs = Fixtures.Accounts.account_attrs()

      assert {:ok, %User{} = user} = Accounts.register_owner(user_attrs, account_attrs)

      assert user.email == user_attrs.email
      assert account = Repo.one(Account)
      assert account.name == account_attrs.name

      assert membership = Repo.one(Membership)
      assert membership.role == :owner
      assert membership.user_id == user.id
      assert membership.account_id == account.id
    end

    test "an invalid workspace tags the account changeset and rolls the user back" do
      user_attrs = %{email: Fixtures.Random.unique_email(), full_name: "New Owner"}
      account_attrs = Fixtures.Accounts.account_attrs(slug: "x")

      assert {:error, {:account, changeset}} =
               Accounts.register_owner(user_attrs, account_attrs)

      assert "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars" in errors_on(
               changeset
             ).slug

      refute Repo.one(User)
      refute Repo.one(Account)
      refute Repo.one(Membership)
    end

    test "a taken email tags the user changeset and writes no workspace" do
      existing = Fixtures.Users.create_user()
      user_attrs = %{email: existing.email, full_name: "Copy Cat"}

      assert {:error, {:user, changeset}} =
               Accounts.register_owner(user_attrs, Fixtures.Accounts.account_attrs())

      assert "has already been taken" in errors_on(changeset).email

      # `existing` is the only user; the signup's own row never committed.
      assert Repo.one(User).id == existing.id
      refute Repo.one(Account)
      refute Repo.one(Membership)
    end

    test "an account claiming the suggested slug before insert rolls the user back" do
      account_name = "Slug Race #{System.unique_integer([:positive])}"
      suggested_slug = Accounts.suggest_unique_slug(account_name)
      existing = Fixtures.Accounts.create_account(name: "Existing", slug: suggested_slug)
      user_attrs = %{email: Fixtures.Random.unique_email(), full_name: "New Owner"}
      account_attrs = %{name: account_name, slug: suggested_slug}

      assert {:error, {:account, changeset}} =
               Accounts.register_owner(user_attrs, account_attrs)

      assert "has already been taken" in errors_on(changeset).slug
      refute Repo.one(User)
      assert Repo.one(Account).id == existing.id
      refute Repo.one(Membership)
    end
  end

  describe "create_account_with_owner/2" do
    test "persists account + owner membership in a single transaction" do
      user = Fixtures.Users.create_user()
      attrs = Fixtures.Accounts.account_attrs()

      assert {:ok, %Account{} = account} = Accounts.create_account_with_owner(attrs, user)

      assert membership = Repo.one(Membership)
      assert membership.role == :owner
      assert membership.user_id == user.id
      assert membership.account_id == account.id
    end

    test "rolls back the whole transaction when the account changeset is invalid" do
      user = Fixtures.Users.create_user()
      invalid_attrs = Fixtures.Accounts.account_attrs(slug: "x")

      assert {:error, changeset} = Accounts.create_account_with_owner(invalid_attrs, user)

      assert "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars" in errors_on(
               changeset
             ).slug

      refute Repo.one(Account)
      refute Repo.one(Membership)
    end
  end

  describe "create_account_with_owner_from_name/2" do
    test "derives the slug from the typed name and seeds the owner membership" do
      user = Fixtures.Users.create_user()

      assert {:ok, %Account{} = account} =
               Accounts.create_account_with_owner_from_name("Acme Co!", user)

      assert account.name == "Acme Co!"
      assert account.slug =~ ~r/^acme-co/

      assert membership = Repo.one(Membership)
      assert membership.role == :owner
      assert membership.account_id == account.id
    end

    test "reports a rejected derived slug on :name, the only field the form has" do
      # "x" passes the name validation but derives a 1-character slug the
      # account slug format rejects — an error with no input of its own.
      user = Fixtures.Users.create_user()

      assert {:error, changeset} = Accounts.create_account_with_owner_from_name("x", user)

      assert "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars" in errors_on(
               changeset
             ).name

      refute Repo.one(Account)
    end

    test "leaves an existing :name error alone" do
      user = Fixtures.Users.create_user()

      assert {:error, changeset} = Accounts.create_account_with_owner_from_name("", user)

      assert "can't be blank" in errors_on(changeset).name
      assert length(errors_on(changeset).name) == 1
    end
  end

  describe "update_account/3 — require_sso (owner + admin security setting)" do
    test "refuses to require SSO when no enabled connection exists" do
      # The lockout this prevents: require_sso on with nothing to sign in
      # through leaves everyone out, owners included. The check used to live in
      # the Team page's click handler, so any other caller skipped it — and even
      # there it read providers outside the write's transaction, so a concurrent
      # disable could slip through.
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert Accounts.update_account(account, %{settings: %{require_sso: true}}, subject) ==
               {:error, :require_sso_without_provider}

      refute Repo.reload!(account).settings.require_sso
    end

    test "a disabled connection is not a way in" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: false)

      assert Accounts.update_account(account, %{settings: %{require_sso: true}}, subject) ==
               {:error, :require_sso_without_provider}
    end

    test "turning the requirement OFF never needs a provider" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:ok, _} =
               Accounts.update_account(account, %{settings: %{require_sso: false}}, subject)
    end

    test "an owner can enable require_sso" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      # require_sso needs a way in — enabling it with no enabled connection would
      # lock everyone out, owners included, so the domain refuses it.
      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      assert {:ok, %Account{settings: %{require_sso: true}}} =
               Accounts.update_account(account, %{settings: %{require_sso: true}}, owner_subject)
    end

    test "an admin can enable require_sso (owners + admins manage security settings)" do
      account = Fixtures.Accounts.create_account()
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      # require_sso needs a way in — enabling it with no enabled connection would
      # lock everyone out, owners included, so the domain refuses it.
      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      assert {:ok, %Account{settings: %{require_sso: true}}} =
               Accounts.update_account(account, %{settings: %{require_sso: true}}, admin_subject)
    end

    test "an operator cannot change a security setting (no manage_security_settings)" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Accounts.update_account(
               account,
               %{settings: %{require_sso: true}},
               operator_subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(account).settings.require_sso
    end

    test "an owner of another account can't toggle this account's require_sso (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      subject_b = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_b)

      assert Accounts.update_account(account_a, %{settings: %{require_sso: true}}, subject_b) ==
               {:error, :unauthorized}

      refute Repo.reload!(account_a).settings.require_sso
    end

    test "an owner of another account can't toggle this account's require_mfa (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      subject_b = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_b)

      assert Accounts.update_account(account_a, %{settings: %{require_mfa: true}}, subject_b) ==
               {:error, :unauthorized}

      refute Repo.reload!(account_a).settings.require_mfa
    end

    test "an admin can rename the account — only the security flags need manage_security_settings" do
      account = Fixtures.Accounts.create_account()
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:ok, %Account{name: "Renamed By Admin"}} =
               Accounts.update_account(account, %{name: "Renamed By Admin"}, admin_subject)
    end
  end

  describe "update_account/3 — require_mfa self-lockout" do
    test "an unenrolled owner cannot enable MFA enforcement" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(owner, account)

      assert Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject) ==
               {:error, :mfa_enrollment_required}

      refute Repo.reload!(account).settings.require_mfa
      assert Repo.all(Audit.Event) == []
    end

    test "an enrolled owner can enable MFA enforcement with a stale subject" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(owner, account)

      enroll_mfa(owner)

      assert {:ok, %Account{settings: %{require_mfa: true}}} =
               Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject)
    end

    test "an actor whose user row is gone cannot enable MFA enforcement" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(owner, account)

      enroll_mfa(owner)
      Fixtures.Users.mark_user_as_deleted(owner)

      assert Accounts.update_account(account, %{settings: %{require_mfa: true}}, subject) ==
               {:error, :mfa_enrollment_required}

      refute Repo.reload!(account).settings.require_mfa
      assert Repo.all(Audit.Event) == []
    end

    test "disabling MFA enforcement never requires enrollment" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      assert {:ok, %Account{settings: %{require_mfa: false}}} =
               Accounts.update_account(account, %{settings: %{require_mfa: false}}, subject)
    end
  end

  describe "update_account/3 — max_grant_lifetime_seconds (owned by Approvals)" do
    test "an owner cannot set the standing-grant cap through the generic update" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:error, changeset} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 86_400}},
                 owner_subject
               )

      assert "is set through the approval settings" in errors_on(changeset).settings.max_grant_lifetime_seconds

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
      assert Repo.all(Audit.Event) == []
    end

    test "the kill switch is refused here too — disabling grants is one domain use case" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:error, changeset} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 0}},
                 owner_subject
               )

      assert "is set through the approval settings" in errors_on(changeset).settings.max_grant_lifetime_seconds

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
    end
  end

  describe "update_account/3 — multi-setting audit" do
    test "records each changed security setting" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      subject = Fixtures.Subjects.subject_for(owner, account)
      enroll_mfa(owner)

      # require_sso needs a way in — enabling it with no enabled connection would
      # lock everyone out, owners included, so the domain refuses it.
      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      assert {:ok, %Account{settings: settings}} =
               Accounts.update_account(
                 account,
                 %{settings: %{require_mfa: true, require_sso: true}},
                 subject
               )

      assert settings.require_mfa
      assert settings.require_sso

      assert Enum.sort(Enum.map(Repo.all(Audit.Event), & &1.event_type)) ==
               ["account.require_mfa_set", "account.require_sso_set"]
    end
  end

  describe "update_account/3 — monthly_report_opt_out (a non-security preference)" do
    test "an owner can opt out of the monthly report and back in" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:ok, %Account{settings: %{monthly_report_opt_out: true}}} =
               Accounts.update_account(
                 account,
                 %{settings: %{monthly_report_opt_out: true}},
                 owner_subject
               )

      assert {:ok, %Account{settings: %{monthly_report_opt_out: false}}} =
               Accounts.update_account(
                 account,
                 %{settings: %{monthly_report_opt_out: false}},
                 owner_subject
               )
    end

    test "it is NOT a security change — audited as account.updated, not a security event" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:ok, _account} =
               Accounts.update_account(
                 account,
                 %{settings: %{monthly_report_opt_out: true}},
                 owner_subject
               )

      assert Enum.map(Repo.all(Audit.Event), & &1.event_type) == ["account.updated"]
    end

    test "an operator cannot toggle it (no manage_own_account)" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Accounts.update_account(
               account,
               %{settings: %{monthly_report_opt_out: true}},
               operator_subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "an owner of another account can't toggle this account's report (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.update_account(
               account_a,
               %{settings: %{monthly_report_opt_out: true}},
               subject_b
             ) == {:error, :unauthorized}

      refute Repo.reload!(account_a).settings.monthly_report_opt_out
    end
  end

  describe "update_account/3 — runner_inactive_retention_hours (owned by Runners)" do
    test "an owner cannot arm the inactivity sweep through the generic update" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      assert {:error, changeset} =
               Accounts.update_account(
                 account,
                 %{settings: %{runner_inactive_retention_hours: 24}},
                 owner_subject
               )

      assert "is set through the runner settings" in errors_on(changeset).settings.runner_inactive_retention_hours

      assert Repo.reload!(account).settings.runner_inactive_retention_hours == nil
      assert Repo.all(Audit.Event) == []
    end
  end

  describe "change_account/2" do
    test "builds an update changeset for the form (no DB write)" do
      account = Fixtures.Accounts.create_account()

      assert changeset = Accounts.change_account(account, %{name: "Renamed"})
      assert changeset.valid?
      assert changeset.changes == %{name: "Renamed"}
    end

    test "with no attrs, yields a valid, change-free changeset" do
      account = Fixtures.Accounts.create_account()

      assert changeset = Accounts.change_account(account)
      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "surfaces validation errors for the inline form" do
      account = Fixtures.Accounts.create_account()

      assert changeset = Accounts.change_account(account, %{name: ""})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "put_account_pack_retention_days/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      %{account: account, subject: subject}
    end

    test "writes the canonical window Catalog validated", %{account: account, subject: subject} do
      assert {:ok, updated} = Accounts.put_account_pack_retention_days(account.id, 30, subject)
      assert updated.settings.pack_unseen_retention_days == 30
      assert Enum.map(Repo.all(Audit.Event), & &1.event_type) == ["account.updated"]
    end

    test "nil turns automatic cleanup off", %{account: account, subject: subject} do
      Fixtures.Accounts.set_account_settings(account, %{pack_unseen_retention_days: 30})

      assert {:ok, updated} = Accounts.put_account_pack_retention_days(account.id, nil, subject)
      assert updated.settings.pack_unseen_retention_days == nil
    end

    test "leaves every other setting alone", %{account: account, subject: subject} do
      Fixtures.Accounts.set_account_settings(account, %{
        require_mfa: true,
        monthly_report_opt_out: true
      })

      assert {:ok, updated} = Accounts.put_account_pack_retention_days(account.id, 7, subject)
      assert updated.settings.require_mfa
      assert updated.settings.monthly_report_opt_out
      assert updated.settings.pack_unseen_retention_days == 7
    end

    test "a deleted account is :not_found", %{account: account, subject: subject} do
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Accounts.put_account_pack_retention_days(account.id, 30, subject) ==
               {:error, :not_found}
    end

    test "a malformed id is :not_found, never a query", %{subject: subject} do
      assert Accounts.put_account_pack_retention_days("not-a-uuid", 30, subject) ==
               {:error, :not_found}
    end

    test "another account's subject is :not_found", %{account: account} do
      other_account = Fixtures.Accounts.create_account()

      other_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), other_account)

      assert Accounts.put_account_pack_retention_days(account.id, 30, other_subject) ==
               {:error, :not_found}

      assert Repo.reload!(account).settings.pack_unseen_retention_days == nil
    end
  end

  describe "put_account_runner_inactive_retention_hours/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      %{account: account, subject: subject}
    end

    test "writes the canonical window Runners validated", %{account: account, subject: subject} do
      assert {:ok, updated} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, 24, subject)

      assert updated.settings.runner_inactive_retention_hours == 24
      assert Enum.map(Repo.all(Audit.Event), & &1.event_type) == ["account.updated"]
    end

    test "nil turns automatic cleanup off", %{account: account, subject: subject} do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 24)

      assert {:ok, updated} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, nil, subject)

      assert updated.settings.runner_inactive_retention_hours == nil
    end

    test "leaves every other setting alone", %{account: account, subject: subject} do
      Fixtures.Accounts.set_account_settings(account, %{
        require_mfa: true,
        pack_unseen_retention_days: 30
      })

      assert {:ok, updated} =
               Accounts.put_account_runner_inactive_retention_hours(account.id, 6, subject)

      assert updated.settings.require_mfa
      assert updated.settings.pack_unseen_retention_days == 30
      assert updated.settings.runner_inactive_retention_hours == 6
    end

    test "a deleted account is :not_found", %{account: account, subject: subject} do
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Accounts.put_account_runner_inactive_retention_hours(account.id, 24, subject) ==
               {:error, :not_found}
    end

    test "a malformed id is :not_found, never a query", %{subject: subject} do
      assert Accounts.put_account_runner_inactive_retention_hours("not-a-uuid", 24, subject) ==
               {:error, :not_found}
    end

    test "another account's subject is :not_found", %{account: account} do
      other_account = Fixtures.Accounts.create_account()

      other_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), other_account)

      assert Accounts.put_account_runner_inactive_retention_hours(account.id, 24, other_subject) ==
               {:error, :not_found}

      assert Repo.reload!(account).settings.runner_inactive_retention_hours == nil
    end
  end

  describe "put_account_max_grant_lifetime_seconds/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      %{account: account, subject: subject}
    end

    test "writes the canonical cap Approvals validated, with its own audit event", %{
      account: account,
      subject: subject
    } do
      assert {:ok, updated} =
               Accounts.put_account_max_grant_lifetime_seconds(account.id, 86_400, subject)

      assert updated.settings.max_grant_lifetime_seconds == 86_400

      assert Enum.map(Repo.all(Audit.Event), & &1.event_type) ==
               ["account.max_grant_lifetime_set"]
    end

    test "0 disables standing grants and nil removes the cap", %{
      account: account,
      subject: subject
    } do
      assert {:ok, disabled} =
               Accounts.put_account_max_grant_lifetime_seconds(account.id, 0, subject)

      assert disabled.settings.max_grant_lifetime_seconds == 0

      assert {:ok, uncapped} =
               Accounts.put_account_max_grant_lifetime_seconds(account.id, nil, subject)

      assert uncapped.settings.max_grant_lifetime_seconds == nil
    end

    test "leaves every other setting alone", %{account: account, subject: subject} do
      Fixtures.Accounts.set_account_settings(account, %{
        require_mfa: true,
        pack_unseen_retention_days: 30
      })

      assert {:ok, updated} =
               Accounts.put_account_max_grant_lifetime_seconds(account.id, 3_600, subject)

      assert updated.settings.require_mfa
      assert updated.settings.pack_unseen_retention_days == 30
      assert updated.settings.max_grant_lifetime_seconds == 3_600
    end

    test "a deleted account is :not_found", %{account: account, subject: subject} do
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Accounts.put_account_max_grant_lifetime_seconds(account.id, 0, subject) ==
               {:error, :not_found}
    end

    test "a malformed id is :not_found, never a query", %{subject: subject} do
      assert Accounts.put_account_max_grant_lifetime_seconds("not-a-uuid", 0, subject) ==
               {:error, :not_found}
    end

    test "another account's subject is :not_found", %{account: account} do
      other_account = Fixtures.Accounts.create_account()

      other_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), other_account)

      assert Accounts.put_account_max_grant_lifetime_seconds(account.id, 0, other_subject) ==
               {:error, :not_found}

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
    end
  end

  describe "suggest_unique_slug/1" do
    test "returns the slugified base when free" do
      assert Accounts.suggest_unique_slug("Acme Co!") =~ ~r/^acme-co/
    end

    test "appends -1, -2, ... on collision" do
      base = "team-#{System.unique_integer([:positive])}"
      Fixtures.Accounts.create_account(slug: base)
      Fixtures.Accounts.create_account(slug: base <> "-1")

      assert Accounts.suggest_unique_slug(base) == base <> "-2"
    end
  end

  describe "list_memberships_for_account/3" do
    test "lists the account's members for a member subject" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(owner_membership)
      _other_membership = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships, _} = Accounts.list_memberships_for_account(account, subject)
      assert length(memberships) == 2
    end

    test "list_account_memberships/2 (system fan-out read) is scoped to the given account" do
      account_a = Fixtures.Accounts.create_account()

      _membership_a =
        Fixtures.Memberships.create_membership(account_id: account_a.id, role: "owner")

      account_b = Fixtures.Accounts.create_account()
      _membership_b = Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "a subject cannot list another account's memberships" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      account_b = Fixtures.Accounts.create_account()

      assert Accounts.list_memberships_for_account(account_b, subject_a) ==
               {:error, :unauthorized}
    end
  end

  describe "touch_membership_activity/1" do
    test "touches once per five-minute window and leaves updated_at alone" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, owner.id)

      assert is_nil(membership.last_active_at)
      assert Accounts.touch_membership_activity(subject) == {:ok, :touched}

      first = Repo.reload!(membership)
      assert %DateTime{} = first.last_active_at
      assert first.updated_at == membership.updated_at

      assert Accounts.touch_membership_activity(subject) == {:ok, :unchanged}
      assert Repo.reload!(membership).last_active_at == first.last_active_at

      stale_at = DateTime.add(first.last_active_at, -301, :second)
      Fixtures.Memberships.set_last_active_at(first, stale_at)

      assert Accounts.touch_membership_activity(subject) == {:ok, :touched}
      assert DateTime.after?(Repo.reload!(membership).last_active_at, stale_at)
    end

    test "requires the account-view permission" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.fetch_membership(account.id, owner.id)

      no_view =
        Fixtures.Subjects.build_subject(
          user: owner,
          account: account,
          membership_id: membership.id,
          role: :runner,
          permissions: MapSet.new()
        )

      assert Accounts.touch_membership_activity(no_view) == {:error, :unauthorized}
      assert is_nil(Repo.reload!(membership).last_active_at)
    end

    test "only touches the actor's current membership" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      owner_membership = Fixtures.Memberships.fetch_membership(account.id, owner.id)
      target = Fixtures.Memberships.create_membership(account_id: account.id)
      forged = %{subject | membership_id: target.id}

      assert Accounts.touch_membership_activity(forged) == {:ok, :unchanged}
      assert is_nil(Repo.reload!(owner_membership).last_active_at)
      assert is_nil(Repo.reload!(target).last_active_at)
    end

    test "a cross-account membership id is an unchanged no-op" do
      {owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      membership_a = Fixtures.Memberships.fetch_membership(account_a.id, owner_a.id)
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      forged = %{subject_b | actor: owner_a, membership_id: membership_a.id}

      assert Accounts.touch_membership_activity(forged) == {:ok, :unchanged}
      assert is_nil(Repo.reload!(membership_a).last_active_at)
    end

    test "suspended and deleted memberships are unchanged no-ops" do
      {owner_suspended, account_suspended, suspended_subject} =
        Fixtures.Subjects.owner_subject()

      suspended =
        Fixtures.Memberships.fetch_membership(account_suspended.id, owner_suspended.id)
        |> Fixtures.Memberships.suspend_membership()

      {owner_deleted, account_deleted, deleted_subject} = Fixtures.Subjects.owner_subject()

      deleted =
        Fixtures.Memberships.fetch_membership(account_deleted.id, owner_deleted.id)
        |> Fixtures.Memberships.mark_membership_as_deleted()

      assert Accounts.touch_membership_activity(suspended_subject) == {:ok, :unchanged}
      assert Accounts.touch_membership_activity(deleted_subject) == {:ok, :unchanged}
      assert is_nil(Repo.reload!(suspended).last_active_at)
      assert is_nil(Repo.reload!(deleted).last_active_at)
    end
  end

  describe "team_member_filters/0" do
    test "carries the Team roster's filters in panel order" do
      assert Enum.map(Accounts.team_member_filters(), & &1.name) == [
               :name_or_email,
               :role,
               :status
             ]
    end

    test "the role filter offers every role, labelled as the roster renders it" do
      # The web never reaches into a Query module, so this vocabulary IS the
      # roster's role picker — a role missing here is a member nobody can filter
      # for, and a raw `billing_manager` here would render unlabelled.
      role = Enum.find(Accounts.team_member_filters(), &(&1.name == :role))

      assert Enum.map(role.values, &elem(&1, 0)) == Enum.map(Emisar.Auth.roles(), &to_string/1)

      for {value, label} <- role.values do
        assert label == Emisar.Auth.role_label(value)
      end
    end

    test "the status filter names the four security states the roster shows" do
      status = Enum.find(Accounts.team_member_filters(), &(&1.name == :status))

      assert status.values == [
               {"active", "Active"},
               {"pending_invitation", "Pending invitation"},
               {"suspended", "Suspended"},
               {"email_unconfirmed", "Email unconfirmed"}
             ]
    end
  end

  describe "list_team_member_facts/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      %{
        account: account,
        owner: owner,
        owner_membership: owner_membership,
        subject: Fixtures.Subjects.membership_subject(owner_membership)
      }
    end

    test "returns one fact per member with its user preloaded", %{
      account: account,
      owner: owner,
      subject: subject
    } do
      Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      assert length(facts) == 2
      assert Enum.all?(facts, &match?(%User{}, &1.membership.user))
      assert owner.id in Enum.map(facts, & &1.membership.user_id)
    end

    test "searches account-local name, user name, and email case-insensitively", %{
      account: account,
      subject: subject
    } do
      directory_user = Fixtures.Users.create_user(full_name: "Personal Name")

      directory_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: directory_user.id
        )
        |> Fixtures.Memberships.sync_display_name("Platform Rowan")

      named_user = Fixtures.Users.create_user(full_name: "Casey Search")

      named_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: named_user.id)

      email_user = Fixtures.Users.create_user(email: "needle.team@example.com")

      email_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: email_user.id)

      percent_user = Fixtures.Users.create_user(full_name: "Percent % Person")

      percent_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: percent_user.id)

      for {term, expected_id} <- [
            {"platform ROW", directory_membership.id},
            {"CASEY sea", named_membership.id},
            {"NEEDLE.TEAM@", email_membership.id},
            {"%", percent_membership.id}
          ] do
        assert {:ok, facts, _metadata} =
                 Accounts.list_team_member_facts(account, subject, filter: [name_or_email: term])

        assert Enum.map(facts, & &1.membership.id) == [expected_id]
      end
    end

    test "role and status filters compose, while lifecycle statuses retain overlap", %{
      account: account,
      owner_membership: owner_membership,
      subject: subject
    } do
      active = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      pending_user = Fixtures.Users.create_user(confirmed?: false)

      pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: pending_user.id,
          role: "viewer",
          invitation_token_digest: "pending"
        )

      unconfirmed_user = Fixtures.Users.create_user(confirmed?: false)

      unconfirmed =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: unconfirmed_user.id,
          role: "viewer"
        )

      suspended =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.suspend_membership()

      suspended_pending_user = Fixtures.Users.create_user(confirmed?: false)

      suspended_pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: suspended_pending_user.id,
          invitation_token_digest: "suspended-pending"
        )
        |> Fixtures.Memberships.suspend_membership()

      assert filtered_membership_ids(account, subject, status: ["active"]) ==
               MapSet.new([owner_membership.id, active.id])

      assert filtered_membership_ids(account, subject, status: ["pending_invitation"]) ==
               MapSet.new([pending.id, suspended_pending.id])

      assert filtered_membership_ids(account, subject, status: ["suspended"]) ==
               MapSet.new([suspended.id, suspended_pending.id])

      assert filtered_membership_ids(account, subject, status: ["email_unconfirmed"]) ==
               MapSet.new([unconfirmed.id])

      assert filtered_membership_ids(account, subject,
               role: ["viewer"],
               status: ["email_unconfirmed"]
             ) == MapSet.new([unconfirmed.id])
    end

    test "never hands the web an invitation token digest", %{account: account, subject: subject} do
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        invitation_token_digest: "digest"
      )

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      invited = Enum.find(facts, & &1.pending_invitation?)

      assert invited.membership.invitation_token_digest == nil
    end

    test "a pending invitation can be resent; a suspended one cannot", %{
      account: account,
      subject: subject
    } do
      pending =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          invitation_token_digest: "digest"
        )

      suspended =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          invitation_token_digest: "digest"
        )
        |> Fixtures.Memberships.suspend_membership()

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      assert facts_by_id[pending.id].pending_invitation?
      refute facts_by_id[pending.id].disabled?
      assert facts_by_id[pending.id].resend_invitation?

      # Both booleans stay true — a suspended invitee is pending AND disabled —
      # and only the action they gate goes away.
      assert facts_by_id[suspended.id].pending_invitation?
      assert facts_by_id[suspended.id].disabled?
      refute facts_by_id[suspended.id].resend_invitation?
    end

    test "MFA enrollment drives the badge and the reset action", %{
      account: account,
      owner_membership: owner_membership,
      subject: subject
    } do
      enrolled = Fixtures.Users.create_user()
      enroll_mfa(enrolled)

      enrolled_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: enrolled.id)

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      assert facts_by_id[enrolled_membership.id].mfa_enrolled?
      assert facts_by_id[enrolled_membership.id].reset_mfa?
      refute facts_by_id[owner_membership.id].mfa_enrolled?
      refute facts_by_id[owner_membership.id].reset_mfa?
    end

    test "confirmation state drives the badge and only the actor's resend action", %{
      account: account,
      subject: subject
    } do
      unconfirmed = Fixtures.Users.create_user(confirmed?: false)

      unconfirmed_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: unconfirmed.id
        )

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      assert facts_by_id[unconfirmed_membership.id].confirmation_pending?
      refute facts_by_id[unconfirmed_membership.id].resend_confirmation?

      unconfirmed_subject = Fixtures.Subjects.membership_subject(unconfirmed_membership)

      assert {:ok, self_facts, _metadata} =
               Accounts.list_team_member_facts(account, unconfirmed_subject)

      assert Enum.find(self_facts, &(&1.membership.id == unconfirmed_membership.id)).resend_confirmation?
    end

    test "self_owner? is true only for the ACTOR's own owner row", %{
      account: account,
      owner_membership: owner_membership,
      subject: subject
    } do
      other_owner =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      self_admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: self_admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      assert facts_by_id[owner_membership.id].self_owner?
      refute facts_by_id[owner_membership.id].role_editable?
      refute facts_by_id[other_owner.id].self_owner?
      assert facts_by_id[other_owner.id].role_editable?

      assert {:ok, admin_facts, _metadata} =
               Accounts.list_team_member_facts(account, admin_subject)

      admin_facts_by_id = Map.new(admin_facts, &{&1.membership.id, &1})
      refute admin_facts_by_id[admin_membership.id].self_owner?
      assert admin_facts_by_id[admin_membership.id].role_editable?
    end

    test "directory ownership closes role and runner-access editing", %{
      account: account,
      subject: subject
    } do
      synced_role =
        Fixtures.Memberships.create_membership(account_id: account.id)
        |> Fixtures.Memberships.mark_directory_managed()

      synced_access =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          runner_access_directory_managed: true
        )

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      refute facts_by_id[synced_role.id].role_editable?
      assert facts_by_id[synced_role.id].runner_access_editable?
      assert facts_by_id[synced_access.id].role_editable?
      refute facts_by_id[synced_access.id].runner_access_editable?
    end

    test "carries each member's persisted runner access", %{account: account, subject: subject} do
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      Fixtures.Memberships.force_runner_access(
        membership,
        Accounts.RunnerAccess.none()
      )

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      facts_by_id = Map.new(facts, &{&1.membership.id, &1})

      assert facts_by_id[membership.id].runner_access == Accounts.RunnerAccess.none()
    end

    test "a viewer of the account can read the roster", %{account: account} do
      viewer = Fixtures.Users.create_user()

      viewer_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.membership_subject(viewer_membership)

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, viewer_subject)
      assert length(facts) == 2
    end

    test "only managers receive an account-local suspension author label", %{
      account: account,
      owner: owner,
      owner_membership: owner_membership,
      subject: subject
    } do
      target = Fixtures.Memberships.create_membership(account_id: account.id)
      assert {:ok, suspended} = Accounts.suspend_membership(target, subject)

      assert {:ok, manager_facts, _metadata} =
               Accounts.list_team_member_facts(account, subject)

      manager_fact = Enum.find(manager_facts, &(&1.membership.id == target.id))

      assert manager_fact.suspended_by_label ==
               Accounts.member_display_name(owner_membership, owner)

      assert is_nil(manager_fact.membership.disabled_by_id)

      viewer = Fixtures.Users.create_user()

      viewer_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.membership_subject(viewer_membership)

      assert {:ok, viewer_facts, _metadata} =
               Accounts.list_team_member_facts(account, viewer_subject)

      viewer_fact = Enum.find(viewer_facts, &(&1.membership.id == suspended.id))
      refute Map.has_key?(viewer_fact, :suspended_by_label)
      assert is_nil(viewer_fact.membership.disabled_by_id)
    end

    test "a former suspension author resolves to no manager-visible label", %{
      account: account,
      subject: subject
    } do
      admin = Fixtures.Users.create_user(full_name: "Former Admin")

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      target = Fixtures.Memberships.create_membership(account_id: account.id)
      admin_subject = Fixtures.Subjects.membership_subject(admin_membership)
      assert {:ok, _suspended} = Accounts.suspend_membership(target, admin_subject)
      Fixtures.Memberships.mark_membership_as_deleted(admin_membership)

      assert {:ok, facts, _metadata} = Accounts.list_team_member_facts(account, subject)
      target_fact = Enum.find(facts, &(&1.membership.id == target.id))

      assert is_nil(target_fact.suspended_by_label)
      assert is_nil(target_fact.membership.disabled_by_id)
    end

    test "a subject from another account is refused even when filters are supplied", %{
      account: account
    } do
      {_other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Accounts.list_team_member_facts(account, other_subject,
               filter: [role: ["owner"], status: ["active"]]
             ) == {:error, :unauthorized}
    end
  end

  describe "fetch_team_member_facts/2" do
    setup do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      %{
        account: account,
        owner_membership: owner_membership,
        subject: Fixtures.Subjects.membership_subject(owner_membership)
      }
    end

    test "reads the member's CURRENT state, not the caller's copy", %{
      account: account,
      subject: subject
    } do
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, facts} = Accounts.fetch_team_member_facts(membership.id, subject)
      assert facts.runner_access_editable?

      Fixtures.Memberships.create_membership(account_id: account.id)

      {1, _} =
        Membership.Query.all()
        |> Membership.Query.by_id(membership.id)
        |> Repo.update_all(set: [runner_access_directory_managed: true])

      assert {:ok, refreshed} = Accounts.fetch_team_member_facts(membership.id, subject)
      refute refreshed.runner_access_editable?
    end

    test "an unknown or malformed id is :not_found", %{subject: subject} do
      assert Accounts.fetch_team_member_facts(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}

      assert Accounts.fetch_team_member_facts("not-a-uuid", subject) == {:error, :not_found}
    end

    test "a subject with no account permission is refused", %{
      account: account,
      owner_membership: owner_membership
    } do
      stranger =
        Fixtures.Subjects.build_subject(
          account: account,
          user: Fixtures.Users.create_user(),
          role: :runner
        )

      assert Accounts.fetch_team_member_facts(owner_membership.id, stranger) ==
               {:error, :unauthorized}
    end

    test "another account's member is :not_found", %{account: account} do
      membership = Fixtures.Memberships.create_membership(account_id: account.id)
      {_other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert Accounts.fetch_team_member_facts(membership.id, other_subject) ==
               {:error, :not_found}
    end
  end

  describe "list_memberships_for_users/3" do
    test "returns the given users' memberships, user preloaded" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      second = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships} =
               Accounts.list_memberships_for_users(account, [owner.id, second.user_id], subject)

      assert memberships |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([owner.id, second.user_id])

      assert Enum.all?(memberships, &match?(%Emisar.Users.User{}, &1.user))
    end

    test "ignores user_ids that aren't members of the account" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      stranger = Fixtures.Users.create_user()

      assert {:ok, [membership]} =
               Accounts.list_memberships_for_users(account, [owner.id, stranger.id], subject)

      assert membership.user_id == owner.id
    end

    test "a subject cannot read another account's memberships" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _} = Fixtures.Subjects.owner_subject()

      assert Accounts.list_memberships_for_users(account_b, [owner_b.id], subject_a) ==
               {:error, :unauthorized}
    end
  end

  describe "fetch_team_security_facts/1" do
    test "counts members and MFA enrollment account-wide (not per page)" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(owner_membership)
      enroll_mfa(owner)

      enrolled_member = Fixtures.Users.create_user()
      enroll_mfa(enrolled_member)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: enrolled_member.id,
        role: "admin"
      )

      unenrolled_member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: unenrolled_member.id,
        role: "viewer"
      )

      assert {:ok, %{mfa_total: 3, mfa_enrolled: 2, mfa_missing: 1}} =
               Accounts.fetch_team_security_facts(subject)
    end

    test "the denominator is every non-deleted membership — suspended and pending too" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      subject = Fixtures.Subjects.membership_subject(owner_membership)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        invitation_token_digest: "digest"
      )

      Fixtures.Memberships.create_membership(account_id: account.id)
      |> Fixtures.Memberships.suspend_membership()

      Fixtures.Memberships.create_membership(account_id: account.id)
      |> Fixtures.Memberships.mark_membership_as_deleted()

      assert {:ok, %{mfa_total: 3}} = Accounts.fetch_team_security_facts(subject)
    end

    test "counts only the subject's own account" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(owner_membership)
      enroll_mfa(owner)

      # A separate account with its own enrolled member must not leak in.
      other_member = Fixtures.Users.create_user()
      enroll_mfa(other_member)
      other_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: other_member.id
      )

      assert {:ok, %{mfa_total: 1, mfa_enrolled: 1}} =
               Accounts.fetch_team_security_facts(subject)
    end

    test "team_managers counts the roles that can manage the team, on the same denominator" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      subject = Fixtures.Subjects.membership_subject(owner_membership)

      Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")
      Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      # billing_manager is the orthogonal finance seat — it holds no manage_team,
      # so the count is the owner and the admin, never "everyone above operator".
      assert {:ok, %{mfa_total: 5, team_managers: 2}} =
               Accounts.fetch_team_security_facts(subject)
    end

    test "team_managers counts only the subject's own account" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      subject = Fixtures.Subjects.membership_subject(owner_membership)

      other_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: other_account.id, role: "owner")
      Fixtures.Memberships.create_membership(account_id: other_account.id, role: "admin")

      assert {:ok, %{team_managers: 1}} = Accounts.fetch_team_security_facts(subject)
    end

    test "the enforcement state and SSO requirement come from the CURRENT account row" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(owner_membership)

      assert {:ok, %{mfa_enforcement: :actor_not_enrolled, sso_required?: false}} =
               Accounts.fetch_team_security_facts(subject)

      # The subject still carries the pre-enrollment user and the pre-update
      # account; both answers have to come from the rows, not that snapshot.
      enroll_mfa(owner)

      assert {:ok, %{mfa_enforcement: :available}} = Accounts.fetch_team_security_facts(subject)

      Fixtures.SSO.create_identity_provider(account_id: account.id, enabled: true)

      {:ok, _account} =
        Accounts.update_account(
          account,
          %{settings: %{require_mfa: true, require_sso: true}},
          subject
        )

      assert {:ok, %{mfa_enforcement: :enforced, sso_required?: true}} =
               Accounts.fetch_team_security_facts(subject)
    end

    test "refuses a subject with no account permission" do
      account = Fixtures.Accounts.create_account()

      runner_subject =
        Fixtures.Subjects.build_subject(
          account: account,
          user: Fixtures.Users.create_user(),
          role: :runner
        )

      assert Accounts.fetch_team_security_facts(runner_subject) == {:error, :unauthorized}
    end

    test "a subject from another account reads only its own totals" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.create_membership(account_id: account.id)
      {_other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %{mfa_total: 1}} = Accounts.fetch_team_security_facts(other_subject)
    end
  end

  describe "suppressed_member_emails/2" do
    test "returns the account's member emails that are on the suppression list" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      bouncing = Fixtures.Users.create_user(email: "bouncing@example.com")
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: bouncing.id)
      _fine = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, _} = Mail.suppress("bouncing@example.com", :hard_bounce, "bounce")

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert suppressed == MapSet.new(["bouncing@example.com"])
    end

    test "is empty when no member email is suppressed" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert MapSet.size(suppressed) == 0
    end

    test "never surfaces a suppression that belongs only to another account" do
      account_a = Fixtures.Accounts.create_account()
      subject_a = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_a)
      account_b = Fixtures.Accounts.create_account()

      # An address suppressed globally, but a member only of account B.
      b_member = Fixtures.Users.create_user(email: "b-only@example.com")
      Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: b_member.id)
      {:ok, _} = Mail.suppress("b-only@example.com", :hard_bounce, "bounce")

      # Account A asks for ITS suppressed emails — B's bouncing address must not leak.
      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account_a, subject_a)
      refute MapSet.member?(suppressed, "b-only@example.com")
      assert MapSet.size(suppressed) == 0
    end

    test "a subject cannot read another account's suppressed emails" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      account_b = Fixtures.Accounts.create_account()

      assert Accounts.suppressed_member_emails(account_b, subject_a) == {:error, :unauthorized}
    end
  end

  describe "list_account_memberships/2" do
    test "lists every membership in the account with :user preloaded (the notifier's contract)" do
      account = Fixtures.Accounts.create_account()
      membership_one = Fixtures.Memberships.create_membership(account_id: account.id)
      membership_two = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships, _meta} = Accounts.list_account_memberships(account.id)

      ids = memberships |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([membership_one.id, membership_two.id])
      # `user` is this helper's contract — the approval notifier addresses the
      # email off it, so it must be preloaded, not an unloaded assoc.
      assert Enum.all?(memberships, &match?(%User{}, &1.user))
    end

    test "is scoped to the given account (no cross-account fan-out leak)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id)
      Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)
      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end
  end

  describe "sync_member_display_name/4" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      %{account: account, provider: provider}
    end

    test "records the name and reports whether this is the person's only workspace", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      audit = &Emisar.Audit.Events.membership_renamed_via_scim(&1, provider, "Dir Name")

      assert {:ok, updated, true} =
               Accounts.sync_member_display_name(account.id, member.user_id, "Dir Name",
                 audit: audit
               )

      assert updated.directory_display_name == "Dir Name"

      other = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other.id,
        user_id: member.user_id,
        role: "viewer"
      )

      audit = &Emisar.Audit.Events.membership_renamed_via_scim(&1, provider, "Another Name")

      assert {:ok, _updated, false} =
               Accounts.sync_member_display_name(account.id, member.user_id, "Another Name",
                 audit: audit
               )
    end

    test "the directory's name change is audited from→to", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      audit = &Emisar.Audit.Events.membership_renamed_via_scim(&1, provider, "Dir Name")

      assert {:ok, _updated, true} =
               Accounts.sync_member_display_name(account.id, member.user_id, "Dir Name",
                 audit: audit
               )

      assert event = Repo.one(Emisar.Audit.Event)
      assert event.event_type == "membership.renamed_via_scim"
      assert event.actor_kind == "directory_sync"
      assert event.actor_id == provider.id
      assert event.target_id == member.user_id
      assert event.payload["from"] == nil
      assert event.payload["to"] == "Dir Name"
    end

    test "an unchanged name writes no row and no audit event", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      audit = &Emisar.Audit.Events.membership_renamed_via_scim(&1, provider, "Dir Name")

      {:ok, _updated, true} =
        Accounts.sync_member_display_name(account.id, member.user_id, "Dir Name", audit: audit)

      Repo.delete_all(Emisar.Audit.Event)

      assert {:ok, _updated, true} =
               Accounts.sync_member_display_name(account.id, member.user_id, "Dir Name",
                 audit: audit
               )

      refute Repo.one(Emisar.Audit.Event)
    end

    test "an unknown member is not found", %{account: account, provider: provider} do
      stranger = Fixtures.Users.create_user()
      audit = &Emisar.Audit.Events.membership_renamed_via_scim(&1, provider, "Nobody")

      assert Accounts.sync_member_display_name(account.id, stranger.id, "Nobody", audit: audit) ==
               {:error, :not_found}
    end
  end

  describe "member_display_name/2" do
    test "the directory-synced membership name wins over the user's own" do
      user = %User{full_name: "Global Name", email: "person@example.com"}
      membership = %Membership{directory_display_name: "Directory Name"}

      assert Accounts.member_display_name(membership, user) == "Directory Name"
    end

    test "a current member without a directory name uses their own full name" do
      user = %User{full_name: "Own Name", email: "person@example.com"}

      assert Accounts.member_display_name(%Membership{}, user) == "Own Name"
      assert Accounts.member_display_name(nil, user) == "person@example.com"
    end

    test "a blank or absent full name falls back to the email" do
      blank = %User{full_name: "  ", email: "blank@example.com"}
      unnamed = %User{full_name: nil, email: "unnamed@example.com"}

      assert Accounts.member_display_name(nil, blank) == "blank@example.com"
      assert Accounts.member_display_name(nil, unnamed) == "unnamed@example.com"
    end
  end

  describe "user_display_name/1" do
    test "uses a nonblank full name and falls back to email" do
      named = %User{full_name: "Maya Chen", email: "maya@example.com"}
      blank = %User{full_name: "  ", email: "blank@example.com"}
      unnamed = %User{full_name: nil, email: "unnamed@example.com"}

      assert Accounts.user_display_name(named) == "Maya Chen"
      assert Accounts.user_display_name(blank) == "blank@example.com"
      assert Accounts.user_display_name(unnamed) == "unnamed@example.com"
      assert Accounts.user_display_name(%{}) == nil
    end
  end

  describe "secondary_user_email/1" do
    test "returns an email only when the primary display name differs" do
      named = %User{full_name: "Maya Chen", email: "maya@example.com"}
      unnamed = %User{full_name: nil, email: "unnamed@example.com"}

      assert Accounts.secondary_user_email(named) == "maya@example.com"
      assert Accounts.secondary_user_email(unnamed) == nil
      assert Accounts.secondary_user_email(%{}) == nil
    end
  end

  describe "user_labels_for_ids/2" do
    test "returns deduplicated account-local labels and skips non-members" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      named = Fixtures.Users.create_user(full_name: "Maya Chen")
      unnamed = Fixtures.Users.create_user(full_name: nil)
      outsider = Fixtures.Users.create_user(full_name: "Not A Member")

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: named.id)

      _other_membership =
        Fixtures.Memberships.create_membership(account_id: other_account.id, user_id: named.id)

      _unnamed_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: unnamed.id)

      _membership = Fixtures.Memberships.sync_display_name(membership, "Directory Maya")

      ids = [named.id, unnamed.id, outsider.id, nil, named.id]

      assert Accounts.user_labels_for_ids(ids, account.id) == %{
               named.id => "Directory Maya",
               unnamed.id => unnamed.email
             }

      assert Accounts.user_labels_for_ids([], account.id) == %{}
    end
  end

  describe "list_active_memberships_for_user/1" do
    test "returns one membership per account the user actively belongs to" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      account_ids =
        user
        |> Accounts.list_active_memberships_for_user()
        |> Enum.map(& &1.account_id)
        |> Enum.sort()

      assert account_ids == Enum.sort([account_a.id, account_b.id])
    end

    test "returns [] for a user with no memberships" do
      user = Fixtures.Users.create_user()

      assert Accounts.list_active_memberships_for_user(user) == []
    end
  end

  describe "fetch_and_lock_active_memberships_for_user/2" do
    test "returns the same rows as the unlocked read" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      assert {:ok, memberships} = Accounts.fetch_and_lock_active_memberships_for_user(user, Repo)

      assert Enum.map(memberships, & &1.account_id) |> Enum.sort() ==
               Enum.sort([account_a.id, account_b.id])
    end

    test "includes a disabled membership in what it locks" do
      # It returns only ACTIVE memberships, but it has to LOCK the disabled ones
      # too: a membership disabled in another account can be reinstated
      # concurrently, and filtering before the lock left exactly that row unheld.
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)

      disabled =
        Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      Fixtures.Memberships.suspend_membership(disabled)

      assert {:ok, memberships} = Accounts.fetch_and_lock_active_memberships_for_user(user, Repo)

      assert Enum.map(memberships, & &1.account_id) == [account_a.id]
    end

    test "takes a row lock, which is the whole reason it exists" do
      # The SSO link approval decides whether an approver outranks the person they
      # are binding a credential to. An unlocked read makes that decision on rows a
      # concurrent promotion can change before the binding commits — so the lock is
      # the behaviour, and it is asserted where a race cannot be staged reliably.
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {sql, _params} =
        Ecto.Adapters.SQL.to_sql(
          :all,
          Repo,
          Membership.Query.not_deleted()
          |> Membership.Query.by_user_id(user.id)
          |> Membership.Query.not_disabled()
          |> Membership.Query.lock_for_update()
        )

      assert sql =~ "FOR NO KEY UPDATE"
    end
  end

  describe "provision_sso_membership/5" do
    test "creates a membership at the given role for a JIT-provisioned user" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert {:ok, %Membership{role: :operator} = membership} =
               Accounts.provision_sso_membership(
                 account.id,
                 user.id,
                 :operator,
                 Accounts.RunnerAccess.none(),
                 directory_managed?: false
               )

      assert membership.account_id == account.id
      assert membership.user_id == user.id
      assert membership.runner_access_mode == :none
      refute membership.runner_access_directory_managed
    end

    test "refuses :owner — owner is never assignable via sync (defense in depth)" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert Accounts.provision_sso_membership(
               account.id,
               user.id,
               :owner,
               Accounts.RunnerAccess.none(),
               directory_managed?: true
             ) ==
               {:error, :owner_not_assignable}

      # Nothing was written — the user has no membership in the account.
      assert is_nil(Fixtures.Memberships.fetch_membership(account.id, user.id))
    end
  end

  describe "peek_active_membership/2" do
    test "returns the membership when it is active (not deleted, not disabled)" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      assert %Membership{id: id} = Accounts.peek_active_membership(account.id, member.id)
      assert id == member.id
    end

    test "returns nil when the membership is suspended (the engine halts mid-run)" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(member, owner_subject)

      assert is_nil(Accounts.peek_active_membership(account.id, member.id))
    end

    test "returns nil when the membership is soft-deleted" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.mark_membership_as_deleted(member)

      assert is_nil(Accounts.peek_active_membership(account.id, member.id))
    end

    test "returns nil when the membership belongs to a different account (account-scoped)" do
      member = Fixtures.Memberships.create_membership()
      other_account = Fixtures.Accounts.create_account()

      assert is_nil(Accounts.peek_active_membership(other_account.id, member.id))
    end

    test "returns nil for non-binary args (the guard's fallback clause)" do
      assert is_nil(Accounts.peek_active_membership(nil, nil))
    end
  end

  describe "peek_sync_membership/2" do
    test "returns the membership joining the account + user" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert %Membership{id: id} = Accounts.peek_sync_membership(account.id, user.id)
      assert id == member.id
    end

    test "returns a deprovisioned (disabled) row too — a SCIM reconcile reads it back" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(member, owner_subject)

      # peek_sync_membership ignores disabled_at — a deprovisioned member still
      # has a row the reconcile must resolve.
      assert %Membership{disabled_at: %DateTime{}} =
               Accounts.peek_sync_membership(account.id, user.id)
    end

    test "returns nil when there is no membership for the pair" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert is_nil(Accounts.peek_sync_membership(account.id, user.id))
    end
  end

  describe "list_sync_memberships/2" do
    test "returns the memberships for the requested set of users in one query" do
      account = Fixtures.Accounts.create_account()
      user_one = Fixtures.Users.create_user()
      user_two = Fixtures.Users.create_user()
      user_three = Fixtures.Users.create_user()

      membership_one =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_one.id)

      membership_two =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_two.id)

      _membership_three =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_three.id)

      memberships = Accounts.list_sync_memberships(account.id, [user_one.id, user_two.id])

      ids = memberships |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([membership_one.id, membership_two.id])
    end

    test "is scoped to the account — a same-user membership in another account is excluded" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _membership_a =
        Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)

      _membership_b =
        Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      memberships = Accounts.list_sync_memberships(account_a.id, [user.id])

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "returns an empty list when no user matches" do
      account = Fixtures.Accounts.create_account()

      assert Accounts.list_sync_memberships(account.id, [Ecto.UUID.generate()]) == []
    end
  end

  describe "fetch_membership_for_session/2" do
    setup do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      %{
        user: user,
        account: account
      }
    end

    test "with no account_id, returns the most-recent non-disabled membership", %{
      user: user,
      account: first_account
    } do
      second_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      second_membership =
        Fixtures.Memberships.create_membership(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} = Accounts.fetch_membership_for_session(user, nil)
      assert id == second_membership.id
    end

    test "with a matching account_id, returns that specific membership even if older" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      second_account = Fixtures.Accounts.create_account()

      first_membership =
        Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      Fixtures.Memberships.create_membership(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = account}} =
               Accounts.fetch_membership_for_session(user, first_account.id)

      assert id == first_membership.id
      assert account.id == first_account.id
    end

    test "with a stale or unknown account_id, falls back to the primary" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, Ecto.UUID.generate())

      assert returned_account_id == first_account.id
    end

    test "with a suspended membership on the requested account, falls back" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      second_account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), second_account)

      second_membership =
        Fixtures.Memberships.create_membership(
          account_id: second_account.id,
          user_id: user.id,
          role: "operator"
        )

      assert {:ok, _} = Accounts.suspend_membership(second_membership, owner_subject)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, second_account.id)

      refute returned_account_id == second_account.id
    end

    test "returns :not_found for a user with no memberships" do
      assert Accounts.fetch_membership_for_session(Fixtures.Users.create_user(), nil) ==
               {:error, :not_found}
    end
  end

  describe "fetch_membership_by_account_id_or_slug/2" do
    test "resolves the user's membership by the account slug" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = resolved, user: %User{}}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.slug)

      assert id == membership.id
      assert resolved.id == account.id
    end

    test "resolves by the account id too (the UUID form for API/SSO/redirects)" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.id)

      assert id == membership.id
    end

    test "a non-member's slug is indistinguishable from an unknown one (404, never a leak)" do
      member = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      outsider = Fixtures.Users.create_user()

      # The account exists, but the outsider isn't a member: SAME :not_found as
      # a slug no account has — so a URL never confirms a tenant exists (404, not 403).
      assert Accounts.fetch_membership_by_account_id_or_slug(outsider, account.slug) ==
               {:error, :not_found}

      assert Accounts.fetch_membership_by_account_id_or_slug(outsider, "no-such-team") ==
               {:error, :not_found}
    end

    test "a member of account A cannot resolve account B (cross-account, by slug or id)" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)

      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        user_id: Fixtures.Users.create_user().id
      )

      assert Accounts.fetch_membership_by_account_id_or_slug(user, account_b.slug) ==
               {:error, :not_found}

      assert Accounts.fetch_membership_by_account_id_or_slug(user, account_b.id) ==
               {:error, :not_found}
    end

    test "a suspended membership does not resolve" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      assert {:ok, _} = Accounts.suspend_membership(membership, owner_subject)

      assert Accounts.fetch_membership_by_account_id_or_slug(user, account.slug) ==
               {:error, :not_found}
    end
  end

  describe "fetch_post_auth_membership/2" do
    test "resolves a live membership on a DISABLED account, with the account preloaded" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      Fixtures.Accounts.disable_account(account)

      assert {:ok, %Membership{id: id, account: %Account{} = resolved}} =
               Accounts.fetch_post_auth_membership(user, account.slug)

      assert id == membership.id
      assert resolved.id == account.id
      assert %DateTime{} = resolved.disabled_at
    end

    test "resolves by the account id too (the UUID form for API/SSO/redirects)" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} = Accounts.fetch_post_auth_membership(user, account.id)
      assert id == membership.id
    end

    test "a non-member's ref is indistinguishable from an unknown one" do
      member = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      outsider = Fixtures.Users.create_user()

      assert Accounts.fetch_post_auth_membership(outsider, account.slug) == {:error, :not_found}
      assert Accounts.fetch_post_auth_membership(outsider, account.id) == {:error, :not_found}
      assert Accounts.fetch_post_auth_membership(outsider, "no-such-team") == {:error, :not_found}
    end

    test "a suspended or tombstoned membership does not resolve" do
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

      assert Accounts.fetch_post_auth_membership(suspended_user, account.slug) ==
               {:error, :not_found}

      assert Accounts.fetch_post_auth_membership(deleted_user, account.slug) ==
               {:error, :not_found}
    end

    test "a soft-deleted account does not resolve, by slug or id" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Accounts.fetch_post_auth_membership(user, account.slug) == {:error, :not_found}
      assert Accounts.fetch_post_auth_membership(user, account.id) == {:error, :not_found}
    end
  end

  describe "switch_account/2" do
    setup do
      user = Fixtures.Users.create_user()
      current_account = Fixtures.Accounts.create_account()
      target_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: current_account.id,
        user_id: user.id,
        role: "owner"
      )

      %{user: user, current_account: current_account, target_account: target_account}
    end

    test "returns the target membership and audits the switch on the target account", %{
      user: user,
      current_account: current_account,
      target_account: target_account
    } do
      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: target_account.id,
          user_id: user.id,
          role: "operator"
        )

      context = %RequestContext{ip_address: "203.0.113.7", user_agent: "Mozilla/5.0"}

      subject =
        Fixtures.Subjects.subject_for(user, current_account,
          context: context,
          auth_method: :magic_link,
          mfa: true
        )

      target_membership_id = target_membership.id
      target_account_id = target_account.id

      assert {:ok, %Membership{id: ^target_membership_id} = switched} =
               Accounts.switch_account(target_account.id, subject)

      assert %Account{id: ^target_account_id} = switched.account
      assert %User{} = switched.user

      event =
        AuditEvent.Query.all()
        |> AuditEvent.Query.by_account_id(target_account.id)
        |> Repo.one()

      assert event.event_type == "session.account_switched"
      assert event.actor_kind == "user"
      assert event.actor_id == user.id
      assert event.target_kind == "user"
      assert event.target_id == user.id
      assert event.target_label == user.email
      assert event.payload["role"] == "operator"
      assert event.ip_address == "203.0.113.7"
      assert event.auth_method == "magic_link"
      assert event.mfa
    end

    test "a subject without the view-own-account permission is rejected", %{
      user: user,
      target_account: target_account
    } do
      Fixtures.Memberships.create_membership(account_id: target_account.id, user_id: user.id)
      subject = Fixtures.Subjects.build_subject(user: user)

      assert Accounts.switch_account(target_account.id, subject) == {:error, :unauthorized}

      refute AuditEvent.Query.all()
             |> AuditEvent.Query.by_account_id(target_account.id)
             |> Repo.one()
    end

    test "a user who is not a member of the target account cannot switch into it", %{
      user: user,
      current_account: current_account,
      target_account: target_account
    } do
      Fixtures.Memberships.create_membership(account_id: target_account.id)
      subject = Fixtures.Subjects.subject_for(user, current_account)

      assert Accounts.switch_account(target_account.id, subject) == {:error, :not_found}

      refute AuditEvent.Query.all()
             |> AuditEvent.Query.by_account_id(target_account.id)
             |> Repo.one()
    end

    test "a suspended membership on the target account cannot be switched into", %{
      user: user,
      current_account: current_account,
      target_account: target_account
    } do
      target_membership =
        Fixtures.Memberships.create_membership(account_id: target_account.id, user_id: user.id)

      Fixtures.Memberships.suspend_membership(target_membership)
      subject = Fixtures.Subjects.subject_for(user, current_account)

      assert Accounts.switch_account(target_account.id, subject) == {:error, :not_found}

      refute AuditEvent.Query.all()
             |> AuditEvent.Query.by_account_id(target_account.id)
             |> Repo.one()
    end

    test "a malformed account id is rejected before any audit is written", %{
      user: user,
      current_account: current_account
    } do
      subject = Fixtures.Subjects.subject_for(user, current_account)

      assert Accounts.switch_account("not-a-uuid", subject) == {:error, :not_found}

      refute AuditEvent.Query.all()
             |> AuditEvent.Query.by_event_type("session.account_switched")
             |> Repo.one()
    end
  end

  describe "membership_disabled?/1" do
    test "is true only once the membership has been suspended" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      refute Accounts.membership_disabled?(membership)

      assert {:ok, suspended} = Accounts.suspend_membership(membership, owner_subject)
      assert Accounts.membership_disabled?(suspended)
    end
  end

  describe "all_memberships_suspended?/1" do
    test "is true when every membership the user holds is suspended" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(membership, owner_subject)

      assert Accounts.all_memberships_suspended?(user)
    end

    test "is false when at least one membership is still active" do
      user = Fixtures.Users.create_user()
      live_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: live_account.id, user_id: user.id)

      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      suspended =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(suspended, owner_subject)

      # One active membership remains → not "all suspended".
      refute Accounts.all_memberships_suspended?(user)
    end

    test "is false when the user has NO memberships (distinct from 'all suspended')" do
      # The UI distinguishes "your access was suspended" from "go to onboarding";
      # a user with zero memberships is the latter, so this must be false.
      user = Fixtures.Users.create_user()

      refute Accounts.all_memberships_suspended?(user)
    end
  end

  describe "update_membership_role/3" do
    test "the last active owner can't demote themselves; with a second owner it works" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      # Sole owner — the in-transaction guard (locked re-count of the
      # account's active owner rows) refuses the demotion.
      assert Accounts.update_membership_role(owner_membership, "admin", subject) ==
               {:error, :last_owner}

      # A second active owner frees the demotion.
      second_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: second_owner.id,
        role: "owner"
      )

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(owner_membership, "admin", subject)
    end

    test "demoting a member revokes the API keys they minted" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: admin.id)

      # Re-applying the same role is a no-op (a SCIM reconcile does this), so
      # the delegation survives.
      assert {:ok, unchanged} =
               Accounts.update_membership_role(admin_membership, "admin", subject)

      assert is_nil(Repo.reload!(key).revoked_at)

      # A demotion is the same loss of standing as suspension. Without this the
      # key keeps its fixed :api_client role — which always holds dispatch_run —
      # so a demoted admin's MCP bridge would still reach the whole fleet.
      assert {:ok, _} = Accounts.update_membership_role(unchanged, "viewer", subject)
      refute is_nil(Repo.reload!(key).revoked_at)
    end

    test "a member without manage_team permission cannot change a role" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      operator = Fixtures.Users.create_user()

      operator_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      target_membership = Fixtures.Memberships.create_membership(account_id: account.id)
      subject = Fixtures.Subjects.membership_subject(operator_membership)

      assert Accounts.update_membership_role(target_membership, "admin", subject) ==
               {:error, :unauthorized}
    end

    test "promotes operator to admin" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(target_membership, "admin", subject)
    end

    test "rejects an unknown role" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:error, changeset} =
               Accounts.update_membership_role(target_membership, "supreme-leader", subject)

      assert "is invalid" in errors_on(changeset).role
    end

    test "an admin cannot grant the owner role (no escalation by proxy)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.update_membership_role(target_membership, "owner", subject) ==
               {:error, :insufficient_privileges}
    end

    test "an admin cannot demote an owner (can't outrank a superior)" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.update_membership_role(owner_membership, "operator", subject) ==
               {:error, :insufficient_privileges}
    end

    test "you cannot promote yourself" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.update_membership_role(admin_membership, "owner", subject) ==
               {:error, :cannot_self_promote}
    end

    test "an owner can grant the owner role" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :owner}} =
               Accounts.update_membership_role(target_membership, "owner", subject)
    end

    test "a scoped admin promotes a member whose access their own covers" do
      account = Fixtures.Accounts.create_account()
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      admin_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      Fixtures.Memberships.force_runner_access(admin_membership, db_access)

      target_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      Fixtures.Memberships.force_runner_access(target_membership, db_access)

      subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert {:ok, %Membership{role: :operator}} =
               Accounts.update_membership_role(target_membership, "operator", subject)
    end

    test "a scoped admin can't promote a member whose access exceeds their own" do
      account = Fixtures.Accounts.create_account()
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      admin_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      Fixtures.Memberships.force_runner_access(admin_membership, db_access)

      target_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      Fixtures.Memberships.force_runner_access(target_membership, RunnerAccess.all())

      subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert Accounts.update_membership_role(target_membership, "operator", subject) ==
               {:error, :member_runner_access_exceeds_subject}

      assert %Membership{role: :viewer} =
               Fixtures.Memberships.fetch_membership(account.id, target_membership.user_id)
    end

    test "the cap covers the pack dimension, not only runners" do
      account = Fixtures.Accounts.create_account()
      {:ok, nginx_only} = RunnerAccess.new(:all, [], [], :restricted, ["nginx"])

      admin_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      Fixtures.Memberships.force_runner_access(admin_membership, nginx_only)

      target_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      Fixtures.Memberships.force_runner_access(target_membership, RunnerAccess.all())

      subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert Accounts.update_membership_role(target_membership, "operator", subject) ==
               {:error, :member_runner_access_exceeds_subject}
    end

    test "a scoped admin can still demote a member whose access exceeds their own" do
      account = Fixtures.Accounts.create_account()
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      admin_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      Fixtures.Memberships.force_runner_access(admin_membership, db_access)

      target_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      Fixtures.Memberships.force_runner_access(target_membership, RunnerAccess.all())

      subject = Fixtures.Subjects.membership_subject(admin_membership)

      assert {:ok, %Membership{role: :viewer}} =
               Accounts.update_membership_role(target_membership, "viewer", subject)
    end

    test "the staff break-glass subject promotes with no membership reach to cap" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      Fixtures.Memberships.force_runner_access(target_membership, RunnerAccess.all())

      # `Emisar.Admin.support_subject/1`: owner permissions, no actor and no
      # membership in the account, so it has no member reach the cap could read.
      subject =
        Fixtures.Subjects.build_subject(
          account: account,
          role: :owner,
          permissions: Auth.Permissions.for_role(:owner)
        )

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(target_membership, "admin", subject)
    end

    test "a scoped admin can't promote another account's member (cross-account)" do
      account = Fixtures.Accounts.create_account()
      {:ok, db_access} = RunnerAccess.restricted(["db"], [])

      admin_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

      Fixtures.Memberships.force_runner_access(admin_membership, db_access)

      other_account = Fixtures.Accounts.create_account()

      other_membership =
        Fixtures.Memberships.create_membership(account_id: other_account.id, role: "viewer")

      Fixtures.Memberships.force_runner_access(other_membership, db_access)

      subject = Fixtures.Subjects.membership_subject(admin_membership)

      # The account gate fires before the reach cap, so a member the actor could
      # otherwise promote is still refused for being in another account.
      assert Accounts.update_membership_role(other_membership, "operator", subject) ==
               {:error, :unauthorized}

      assert %Membership{role: :viewer} =
               Fixtures.Memberships.fetch_membership(other_account.id, other_membership.user_id)
    end

    test "an owner of another account can't change this member's role (cross-account)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # `ensure_subject_in_account` (passed :unauthorized) fires before the
      # `for_subject`-scoped row read, so the cross-account mutation is refused
      # without touching A's row.
      assert Accounts.update_membership_role(target_membership, "admin", subject_b) ==
               {:error, :unauthorized}

      # A's membership is untouched — still operator.
      assert %Membership{role: :operator} =
               Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end
  end

  describe "subscribe_account_team/1" do
    test "the subscriber receives the account's team-list broadcasts" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Accounts.subscribe_account_team(account.id) == :ok

      # A team mutation publishes on the topic the subscriber just joined.
      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)
      assert_receive {:list_changed, :team, "membership.suspended", user_id}, 500
      assert user_id == target.user_id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      owner_subject_b = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_b)

      target_b =
        Fixtures.Memberships.create_membership(account_id: account_b.id, role: "operator")

      assert Accounts.subscribe_account_team(account_a.id) == :ok

      # The mutation happens on B's topic — A's subscriber must hear nothing.
      assert {:ok, _} = Accounts.suspend_membership(target_b, owner_subject_b)
      refute_receive {:list_changed, :team, _event, _user_id}
    end
  end

  describe "suspend_membership/2 + reinstate_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      {:ok, account: account, owner: owner, target: target, owner_subject: owner_subject}
    end

    test "owner can suspend an operator and reinstate", %{
      owner: owner,
      target: target,
      owner_subject: owner_subject
    } do
      assert {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      assert Membership.disabled?(suspended)
      assert suspended.disabled_by_id == owner.id
      assert Repo.reload!(target).disabled_by_id == owner.id

      assert {:ok, reinstated} = Accounts.reinstate_membership(suspended, owner_subject)
      refute Membership.disabled?(reinstated)
      assert is_nil(reinstated.disabled_by_id)
      assert is_nil(Repo.reload!(target).disabled_by_id)
    end

    test "suspending a member revokes the API keys they minted", %{
      account: account,
      owner_subject: owner_subject
    } do
      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: admin.id)

      assert is_nil(Emisar.Repo.reload!(key).revoked_at)

      assert {:ok, _} = Accounts.suspend_membership(admin_membership, owner_subject)

      # after_commit revokes the keys the suspended member minted so they
      # can't keep dispatching via MCP / OAuth after losing access.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "operator cannot suspend anyone", %{account: account, target: target} do
      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Accounts.suspend_membership(target, operator_subject) == {:error, :unauthorized}
    end

    test "a repeated suspension keeps the seat and the first hold provenance", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      # Owner + target = 2 seats before; suspension preserves the role + history
      # for reinstate, so it must NOT free the seat (only a soft-delete removal
      # does — see delete_membership).
      assert Accounts.count_memberships(account.id) == 2

      assert {:ok, first} = Accounts.suspend_membership(target, owner_subject)
      :ok = Accounts.subscribe_account_team(account.id)
      assert {:ok, repeated} = Accounts.suspend_membership(target, owner_subject)

      assert Accounts.count_memberships(account.id) == 2
      assert repeated.disabled_at == first.disabled_at
      assert repeated.disabled_by_id == first.disabled_by_id
      assert Membership.disabled?(Repo.reload!(target))
      assert length(Repo.all(Emisar.Audit.Event)) == 1
      refute_receive {:list_changed, :team, "membership.suspended", _user_id}
    end

    test "can't suspend yourself", %{owner: owner, account: account, owner_subject: owner_subject} do
      owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert Accounts.suspend_membership(owner_membership, owner_subject) ==
               {:error, :cannot_modify_self}
    end

    test "can't suspend the last owner", %{
      owner: owner,
      account: account,
      owner_subject: owner_subject
    } do
      owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      # Promote another owner so the actor isn't the only one — then
      # the second owner suspends the first.
      second_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: second_owner.id,
        role: "owner"
      )

      second_owner_subject = Fixtures.Subjects.subject_for(second_owner, account, role: :owner)
      assert {:ok, _} = Accounts.suspend_membership(owner_membership, second_owner_subject)

      # Now `second_owner` is the last ACTIVE owner — can't be suspended.
      # (The first owner's Subject still carries owner permissions at the
      # context layer — suspension is enforced by killing their session at
      # the web layer — so it can drive this attempt.)
      second_owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, second_owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert Accounts.suspend_membership(second_owner_membership, owner_subject) ==
               {:error, :last_owner}

      # Reinstating the first owner makes the second suspendable again —
      # and pins that reinstate REALLY clears the row (a stale-struct
      # reinstate used to silently no-op).
      {:ok, _} = Accounts.reinstate_membership(owner_membership, second_owner_subject)

      assert {:ok, _} =
               Accounts.suspend_membership(second_owner_membership, owner_subject)
    end

    test "suspended membership is excluded from fetch_membership_for_session/2", %{
      target: target,
      owner_subject: owner_subject
    } do
      target_user = Emisar.Repo.preload(target, :user).user
      assert {:ok, %Membership{}} = Accounts.fetch_membership_for_session(target_user, nil)

      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)
      assert Accounts.fetch_membership_for_session(target_user, nil) == {:error, :not_found}
      assert Accounts.all_memberships_suspended?(target_user)
    end

    test "an owner of another account can't suspend this member (cross-account)", %{
      account: account,
      target: target
    } do
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.suspend_membership(target, subject_b) == {:error, :unauthorized}

      refute Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )

      assert is_nil(Repo.reload!(target).disabled_by_id)
    end

    test "a human retry cannot claim a directory-owned suspension", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      provider = provider_fixture(account)
      assert {:ok, directory_suspended, true} = Accounts.sync_suspend_membership(target, provider)
      assert directory_suspended.directory_suspended
      assert is_nil(directory_suspended.disabled_by_id)

      assert {:ok, unchanged} = Accounts.suspend_membership(directory_suspended, owner_subject)
      assert unchanged.disabled_at == directory_suspended.disabled_at
      assert unchanged.directory_suspended
      assert is_nil(unchanged.disabled_by_id)
      assert length(Repo.all(Emisar.Audit.Event)) == 1
    end

    test "operator cannot reinstate anyone", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      # Suspend as owner first so there's a disabled row to reinstate; reinstate
      # shares suspend's manage_team gate, so a non-manager is refused — and the
      # row stays disabled.
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)

      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Accounts.reinstate_membership(suspended, operator_subject) == {:error, :unauthorized}

      assert Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )
    end

    test "an owner of another account can't reinstate this member (cross-account)", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # :unauthorized (not :not_found) — accounts gates struct-taking writes with
      # ensure_subject_in_account(:unauthorized) before the for_subject fetch, so
      # account B is refused and the member stays suspended in account A.
      assert Accounts.reinstate_membership(suspended, subject_b) == {:error, :unauthorized}

      assert Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )
    end
  end

  describe "reinstate_membership/2" do
    test "reinstating clears disabled_at and broadcasts the reinstate" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      assert Membership.disabled?(suspended)

      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, reinstated} = Accounts.reinstate_membership(suspended, owner_subject)
      refute Membership.disabled?(reinstated)
      assert is_nil(Repo.reload!(target).disabled_at)

      assert_receive {:list_changed, :team, "membership.reinstated", user_id}, 500
      assert user_id == target.user_id
    end

    test "an owner of another account can't reinstate this member (cross-account)" do
      account_a = Fixtures.Accounts.create_account()
      owner_subject_a = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_a)
      target = Fixtures.Memberships.create_membership(account_id: account_a.id, role: "operator")
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject_a)

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.reinstate_membership(suspended, subject_b) == {:error, :unauthorized}
      assert Membership.disabled?(Repo.reload!(target))
    end
  end

  describe "sync_suspend_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "suspends a member the IdP deprovisioned (disabled_at set, attributed to the provider)",
         %{account: account, provider: provider} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{} = suspended, true} =
               Accounts.sync_suspend_membership(member, provider)

      assert Membership.disabled?(suspended)
      assert is_nil(suspended.disabled_by_id)
      assert Membership.disabled?(Repo.reload!(member))
    end

    test "records WHICH connection placed the hold, not just that one did", %{
      account: account,
      provider: provider
    } do
      # An account can run several connections, and a person can hold an identity
      # on each. Only the one that deactivated them may lift the hold, so the
      # attribution has to be exact — a backfill migration guessed it from a join
      # that could match two identities, and a misattributed suspension leaves the
      # right connection unable to reactivate and a wrong one able to.
      other = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{} = suspended, true} =
               Accounts.sync_suspend_membership(member, provider)

      assert suspended.directory_provider_id == provider.id
      assert suspended.directory_suspended
      refute suspended.directory_provider_id == other.id
    end

    test "the last-active-owner guard still fires — a deprovision can't lock out the account",
         %{account: account, provider: provider} do
      sole_owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      assert Accounts.sync_suspend_membership(sole_owner, provider) == {:error, :last_owner}
      refute Membership.disabled?(Repo.reload!(sole_owner))
    end

    test "rejects a membership outside the provider's account (the write-path backstop)", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert Accounts.sync_suspend_membership(other, provider) == {:error, :not_found}
      assert is_nil(Repo.reload!(other).disabled_at)
    end

    test "never takes ownership of a manual break-glass suspension (no-op, provenance stays manual)",
         %{account: account, provider: provider} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      suspended = Fixtures.Memberships.suspend_membership(member)

      assert {:ok, %Membership{} = returned, false} =
               Accounts.sync_suspend_membership(suspended, provider)

      assert Membership.disabled?(returned)
      refute returned.directory_suspended
      refute Repo.reload!(member).directory_suspended
      # No write committed — so no deprovision audit row either.
      assert Repo.all(Emisar.Audit.Event) == []
    end

    test "is idempotent — re-deactivating an already directory-suspended member is a no-op", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended, true} = Accounts.sync_suspend_membership(member, provider)

      assert {:ok, %Membership{} = returned, false} =
               Accounts.sync_suspend_membership(suspended, provider)

      assert Membership.disabled?(returned)
      assert returned.directory_suspended
    end
  end

  describe "membership_suspended_effects/1" do
    test "broadcasts the suspension and revokes the member's API keys" do
      account = Fixtures.Accounts.create_account()
      member_user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member_user.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member_user.id)

      assert is_nil(Repo.reload!(key).revoked_at)
      :ok = Accounts.subscribe_account_team(account.id)

      assert Accounts.membership_suspended_effects(member) == :ok

      member_user_id = member_user.id
      assert_receive {:list_changed, :team, "membership.suspended", ^member_user_id}
      refute is_nil(Repo.reload!(key).revoked_at)
    end
  end

  describe "sync_reinstate_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "reinstates a member the IdP re-provisioned (clears disabled_at)", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended, true} = Accounts.sync_suspend_membership(member, provider)
      assert Membership.disabled?(suspended)

      assert {:ok, %Membership{} = reinstated, true} =
               Accounts.sync_reinstate_membership(suspended, provider)

      refute Membership.disabled?(reinstated)
      assert is_nil(Repo.reload!(member).disabled_at)
    end

    test "rejects a membership outside the provider's account", %{provider: provider} do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert Accounts.sync_reinstate_membership(other, provider) == {:error, :not_found}
    end

    test "a manually-suspended member stays suspended — the IdP can't lift a local break-glass hold",
         %{account: account, provider: provider} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      suspended = Fixtures.Memberships.suspend_membership(member)

      assert {:ok, %Membership{} = returned, false} =
               Accounts.sync_reinstate_membership(suspended, provider)

      assert Membership.disabled?(returned)
      assert Membership.disabled?(Repo.reload!(member))
    end

    test "a second connection can't lift the suspension the first one placed", %{
      account: account,
      provider: provider
    } do
      # An account can run more than one connection. The other directory saying
      # "active" is news about ITS directory, not this one's, and letting it
      # through reinstated someone the owning directory had deprovisioned.
      # A different kind — an account runs at most one enabled connection per kind.
      other_provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)

      user = Fixtures.Users.create_user()

      {:ok, member} =
        Accounts.provision_sso_membership(
          account.id,
          user.id,
          :operator,
          Accounts.RunnerAccess.none(),
          directory_managed?: true,
          directory_provider: provider
        )

      {:ok, suspended, true} = Accounts.sync_suspend_membership(member, provider)

      assert {:ok, %Membership{} = returned, false} =
               Accounts.sync_reinstate_membership(suspended, other_provider)

      assert Membership.disabled?(returned)
      assert Membership.disabled?(Repo.reload!(member))

      # The connection that placed it still can.
      assert {:ok, %Membership{} = reinstated, true} =
               Accounts.sync_reinstate_membership(suspended, provider)

      refute Membership.disabled?(reinstated)
    end

    test "is idempotent — reactivating a not-suspended member is a no-op", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{} = returned, false} =
               Accounts.sync_reinstate_membership(member, provider)

      refute Membership.disabled?(returned)
      refute Membership.disabled?(Repo.reload!(member))
    end
  end

  describe "put_sync_membership_lifecycle/4" do
    test "composes the lifecycle audit for the outer commit to broadcast" do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      :ok = Audit.subscribe_account_audit(account.id)

      assert {:ok,
              %{
                lifecycle_audit: %AuditEvent{
                  event_type: "membership.deprovisioned_via_scim"
                },
                membership_transition: %{
                  effect: {:suspended, %Membership{disabled_at: %DateTime{}}}
                }
              }} =
               Multi.new()
               |> Accounts.put_sync_membership_lifecycle(member, provider, :suspend)
               |> Repo.commit_multi()

      assert_receive {:audit_event, %AuditEvent{event_type: "membership.deprovisioned_via_scim"}}
    end
  end

  describe "membership_reinstated_effects/1" do
    test "broadcasts the reinstatement to the team page" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      :ok = Accounts.subscribe_account_team(account.id)

      assert Accounts.membership_reinstated_effects(member) == :ok

      member_user_id = member.user_id
      assert_receive {:list_changed, :team, "membership.reinstated", ^member_user_id}
    end
  end

  describe "sync_set_membership_authorization/4" do
    test "persists a directory role and runner grant together" do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      {:ok, access} = RunnerAccess.restricted(["operations"], [])

      assert {:ok, %Membership{role: :operator} = updated} =
               Accounts.sync_set_membership_authorization(
                 member,
                 :operator,
                 access,
                 provider
               )

      assert updated.directory_provider_id == provider.id
      assert Accounts.runner_access_for_membership(account.id, member.id) == access
    end
  end

  describe "put_sync_membership_authorization/5" do
    test "composes into an outer transaction whose later failure rolls every write back" do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      {:ok, access} = RunnerAccess.restricted(["operations"], [])
      before_access = Accounts.runner_access_for_membership(account.id, member.id)

      result =
        Multi.new()
        |> Accounts.put_sync_membership_authorization(member, :operator, access, provider)
        |> Multi.error(:forced_failure, :forced_rollback)
        |> Repo.commit_multi()

      assert result == {:error, :forced_rollback}
      assert Repo.reload!(member).role == :viewer
      assert Accounts.runner_access_for_membership(account.id, member.id) == before_access

      refute AuditEvent.Query.all()
             |> AuditEvent.Query.by_account_id(account.id)
             |> AuditEvent.Query.only_event_types([
               "membership.role_synced_via_scim",
               "membership.runner_access_synced_via_scim"
             ])
             |> Repo.exists?()
    end
  end

  describe "after_sync_membership_authorization_committed/1" do
    test "fires the composed transition's team notification only after the caller commits" do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      {:ok, access} = RunnerAccess.restricted(["operations"], [])
      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, changes} =
               Multi.new()
               |> Accounts.put_sync_membership_authorization(
                 member,
                 :operator,
                 access,
                 provider
               )
               |> Repo.commit_multi()

      refute_receive {:list_changed, :team, "membership.role_changed", _user_id}
      assert Accounts.after_sync_membership_authorization_committed(changes) == :ok

      member_user_id = member.user_id

      assert_receive {:list_changed, :team, "membership.role_changed", ^member_user_id}
    end
  end

  describe "sync_set_membership_role/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "sets the member's role from their mapped IdP groups", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:ok, %Membership{role: :operator}} =
               Accounts.sync_set_membership_role(member, :operator, provider)

      assert Repo.reload!(member).role == :operator
    end

    test "is idempotent — an already-matching role returns {:ok, membership} with no write", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{role: :operator} = returned} =
               Accounts.sync_set_membership_role(member, :operator, provider)

      # The matching-role clause returns the caller's struct without touching the row.
      assert returned.id == member.id
    end

    test "refuses :owner — owner stays a deliberate human grant (defense in depth)", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert Accounts.sync_set_membership_role(member, :owner, provider) ==
               {:error, :owner_not_assignable}

      assert Repo.reload!(member).role == :viewer
    end

    test "never demotes the account's last active owner", %{account: account, provider: provider} do
      sole_owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      assert Accounts.sync_set_membership_role(sole_owner, :admin, provider) ==
               {:error, :last_owner}

      assert Repo.reload!(sole_owner).role == :owner
    end

    test "rejects a membership outside the provider's account", %{provider: provider} do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert Accounts.sync_set_membership_role(other, :admin, provider) == {:error, :not_found}
      assert Repo.reload!(other).role == :operator
    end

    test "rejects an already-synced membership outside the provider's account", %{
      provider: provider
    } do
      other =
        Fixtures.Memberships.create_membership(role: "operator")
        |> Fixtures.Memberships.mark_directory_managed()

      assert Accounts.sync_set_membership_role(other, :operator, provider) == {:error, :not_found}
      assert Repo.reload!(other).directory_managed
    end
  end

  describe "clear_directory_managed_for_users/3" do
    test "an operator can reinstate a member the removed directory had deactivated" do
      # Suspended by a directory that no longer exists: `reinstate_membership`
      # refuses a `directory_suspended` row on the reasoning that only the IdP may
      # lift what the IdP placed, so with the IdP gone the member was suspended
      # permanently, by nobody.
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended, true} = Accounts.sync_suspend_membership(member, provider)

      assert Accounts.reinstate_membership(suspended, subject) == {:error, :deactivated_in_idp}

      Accounts.clear_directory_managed_for_users(account.id, provider.id, [member.user_id])

      # The suspension stands — the directory's last word was that they are out —
      # but it is now an operator's to lift.
      freed = Repo.reload!(member)
      assert Membership.disabled?(freed)
      refute freed.directory_suspended

      assert {:ok, %Membership{} = reinstated} = Accounts.reinstate_membership(freed, subject)
      refute Membership.disabled?(reinstated)
    end

    test "the directory's name goes with the directory" do
      # Left set, this account kept calling the person whatever the IdP called
      # them — forever, since their own profile name can never take over a
      # directory name — so a rename after the disable was permanent.
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      Fixtures.Memberships.mark_directory_managed(member)
      Fixtures.Memberships.sync_display_name(member, "Directory Name")

      Accounts.clear_directory_managed_for_users(account.id, provider.id, [member.user_id])

      refute Repo.reload!(member).directory_display_name
    end

    test "clears the flag only for the named members, leaving other synced members" do
      account = Fixtures.Accounts.create_account()
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      freed = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      Fixtures.Memberships.mark_directory_managed(freed)
      kept = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      Fixtures.Memberships.mark_directory_managed(kept)

      Accounts.clear_directory_managed_for_users(account.id, provider.id, [freed.user_id])

      refute Repo.reload!(freed).directory_managed
      assert Repo.reload!(kept).directory_managed
    end

    test "leaves alone a suspension another connection owns" do
      # Tearing down connection B must not erase the hold connection A placed —
      # otherwise a local admin can reinstate access A still says is revoked.
      account = Fixtures.Accounts.create_account()
      provider_a = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :okta)
      provider_b = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :entra)
      user = Fixtures.Users.create_user()

      {:ok, membership} =
        Accounts.provision_sso_membership(
          account.id,
          user.id,
          :operator,
          Accounts.RunnerAccess.none(),
          directory_managed?: true,
          directory_provider: provider_a
        )

      {:ok, _suspended, true} = Accounts.sync_suspend_membership(membership, provider_a)

      Accounts.clear_directory_managed_for_users(account.id, provider_b.id, [user.id])

      still_held = Repo.reload!(membership)
      assert still_held.directory_suspended
      assert still_held.directory_provider_id == provider_a.id
    end
  end

  describe "reset_member_mfa/2" do
    test "an owner clears a member's MFA + writes the user.mfa_reset_by_admin audit row" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %User{} = updated} = Accounts.reset_member_mfa(target, owner_subject)

      # Every MFA field is wiped — the member can no longer present a factor.
      assert is_nil(updated.mfa_enabled_at)
      assert is_nil(updated.mfa_secret)
      assert updated.mfa_recovery_codes == []

      # And it's persisted, not just on the returned struct.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      assert is_nil(reloaded.mfa_enabled_at)

      events = Emisar.Audit.list_events(owner_subject, page: [limit: 10]) |> elem(1)
      assert Enum.any?(events, &(&1.event_type == "user.mfa_reset_by_admin"))
    end

    test "the reset ends every session the member holds" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      mfa_token =
        Fixtures.Auth.create_session_token!(target_user, :magic_link, DateTime.utc_now())

      plain_token = Fixtures.Auth.create_session_token!(target_user, :magic_link, nil)
      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %User{}} = Accounts.reset_member_mfa(target, owner_subject)

      # A reset is the remediation for a compromised factor, so a cookie the
      # attacker already holds must not outlive it. Stripping its second-factor
      # claim (what `Auth.session_mfa_verified?/2` does on its own) would leave
      # that cookie signed in.
      assert Auth.fetch_user_and_token_by_session_token(mfa_token) == {:error, :not_found}
      assert Auth.fetch_user_and_token_by_session_token(plain_token) == {:error, :not_found}
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert Accounts.reset_member_mfa(target, subject) == {:error, :unauthorized}

      # The member's factor is untouched.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an admin can't reset an owner's MFA (hierarchy)" do
      account = Fixtures.Accounts.create_account()
      owner = enroll_member_mfa(Fixtures.Users.create_user())

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.reset_member_mfa(owner_membership, subject) ==
               {:error, :insufficient_privileges}

      {:ok, reloaded} = Users.fetch_user_by_id(owner.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an owner of another account can't reset this member's MFA (cross-account)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.reset_member_mfa(target, subject_b) == {:error, :unauthorized}

      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end
  end

  describe "update_user_as_admin/3" do
    test "a directory-synced member's profile is refused — the IdP owns the name" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target = Fixtures.Users.create_user(full_name: "Synced Name")

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      provider = account |> provider_fixture() |> Fixtures.SSO.enable_scim()

      external_id = "okta|#{System.unique_integer([:positive])}"

      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: target.id,
        provider_identifier: external_id,
        scim_external_id: external_id,
        created_by: :provider,
        provisioned_via: :scim,
        scim_active: true
      })

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert Accounts.update_user_as_admin(membership, %{"full_name" => "Renamed"}, subject) ==
               {:error, :directory_managed_profile}

      assert Repo.reload!(target).full_name == "Synced Name"
    end

    test "an owner renames a member's profile" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %User{full_name: "Renamed By Admin"}} =
               Accounts.update_user_as_admin(
                 membership,
                 %{"full_name" => "Renamed By Admin"},
                 subject
               )
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject) ==
               {:error, :unauthorized}
    end

    test "an owner of another account can't edit this member (cross-account)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # This path passes :unauthorized to ensure_subject_in_account (the team
      # UI already scoped the membership), so cross-account is :unauthorized.
      assert Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject_b) ==
               {:error, :unauthorized}
    end
  end

  describe "end_all_sessions_for/2" do
    test "an owner force-signs-out a member everywhere" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      token = Fixtures.Auth.create_session_token!(target, :magic_link, nil)
      assert {:ok, %User{}, _auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)

      assert Accounts.end_all_sessions_for(membership, subject) == :ok
      assert Emisar.Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert Accounts.end_all_sessions_for(membership, subject) == {:error, :unauthorized}
    end

    test "an owner of another account can't end this member's sessions (cross-account)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.end_all_sessions_for(membership, subject_b) == {:error, :unauthorized}
    end
  end

  describe "delete_membership/2" do
    test "owner can remove a non-owner member" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{} = removed} = Accounts.delete_membership(target, subject)

      # Removal is a soft delete: the tombstone keeps history while every
      # not_deleted() read treats the member as gone.
      assert removed.deleted_at

      assert Accounts.fetch_membership_for_session(target_user, account.id) ==
               {:error, :not_found}
    end

    test "the last active owner cannot be removed" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      subject = Fixtures.Subjects.membership_subject(owner_membership)

      assert Accounts.delete_membership(owner_membership, subject) == {:error, :last_owner}
    end

    test "removing a member revokes the API keys they minted" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      member = Fixtures.Users.create_user()

      member_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member.id)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # Removal revokes minted keys after commit, cutting off MCP / OAuth
      # alongside the member's now-invalidated browser sessions.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "removing a member ends their access here without signing them out elsewhere" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      session_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert {:ok, %User{}, _token} =
               Emisar.Auth.fetch_user_and_token_by_session_token(session_token)

      assert {:ok, _} = Accounts.delete_membership(membership, subject)

      # A session token is a user-level login, not an account credential — the
      # person may belong to other workspaces, and this account has no authority
      # over those. It survives…
      assert {:ok, %User{}, _token} =
               Emisar.Auth.fetch_user_and_token_by_session_token(session_token)

      # …but it no longer resolves this account, which is what ending access means.
      assert Accounts.fetch_membership_for_session(member, account.id) == {:error, :not_found}
    end

    test "a removed member can be re-invited (tombstone doesn't hold the seat)" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert {:ok, %{membership: fresh}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: target_user.email, role: "viewer"),
                 subject
               )

      assert fresh.user_id == target_user.id
      assert fresh.id != target.id
    end

    test "an operator (no manage_team permission) cannot remove a member → :unauthorized" do
      account = Fixtures.Accounts.create_account()
      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "viewer"
        )

      operator = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert Accounts.delete_membership(target, operator_subject) == {:error, :unauthorized}
      # The target membership is still present.
      assert %Membership{} = Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end

    test "an admin cannot remove an owner" do
      account = Fixtures.Accounts.create_account()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.delete_membership(owner_membership, subject) ==
               {:error, :insufficient_privileges}
    end

    test "an owner of another account can't remove this member (cross-account)" do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Accounts.delete_membership(target, subject_b) == {:error, :unauthorized}
      # A's membership survives.
      assert %Membership{} = Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end

    test "a removed member's API key can no longer resolve for dispatch" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      member = Fixtures.Users.create_user()

      member_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {raw, _key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member.id)

      # The key resolves while the member is active — the MCP/OAuth auth boundary.
      assert %Emisar.ApiKeys.ApiKey{} = Emisar.ApiKeys.peek_api_key_by_secret(raw)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # After removal the key is revoked (after_commit), so the credential
      # resolution that precedes building a Subject returns nil — no dispatch.
      assert is_nil(Emisar.ApiKeys.peek_api_key_by_secret(raw))
    end
  end

  describe "invite_user_to_account/2" do
    test "creates a placeholder user for an unknown email" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      assert {:ok,
              %{
                membership: %Membership{role: :admin},
                user: %User{} = invitee,
                invitation_token: token
              }} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: email,
                   role: "admin",
                   runner_access_mode: "all"
                 ),
                 subject
               )

      assert invitee.email == email
      refute invitee.confirmed_at
      assert is_binary(token)
    end

    test "persists selected pack access on the invited membership" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          role: "viewer",
          runner_access_mode: "all",
          pack_access_mode: "restricted",
          pack_scope: ["pack:postgres"]
        )

      assert {:ok, %{membership: membership}} = Accounts.invite_user_to_account(attrs, subject)

      assert Accounts.runner_access_for_membership(account.id, membership.id) ==
               %RunnerAccess{
                 mode: :all,
                 groups: [],
                 runner_ids: [],
                 pack_mode: :restricted,
                 pack_ids: ["postgres"]
               }
    end

    test "a member without invite permission cannot invite a user" do
      account = Fixtures.Accounts.create_account()

      viewer_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      subject = Fixtures.Subjects.membership_subject(viewer_membership)
      email = "denied-invite-#{System.unique_integer([:positive])}@example.test"

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: email,
                 role: "operator",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :unauthorized}
    end

    test "reuses the existing user when one is already registered" do
      inviter = Fixtures.Users.create_user()
      existing = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      assert {:ok, %{user: %User{id: id}}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: existing.email,
                   role: "operator",
                   runner_access_mode: "all"
                 ),
                 subject
               )

      assert id == existing.id
    end

    test "refuses duplicate memberships" do
      inviter = Fixtures.Users.create_user()
      existing = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: existing.id)
      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: existing.email,
                 role: "operator",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :already_member}
    end

    test "an admin cannot invite an owner (can't grant a role it doesn't hold)" do
      admin = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      email = "owner-invite-#{System.unique_integer([:positive])}@example.test"

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: email,
                 role: "owner",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :insufficient_privileges}
    end

    test "seats are uncapped — inviting well past any prior limit always succeeds" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      # Team seats are a deliberate growth lever, not a gate — there is no
      # Billing.check_limit on this path, so a large batch of invites all land.
      for n <- 1..12 do
        email = "seat-#{n}-#{System.unique_integer([:positive])}@example.test"

        assert {:ok, %{membership: %Membership{}}} =
                 Accounts.invite_user_to_account(
                   Fixtures.Accounts.invitation_attrs(
                     email: email,
                     role: "viewer",
                     runner_access_mode: "all"
                   ),
                   subject
                 )
      end

      # All twelve invitees plus the owner are members — none was capped.
      assert Accounts.count_memberships(account.id) == 13
    end

    test "an invite always lands in the SUBJECT's account — B's owner can't seed account A" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      subject_b = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_b)

      email = "cross-#{System.unique_integer([:positive])}@example.test"

      # The membership's account is read off `subject.account`, so B's owner can
      # only ever invite into B — there is no caller-supplied account id to
      # redirect the invite into A.
      assert {:ok, %{membership: %Membership{account_id: account_id}, user: invitee}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 subject_b
               )

      assert account_id == account_b.id
      # And nothing was written into A: the invitee has no membership there.
      assert is_nil(Fixtures.Memberships.fetch_membership(account_a.id, invitee.id))
    end
  end

  describe "invite_user_to_account_and_deliver/3" do
    test "emails the join link and reports it sent, without handing back the token" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      email = "deliver-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, result} =
               Accounts.invite_user_to_account_and_deliver(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 owner,
                 subject
               )

      assert result.delivery == {:ok, :sent}
      assert %Membership{role: :operator} = result.membership
      assert result.user.email == email
      refute Map.has_key?(result, :invitation_token)

      assert_receive {:email, sent}
      assert sent.to == [{"", email}]
      assert sent.subject == "You're invited to #{account.name} on emisar"
      assert sent.text_body =~ "/accept_invitation/"
    end

    test "a suppressed address still gets the invitation, but no email is sent" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      email = "bounced-#{System.unique_integer([:positive])}@example.test"
      {:ok, _} = Mail.suppress(email, :hard_bounce, "bounce")

      assert {:ok, result} =
               Accounts.invite_user_to_account_and_deliver(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 owner,
                 subject
               )

      assert result.delivery == {:ok, :suppressed}
      refute Map.has_key?(result, :invitation_token)
      assert Repo.reload!(result.membership).invitation_token_digest
      refute_received {:email, _}
    end

    test "a mailer failure is reported while the invitation stays persisted" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      email = "mailer-down-#{System.unique_integer([:positive])}@example.test"
      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert {:ok, result} =
               Accounts.invite_user_to_account_and_deliver(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 owner,
                 subject
               )

      assert result.delivery == {:error, {:failed, :boom}}
      refute Map.has_key?(result, :invitation_token)
      assert Repo.reload!(result.membership).invitation_token_digest
    end

    test "a viewer cannot invite, and nothing is emailed" do
      account = Fixtures.Accounts.create_account()
      viewer = Fixtures.Users.create_user()

      viewer_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.membership_subject(viewer_membership)
      email = "denied-deliver-#{System.unique_integer([:positive])}@example.test"

      assert Accounts.invite_user_to_account_and_deliver(
               Fixtures.Accounts.invitation_attrs(
                 email: email,
                 role: "operator",
                 runner_access_mode: "all"
               ),
               viewer,
               subject
             ) ==
               {:error, :unauthorized}

      refute_received {:email, _}
    end
  end

  describe "resend_account_invitation/2" do
    test "refreshes the pending invite token and validity window" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      email = "resend-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user, invitation_token: old_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      expired_at = DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60, :second)

      membership =
        membership
        |> Ecto.Changeset.change(inserted_at: expired_at, updated_at: expired_at)
        |> Repo.update!()

      # Still pending, past the window: :expired (the digest is only burned by
      # acceptance or replaced by the resend below — after which :not_found).
      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :expired}

      assert {:ok,
              %{
                membership: %Membership{} = updated,
                user: %User{id: user_id},
                invitation_token: new_token
              }} =
               Accounts.resend_account_invitation(membership, subject)

      assert user_id == user.id
      assert updated.id == membership.id
      refute new_token == old_token
      refute updated.invitation_token_digest == membership.invitation_token_digest
      assert DateTime.compare(updated.inserted_at, expired_at) == :gt
      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(new_token)
      assert id == membership.id
      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}
    end

    test "a viewer cannot resend an invitation" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "viewer-denied-#{System.unique_integer([:positive])}@example.test",
            role: "operator"
          ),
          owner_subject
        )

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert Accounts.resend_account_invitation(membership, viewer_subject) ==
               {:error, :unauthorized}

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end

    test "an owner of another account cannot resend this account's invitation" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "cross-resend-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject_a
        )

      assert Accounts.resend_account_invitation(membership, subject_b) == {:error, :unauthorized}

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end

    test "an accepted invitation is no longer resendable" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "accepted-resend-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _accepted} = Accounts.mark_invitation_accepted(membership, user)
      assert Accounts.resend_account_invitation(membership, subject) == {:error, :not_found}
    end

    test "an admin cannot resend an owner invitation" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "owner-resend-#{System.unique_integer([:positive])}@example.test",
            role: "owner"
          ),
          owner_subject
        )

      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.resend_account_invitation(membership, admin_subject) ==
               {:error, :insufficient_privileges}
    end
  end

  describe "resend_account_invitation_and_deliver/3" do
    test "rotates the token, emails the refreshed link, and hands back no token" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      email = "resend-deliver-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      assert {:ok, result} =
               Accounts.resend_account_invitation_and_deliver(membership, owner, subject)

      assert result.delivery == {:ok, :sent}
      refute Map.has_key?(result, :invitation_token)

      refute Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest

      assert_receive {:email, sent}
      assert sent.to == [{"", email}]
      assert sent.text_body =~ "/accept_invitation/"
    end

    test "reports a suppressed resend after rotating the invitation" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      email = "suppressed-resend-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      {:ok, _} = Mail.suppress(email, :spam_complaint, "complaint")

      assert {:ok, result} =
               Accounts.resend_account_invitation_and_deliver(membership, owner, subject)

      assert result.delivery == {:ok, :suppressed}
      refute Map.has_key?(result, :invitation_token)

      refute Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest

      refute_received {:email, _}
    end

    test "an owner of another account cannot resend, and nothing is emailed" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "cross-resend-deliver-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject_a
        )

      assert Accounts.resend_account_invitation_and_deliver(membership, owner_b, subject_b) ==
               {:error, :unauthorized}

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest

      refute_received {:email, _}
    end
  end

  describe "fetch_invitation_by_token/2" do
    test "resolves a pending invitation by its raw token" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(token)
      assert id == membership.id
    end

    test "honors the :preload option for the accept page's render" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-preload-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, %Membership{account: %Account{}, user: %User{}}} =
               Accounts.fetch_invitation_by_token(token, preload: [:account, :user])
    end

    test "does not resolve an invitation for a disabled account" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "an empty/blank/nil token is :not_found (the guard clauses)" do
      assert Accounts.fetch_invitation_by_token("") == {:error, :not_found}
      assert Accounts.fetch_invitation_by_token(nil) == {:error, :not_found}
      assert Accounts.fetch_invitation_by_token("not-a-real-token") == {:error, :not_found}
    end

    test "an accepted invitation no longer resolves (pending-only)" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-accepted-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      {:ok, _} = Accounts.mark_invitation_accepted(membership, user)

      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end
  end

  describe "mark_invitation_accepted/2" do
    test "stamps invitation_accepted_at + clears the token without touching the user" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "joiner-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      # No full_name set — the signed-in-as-self path skips the registration
      # changeset entirely.
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, user)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest

      # User row is untouched: same email, same full_name.
      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.email == user.email
      assert reloaded.full_name == user.full_name
    end

    test "a different signed-in user can't accept (burn) someone else's invite" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      attacker = Fixtures.Users.create_user()

      assert Accounts.mark_invitation_accepted(membership, attacker) == {:error, :unauthorized}

      # The token survives, so the real invitee can still accept.
      assert {:ok, found} = Accounts.fetch_invitation_by_token(token)
      assert found.id == membership.id
    end

    test "a stale invitation cannot be accepted after the account is disabled" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "mark-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Accounts.mark_invitation_accepted(membership, user) == {:error, :not_found}
      reloaded = Repo.reload!(membership)
      assert is_nil(reloaded.invitation_accepted_at)
      assert is_binary(reloaded.invitation_token_digest)
    end
  end

  describe "accept_invitation/2" do
    test "sets the invitee's name + password, confirms them, and clears the token" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: invitee}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "accept-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      # The placeholder user is unconfirmed with no password until acceptance.
      refute invitee.confirmed_at

      assert {:ok, %{user: %User{} = user, membership: %Membership{} = accepted}} =
               Accounts.accept_invitation(membership, %{
                 "full_name" => "Accepted Member",
                 "password" => "a-very-strong-password"
               })

      assert user.full_name == "Accepted Member"
      # Acceptance proves email ownership, so the user is confirmed and the
      # invitation token is cleared.
      refute is_nil(user.confirmed_at)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest
    end

    test "the first acceptor wins — a second accept on the burnt token is :not_found" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "race-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      first_attrs = %{
        "full_name" => "First",
        "password" => "a-very-strong-password"
      }

      assert {:ok, _} = Accounts.accept_invitation(membership, first_attrs)

      # The locked re-judge of the (now non-pending) invitation refuses the
      # second submit before it could overwrite the winner's password.
      second_attrs = %{
        "full_name" => "Second",
        "password" => "another-strong-password"
      }

      assert Accounts.accept_invitation(membership, second_attrs) == {:error, :not_found}
    end

    test "a stale invitation cannot provision a user after the account is disabled" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: invitee}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "accept-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      late_attrs = %{
        "full_name" => "Late Member",
        "password" => "a-very-strong-password"
      }

      assert Accounts.accept_invitation(membership, late_attrs) == {:error, :not_found}

      {:ok, reloaded} = Users.fetch_user_by_id(invitee.id)
      assert is_nil(reloaded.confirmed_at)
      assert is_nil(reloaded.full_name)
    end
  end

  describe "count_memberships/1" do
    test "counts the account's membership rows (the Billing seat count)" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Memberships.create_membership(account_id: account.id)

      assert Accounts.count_memberships(account.id) == 2
    end

    test "counts suspended members (suspension preserves the seat)" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      owner_subject = Fixtures.Subjects.membership_subject(owner_membership)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Accounts.count_memberships(account.id) == 2
      {:ok, _} = Accounts.suspend_membership(member, owner_subject)
      # Suspension keeps the seat — still 2.
      assert Accounts.count_memberships(account.id) == 2
    end

    test "does NOT count soft-deleted (removed) members — they free the seat" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      owner_subject = Fixtures.Subjects.membership_subject(owner_membership)
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Accounts.count_memberships(account.id) == 2
      {:ok, _} = Accounts.delete_membership(member, owner_subject)
      # Removal frees the seat — back to 1 (the owner).
      assert Accounts.count_memberships(account.id) == 1
    end

    test "is scoped to the account" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account_a.id)
      Fixtures.Memberships.create_membership(account_id: account_b.id)
      Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert Accounts.count_memberships(account_a.id) == 1
    end
  end

  describe "peek_account_by_paddle_customer_id/1" do
    test "resolves the account a Paddle customer id belongs to" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      {:ok, linked} = Accounts.put_account_paddle_customer_sync(account, "ctm_123", owner.id)

      assert %Account{id: id} = Accounts.peek_account_by_paddle_customer_id("ctm_123")
      assert id == linked.id
    end

    test "resolves a soft-deleted account too (final-invoice webhooks must still land)" do
      # Deliberately all(), not not_deleted(): a tombstoned account's
      # cancellation/final-invoice webhooks must still resolve so Billing can
      # close the books.
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      {:ok, _} = Accounts.put_account_paddle_customer_sync(account, "ctm_deleted", owner.id)
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert %Account{id: id} = Accounts.peek_account_by_paddle_customer_id("ctm_deleted")
      assert id == account.id
    end

    test "returns nil for an unknown customer id (the webhook no-ops on it)" do
      assert is_nil(Accounts.peek_account_by_paddle_customer_id("ctm_unknown"))
    end
  end

  describe "list_accounts_for_system_sweep/1" do
    test "returns tombstoned accounts in stable id order" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      Fixtures.Accounts.mark_account_as_deleted(account_a)

      assert [first, second] = Accounts.list_accounts_for_system_sweep()
      assert [first.id, second.id] == Enum.sort([account_a.id, account_b.id])
    end

    test "paginates after the supplied account id" do
      accounts = for _ <- 1..3, do: Fixtures.Accounts.create_account()
      [first, second, third] = Enum.sort_by(accounts, & &1.id)

      assert Enum.map(Accounts.list_accounts_for_system_sweep(limit: 1), & &1.id) == [first.id]

      assert Enum.map(
               Accounts.list_accounts_for_system_sweep(limit: 2, after_account_id: first.id),
               & &1.id
             ) == [second.id, third.id]
    end
  end

  describe "list_accounts_due_for_report/2" do
    test "includes never-reported and stale accounts; excludes freshly-reported and deleted" do
      cutoff = ~U[2026-07-01 00:00:00.000000Z]

      never_reported = Fixtures.Accounts.create_account()

      stale =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.set_last_report_sent_at(~U[2026-06-15 12:00:00.000000Z])

      Fixtures.Accounts.create_account()
      |> Fixtures.Accounts.set_last_report_sent_at(~U[2026-07-05 12:00:00.000000Z])

      deleted = Fixtures.Accounts.create_account()
      Fixtures.Accounts.mark_account_as_deleted(deleted)

      due_ids =
        cutoff |> Accounts.list_accounts_due_for_report() |> Enum.map(& &1.id) |> Enum.sort()

      assert due_ids == Enum.sort([never_reported.id, stale.id])
    end

    test "paginates after the supplied account id" do
      cutoff = ~U[2026-07-01 00:00:00.000000Z]
      accounts = for _ <- 1..3, do: Fixtures.Accounts.create_account()
      [first, second, third] = Enum.sort_by(accounts, & &1.id)

      assert Enum.map(Accounts.list_accounts_due_for_report(cutoff, limit: 1), & &1.id) ==
               [first.id]

      assert Enum.map(
               Accounts.list_accounts_due_for_report(cutoff,
                 limit: 2,
                 after_account_id: first.id
               ),
               & &1.id
             ) == [second.id, third.id]
    end
  end

  describe "mark_account_report_sent/2" do
    test "stamps last_report_sent_at when the account is due" do
      cutoff = ~U[2026-07-01 00:00:00.000000Z]
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{} = updated} = Accounts.mark_account_report_sent(account, cutoff)
      assert updated.last_report_sent_at
      assert DateTime.compare(updated.last_report_sent_at, cutoff) == :gt
    end

    test "is a no-op when the account was already reported at or after the cutoff" do
      cutoff = ~U[2026-07-01 00:00:00.000000Z]

      account =
        Fixtures.Accounts.create_account()
        |> Fixtures.Accounts.set_last_report_sent_at(~U[2026-07-10 09:00:00.000000Z])

      assert Accounts.mark_account_report_sent(account, cutoff) == {:error, :already_reported}
    end
  end

  describe "list_paddle_customer_sync_accounts/1" do
    test "returns accounts with a missing Paddle customer" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      assert Enum.map(Accounts.list_paddle_customer_sync_accounts(), & &1.id) == [account.id]
    end

    test "omits accounts whose customer is synced to the current owner email" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      {:ok, _} = Accounts.put_account_paddle_customer_sync(account, "ctm_synced", owner.id)

      assert Accounts.list_paddle_customer_sync_accounts() == []
    end

    test "returns a synced account after its stored billing owner changes email" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      {:ok, _} = Accounts.put_account_paddle_customer_sync(account, "ctm_stale", owner.id)

      Fixtures.Users.update_email(owner, "changed-#{System.unique_integer([:positive])}@test.dev")

      assert Enum.map(Accounts.list_paddle_customer_sync_accounts(), & &1.id) == [account.id]
    end
  end

  describe "fetch_paddle_customer_sync_target/1" do
    test "selects the earliest active confirmed owner when no billing contact is stored" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user(email: "owner-a@example.test")
      other_owner = Fixtures.Users.create_user(email: "owner-b@example.test")

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: other_owner.id,
        role: "owner"
      )

      assert {:ok, %{account: %Account{id: account_id}, owner: selected}} =
               Accounts.fetch_paddle_customer_sync_target(account.id)

      assert account_id == account.id
      assert selected.id == owner.id
    end

    test "keeps the stored billing contact while they remain an active owner" do
      account = Fixtures.Accounts.create_account()
      first_owner = Fixtures.Users.create_user()
      billing_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: first_owner.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: billing_owner.id,
        role: "owner"
      )

      {:ok, _} =
        Accounts.put_account_paddle_customer_sync(account, "ctm_stable", billing_owner.id)

      assert {:ok, %{owner: selected}} = Accounts.fetch_paddle_customer_sync_target(account.id)
      assert selected.id == billing_owner.id
    end

    test "falls back when the stored billing contact is no longer an owner" do
      account = Fixtures.Accounts.create_account()
      fallback_owner = Fixtures.Users.create_user()
      billing_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: fallback_owner.id,
        role: "owner"
      )

      billing_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: billing_owner.id,
          role: "owner"
        )

      {:ok, _} =
        Accounts.put_account_paddle_customer_sync(account, "ctm_fallback", billing_owner.id)

      Fixtures.Memberships.force_role(billing_membership, "admin")

      assert {:ok, %{owner: selected}} = Accounts.fetch_paddle_customer_sync_target(account.id)
      assert selected.id == fallback_owner.id
    end

    test "skips unconfirmed owners and refuses an account with no billable owner email" do
      account = Fixtures.Accounts.create_account()
      unconfirmed = Fixtures.Users.create_user(confirmed?: false)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: unconfirmed.id,
        role: "owner"
      )

      assert Accounts.fetch_paddle_customer_sync_target(account.id) ==
               {:error, :no_billing_contact}
    end
  end

  describe "fetch_account_report_recipient/1" do
    test "returns the stable active confirmed owner" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      assert {:ok, recipient} = Accounts.fetch_account_report_recipient(account)
      assert recipient.id == owner.id
    end

    test "returns :no_recipient when the account has no confirmed owner" do
      account = Fixtures.Accounts.create_account()
      unconfirmed = Fixtures.Users.create_user(confirmed?: false)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: unconfirmed.id,
        role: "owner"
      )

      assert Accounts.fetch_account_report_recipient(account) == {:error, :no_recipient}
    end

    test "does not select another account's owner" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      other_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: other_owner.id,
        role: "owner"
      )

      assert Accounts.fetch_account_report_recipient(account) == {:error, :no_recipient}
    end
  end

  describe "fetch_account_for_report_unsubscribe/1" do
    test "resolves the account a valid token addresses" do
      account = Fixtures.Accounts.create_account()
      token = Crypto.monthly_report_unsubscribe_token(account.id)

      assert {:ok, %Account{} = resolved} = Accounts.fetch_account_for_report_unsubscribe(token)
      assert resolved.id == account.id
    end

    test "rejects a forged or mangled token" do
      assert Accounts.fetch_account_for_report_unsubscribe("not-a-real-token") ==
               {:error, :invalid}
    end

    test "rejects a valid token for a since-deleted account" do
      account = Fixtures.Accounts.create_account()
      token = Crypto.monthly_report_unsubscribe_token(account.id)
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Accounts.fetch_account_for_report_unsubscribe(token) == {:error, :invalid}
    end
  end

  describe "unsubscribe_from_monthly_report/1" do
    test "flips monthly_report_opt_out on for the token's account" do
      account = Fixtures.Accounts.create_account()
      refute account.settings.monthly_report_opt_out
      token = Crypto.monthly_report_unsubscribe_token(account.id)

      assert {:ok, %Account{} = updated} = Accounts.unsubscribe_from_monthly_report(token)
      assert updated.settings.monthly_report_opt_out
      assert Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "is idempotent" do
      account = Fixtures.Accounts.create_account()
      token = Crypto.monthly_report_unsubscribe_token(account.id)

      assert {:ok, _} = Accounts.unsubscribe_from_monthly_report(token)
      assert {:ok, %Account{} = updated} = Accounts.unsubscribe_from_monthly_report(token)
      assert updated.settings.monthly_report_opt_out
    end

    test "a token for one account never opts another out" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      token = Crypto.monthly_report_unsubscribe_token(account.id)

      assert {:ok, _} = Accounts.unsubscribe_from_monthly_report(token)
      refute Repo.reload!(other_account).settings.monthly_report_opt_out
    end

    test "rejects a forged token" do
      assert Accounts.unsubscribe_from_monthly_report("nope") == {:error, :invalid}
    end
  end

  describe "put_account_paddle_customer_sync/3" do
    test "stamps the Paddle customer id, billing contact, and sync time" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      assert is_nil(account.paddle_customer_id)

      assert {:ok,
              %Account{
                paddle_customer_id: "ctm_first",
                paddle_billing_contact_user_id: owner_id,
                paddle_customer_synced_at: %DateTime{}
              }} = Accounts.put_account_paddle_customer_sync(account, "ctm_first", owner.id)

      assert owner_id == owner.id

      reloaded = Repo.reload!(account)
      assert reloaded.paddle_customer_id == "ctm_first"
      assert reloaded.paddle_billing_contact_user_id == owner.id
    end

    test "first-wins: a different customer id keeps the already-linked id" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      other_owner = Fixtures.Users.create_user()
      {:ok, _} = Accounts.put_account_paddle_customer_sync(account, "ctm_winner", owner.id)

      # The loser's write is a no-op — the caller gets the winning account back,
      # still carrying the first id (callers read the id off the RETURNED account).
      assert {:ok,
              %Account{
                paddle_customer_id: "ctm_winner",
                paddle_billing_contact_user_id: owner_id
              }} = Accounts.put_account_paddle_customer_sync(account, "ctm_loser", other_owner.id)

      assert owner_id == owner.id
      assert Repo.reload!(account).paddle_customer_id == "ctm_winner"
    end

    test "a sync for the stored customer id may update the billing contact" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()
      new_owner = Fixtures.Users.create_user()
      {:ok, linked} = Accounts.put_account_paddle_customer_sync(account, "ctm_keep", owner.id)

      assert {:ok, %Account{paddle_billing_contact_user_id: owner_id}} =
               Accounts.put_account_paddle_customer_sync(linked, "ctm_keep", new_owner.id)

      assert owner_id == new_owner.id
    end
  end

  describe "soft-deleted associations are excluded from preloads" do
    test "account preload skips a soft-deleted membership (preloader honors :where)" do
      account = Fixtures.Accounts.create_account()
      live_user = Fixtures.Users.create_user()
      doomed_user = Fixtures.Users.create_user()

      _live =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: live_user.id)

      doomed =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: doomed_user.id)

      Fixtures.Memberships.mark_membership_as_deleted(doomed)

      {:ok, loaded} =
        Account.Query.not_deleted()
        |> Account.Query.by_id(account.id)
        |> Emisar.Repo.fetch(Account.Query, preload: [:memberships])

      assert [%Membership{} = only] = loaded.memberships
      assert only.user_id == live_user.id
    end
  end

  describe "subject_can_manage_team?/1" do
    test "is true for an owner and an admin (they hold manage_team)" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.subject_can_manage_team?(owner_subject)
      assert Accounts.subject_can_manage_team?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Accounts.subject_can_manage_team?(operator_subject)
      refute Accounts.subject_can_manage_team?(viewer_subject)
    end
  end

  describe "subject_can_manage_account?/1" do
    test "is true for an owner and an admin (they hold manage_own_account)" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.subject_can_manage_account?(owner_subject)
      assert Accounts.subject_can_manage_account?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Accounts.subject_can_manage_account?(operator_subject)
      refute Accounts.subject_can_manage_account?(viewer_subject)
    end
  end

  describe "subject_can_manage_account_security?/1" do
    test "is true for an owner and an admin (they hold manage_security_settings)" do
      account = Fixtures.Accounts.create_account()
      owner_subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.subject_can_manage_account_security?(owner_subject)
      assert Accounts.subject_can_manage_account_security?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      account = Fixtures.Accounts.create_account()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: operator.id,
        role: "operator"
      )

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Accounts.subject_can_manage_account_security?(operator_subject)
      refute Accounts.subject_can_manage_account_security?(viewer_subject)
    end
  end

  describe "refresh_directory_authorization_sessions/1" do
    test "disconnects live sockets without revoking the member's session token" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "admin"
        )

      token = Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now())

      assert Accounts.refresh_directory_authorization_sessions(membership) == :ok
      assert {:ok, %User{}, _session} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
    end
  end

  describe "team-list broadcasts" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      %{
        account: account,
        target: target,
        subject: Fixtures.Subjects.subject_for(owner, account, role: :owner)
      }
    end

    test "suspending a member broadcasts {:list_changed, :team, …} on the account topic", %{
      account: account,
      target: target,
      subject: subject
    } do
      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, _} = Accounts.suspend_membership(target, subject)

      assert_receive {:list_changed, :team, "membership.suspended", user_id}, 500
      assert user_id == target.user_id
    end

    test "removing a member broadcasts {:list_changed, :team, …} on the account topic", %{
      account: account,
      target: target,
      subject: subject
    } do
      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert_receive {:list_changed, :team, "membership.removed", user_id}, 500
      assert user_id == target.user_id
    end
  end

  # Build an IdP provider for the directory-sync tests. The provider's account
  # IS the authorization on the no-Subject sync path, so the sync_* functions
  # need only a persisted provider scoped to the right account — not a full
  # SCIM-enabled one. Owner is rejected as a default_role, so use :viewer.
  defp provider_fixture(account) do
    Fixtures.SSO.create_identity_provider(%{
      account_id: account.id,
      kind: :okta,
      name: "Okta",
      issuer: "https://idp.test",
      client_id: "cid",
      client_secret: "secret",
      enabled: true,
      default_role: :viewer
    })
  end

  defp enroll_mfa(user) do
    Fixtures.Users.set_mfa_state(user, mfa_enabled_at: DateTime.utc_now())
  end

  # Fully enroll a member's MFA — secret + recovery codes too, not just
  # the timestamp — so reset_member_mfa's "every field is wiped" assertion
  # is meaningful (clearing only the timestamp wouldn't prove the secret
  # and codes were dropped).
  defp enroll_member_mfa(user) do
    Fixtures.Users.set_mfa_state(user,
      mfa_secret: "JBSWY3DPEHPK3PXP",
      mfa_enabled_at: DateTime.utc_now(),
      mfa_recovery_codes: ["digest-a", "digest-b"]
    )
  end
end
