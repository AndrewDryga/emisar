defmodule Emisar.AccountsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Users
  alias Emisar.Users.User

  describe "create_account_with_owner/2" do
    test "persists account + owner membership in a single transaction" do
      user = user_fixture()

      assert {:ok, %Account{} = account} =
               Accounts.create_account_with_owner(
                 %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
                 user
               )

      assert %Membership{role: :owner} = fetch_membership(account.id, user.id)
    end

    test "rolls back when the account changeset is invalid" do
      user = user_fixture()

      # Slug too short — fails the format regex (>=3 chars).
      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_account_with_owner(%{name: "x", slug: "x"}, user)

      # No partial membership stuck around. The user has no account yet, so
      # the picker subject is built straight from the actor (account nil).
      subject = %Emisar.Auth.Subject{actor: user}
      assert {:ok, [], _} = Accounts.list_accounts_for_user(subject)
    end
  end

  describe "fetch_membership_for_session/2" do
    test "with no account_id, returns the most-recent non-disabled membership" do
      user = user_fixture()
      first_account = account_fixture()
      second_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)
      second_membership = membership_fixture(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{}, user: %User{}}} =
               Accounts.fetch_membership_for_session(user, nil)

      assert id == second_membership.id
    end

    test "with a matching account_id, returns that specific membership even if older" do
      user = user_fixture()
      first_account = account_fixture()
      second_account = account_fixture()
      first_membership = membership_fixture(account_id: first_account.id, user_id: user.id)
      _ = membership_fixture(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = account}} =
               Accounts.fetch_membership_for_session(user, first_account.id)

      assert id == first_membership.id
      assert account.id == first_account.id
    end

    test "with a stale or unknown account_id, falls back to the primary" do
      user = user_fixture()
      first_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, Ecto.UUID.generate())

      assert returned_account_id == first_account.id
    end

    test "with a suspended membership on the requested account, falls back" do
      user = user_fixture()
      first_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)

      {_owner_user, second_account, owner_subject} = owner_subject_fixture()

      second_membership =
        membership_fixture(account_id: second_account.id, user_id: user.id, role: "operator")

      assert {:ok, _} = Accounts.suspend_membership(second_membership, owner_subject)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, second_account.id)

      refute returned_account_id == second_account.id
    end

    test "returns :not_found for a user with no memberships" do
      assert {:error, :not_found} =
               Accounts.fetch_membership_for_session(user_fixture(), nil)
    end
  end

  describe "invite_user_to_account/3" do
    test "creates a placeholder user for an unknown email" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      assert {:ok,
              %{
                membership: %Membership{role: :admin},
                user: %User{} = invitee,
                invitation_token: token
              }} =
               Accounts.invite_user_to_account(email, "admin", subject)

      assert invitee.email == email
      refute invitee.hashed_password
      assert is_binary(token)
    end

    test "reuses the existing user when one is already registered" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      assert {:ok, %{user: %User{id: id}}} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)

      assert id == existing.id
    end

    test "refuses duplicate memberships" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      _ = membership_fixture(account_id: account.id, user_id: existing.id)
      subject = subject_for(inviter, account, role: :owner)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)
    end

    test "an admin cannot invite an owner (can't grant a role it doesn't hold)" do
      admin = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      email = "owner-invite-#{System.unique_integer([:positive])}@example.test"

      assert {:error, :insufficient_privileges} =
               Accounts.invite_user_to_account(email, "owner", subject)
    end
  end

  describe "mark_invitation_accepted/1" do
    test "stamps invitation_accepted_at + clears the token without touching the user" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "joiner-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      # No password change, no full_name set — the signed-in-as-self
      # path skips the registration changeset entirely.
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, user)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest

      # User row is untouched: same hashed_password (nil for a placeholder
      # user), same email.
      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.email == user.email
      assert reloaded.hashed_password == user.hashed_password
    end

    test "a different signed-in user can't accept (burn) someone else's invite" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      attacker = user_fixture()

      assert {:error, :unauthorized} =
               Accounts.mark_invitation_accepted(membership, attacker)

      # The token survives, so the real invitee can still accept.
      assert {:ok, found} = Accounts.fetch_invitation_by_token(token)
      assert found.id == membership.id
    end
  end

  describe "suggest_unique_slug/1" do
    test "returns the slugified base when free" do
      assert Accounts.suggest_unique_slug("Acme Co!") =~ ~r/^acme-co/
    end

    test "appends -1, -2, ... on collision" do
      base = "team-#{System.unique_integer([:positive])}"
      _ = account_fixture(slug: base)
      _ = account_fixture(slug: base <> "-1")

      assert Accounts.suggest_unique_slug(base) == base <> "-2"
    end
  end

  describe "update_membership_role/3" do
    test "the last active owner can't demote themselves; with a second owner it works" do
      account = account_fixture()
      owner = user_fixture()
      owner_m = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      # Sole owner — the in-transaction guard (locked re-count of the
      # account's active owner rows) refuses the demotion.
      assert {:error, :last_owner} = Accounts.update_membership_role(owner_m, "admin", subject)

      # A second active owner frees the demotion.
      second = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: second.id, role: "owner")

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(owner_m, "admin", subject)
    end

    test "promotes operator to admin" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()
      m = membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(m, "admin", subject)
    end

    test "rejects an unknown role" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()
      m = membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:error, cs} = Accounts.update_membership_role(m, "supreme-leader", subject)
      assert "is invalid" in errors_on(cs).role
    end

    test "an admin cannot grant the owner role (no escalation by proxy)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      m = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "operator")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(m, "owner", subject)
    end

    test "an admin cannot demote an owner (can't outrank a superior)" do
      account = account_fixture()

      owner_m =
        membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(owner_m, "operator", subject)
    end

    test "you cannot promote yourself" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      admin = user_fixture()
      admin_m = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :cannot_self_promote} =
               Accounts.update_membership_role(admin_m, "owner", subject)
    end

    test "an owner can grant the owner role" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      m = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :owner}} =
               Accounts.update_membership_role(m, "owner", subject)
    end
  end

  describe "delete_membership/3" do
    test "owner can remove a non-owner member" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{} = removed} = Accounts.delete_membership(target, subject)

      # Removal is a soft delete: the tombstone keeps history while every
      # not_deleted() read treats the member as gone.
      assert removed.deleted_at
      assert {:error, :not_found} = Accounts.fetch_membership_for_session(target_user, account.id)
    end

    test "removing a member revokes the API keys they minted" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      member = user_fixture()

      member_membership =
        membership_fixture(account_id: account.id, user_id: member.id, role: "admin")

      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: member.id)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # Sessions self-heal at membership resolution; the minted keys don't,
      # so removal revokes them (after_commit) to cut off MCP / OAuth.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "a removed member can be re-invited (tombstone doesn't hold the seat)" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert {:ok, %{membership: fresh}} =
               Accounts.invite_user_to_account(target_user.email, "viewer", subject)

      assert fresh.user_id == target_user.id
      assert fresh.id != target.id
    end

    test "an operator (no manage_team permission) cannot remove a member → :unauthorized" do
      account = account_fixture()
      target_user = user_fixture()
      target = membership_fixture(account_id: account.id, user_id: target_user.id, role: "viewer")

      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.delete_membership(target, operator_subject)
      # The target membership is still present.
      assert %Membership{} = fetch_membership(account.id, target_user.id)
    end

    test "an admin cannot remove an owner" do
      account = account_fixture()

      owner_m =
        membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} = Accounts.delete_membership(owner_m, subject)
    end
  end

  describe "suspend_membership/2 + reinstate_membership/2" do
    setup do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      owner_subject = subject_for(owner, account, role: :owner)
      {:ok, account: account, owner: owner, target: target, owner_subject: owner_subject}
    end

    test "owner can suspend an operator and reinstate", %{
      target: target,
      owner_subject: owner_subject
    } do
      assert {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      assert Membership.disabled?(suspended)

      assert {:ok, reinstated} = Accounts.reinstate_membership(suspended, owner_subject)
      refute Membership.disabled?(reinstated)
    end

    test "suspending a member revokes the API keys they minted", %{
      account: account,
      owner_subject: owner_subject
    } do
      admin = user_fixture()

      admin_membership =
        membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")

      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: admin.id)
      assert is_nil(Emisar.Repo.reload!(key).revoked_at)

      assert {:ok, _} = Accounts.suspend_membership(admin_membership, owner_subject)

      # after_commit revokes the keys the suspended member minted so they
      # can't keep dispatching via MCP / OAuth after losing access.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "operator cannot suspend anyone", %{account: account, target: target} do
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.suspend_membership(target, operator_subject)
    end

    test "can't suspend yourself", %{owner: owner, account: account, owner_subject: owner_subject} do
      owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert {:error, :cannot_modify_self} =
               Accounts.suspend_membership(owner_membership, owner_subject)
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
      second_owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: second_owner.id, role: "owner")
      second_owner_subject = subject_for(second_owner, account, role: :owner)
      assert {:ok, _} = Accounts.suspend_membership(owner_membership, second_owner_subject)

      # Now `second_owner` is the last ACTIVE owner — can't be suspended.
      # (The first owner's Subject still carries owner permissions at the
      # context layer — suspension is enforced by killing their session at
      # the web layer — so it can drive this attempt.)
      second_owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, second_owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert {:error, :last_owner} =
               Accounts.suspend_membership(second_owner_membership, owner_subject)

      # Reinstating the first owner makes the second suspendable again —
      # and pins that reinstate REALLY clears the row (a stale-struct
      # reinstate used to silently no-op).
      {:ok, _} = Accounts.reinstate_membership(owner_membership, second_owner_subject)

      assert {:ok, _} =
               Accounts.suspend_membership(second_owner_membership, owner_subject)

      _ = owner
    end

    test "suspended membership is excluded from fetch_membership_for_session/2", %{
      target: target,
      owner_subject: owner_subject
    } do
      target_user = Emisar.Repo.preload(target, :user).user
      assert {:ok, %Membership{}} = Accounts.fetch_membership_for_session(target_user, nil)

      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)
      assert {:error, :not_found} = Accounts.fetch_membership_for_session(target_user, nil)
      assert Accounts.all_memberships_suspended?(target_user)
    end
  end

  describe "force_password_reset/2" do
    test "wipes sessions + emails the user + audit-logs" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      target_subject = subject_for(target_user, account, role: :operator)
      _ = Emisar.Auth.create_session_token!(target_user)
      assert {:ok, [_], _} = Emisar.Auth.list_sessions_for_user(target_subject)

      owner_subject = subject_for(owner, account, role: :owner)
      assert :ok = Accounts.force_password_reset(target, owner_subject)
      assert {:ok, [], _} = Emisar.Auth.list_sessions_for_user(target_subject)

      events =
        Emisar.Audit.list_events(owner_subject, page: [limit: 10])
        |> elem(1)

      assert Enum.any?(events, &(&1.event_type == "user.password_reset_forced"))
    end
  end

  describe "soft-deleted associations are excluded from preloads" do
    test "account preload skips a soft-deleted membership (preloader honors :where)" do
      account = account_fixture()
      live_user = user_fixture()
      doomed_user = user_fixture()
      _live = membership_fixture(account_id: account.id, user_id: live_user.id)
      doomed = membership_fixture(account_id: account.id, user_id: doomed_user.id)

      {:ok, _} = doomed |> Membership.Changeset.delete() |> Emisar.Repo.update()

      {:ok, loaded} =
        Account.Query.not_deleted()
        |> Account.Query.by_id(account.id)
        |> Emisar.Repo.fetch(Account.Query, preload: [:memberships])

      assert [%Membership{} = only] = loaded.memberships
      assert only.user_id == live_user.id
    end
  end

  describe "list_memberships_for_account/3" do
    test "lists the account's members for a member subject" do
      {_owner, account, subject} = owner_subject_fixture()
      _second = membership_fixture(account_id: account.id)

      assert {:ok, memberships, _} = Accounts.list_memberships_for_account(account, subject)
      assert length(memberships) == 2
    end

    test "list_account_memberships/2 (system fan-out read) is scoped to the given account" do
      {_owner_a, account_a, _} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()
      _other = membership_fixture(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "a subject cannot list another account's memberships" do
      {_owner_a, _account_a, subject_a} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()

      assert {:error, :unauthorized} =
               Accounts.list_memberships_for_account(account_b, subject_a)
    end
  end

  describe "record_account_switched/1" do
    test "writes the session.account_switched audit row for the switched-to account" do
      {owner, account, subject} = owner_subject_fixture()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, account.id)

      assert {:ok, _event} = Accounts.record_account_switched(membership)

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 10])
      switched = Enum.find(events, &(&1.event_type == "session.account_switched"))

      assert switched
      assert switched.actor_id == owner.id
      assert switched.subject_label == owner.email
    end
  end
end
