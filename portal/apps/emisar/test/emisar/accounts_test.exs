defmodule Emisar.AccountsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership, User}

  describe "register_user/1" do
    test "creates a user with a hashed password" do
      email = "reg-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} =
               Accounts.register_user(%{
                 email: email,
                 full_name: "Reggie",
                 password: "a-12-char-password"
               })

      assert user.email == email
      assert is_binary(user.hashed_password)
      # The virtual `password` field is wiped after hashing.
      refute user.password
    end

    test "rejects duplicate emails" do
      email = "dup-#{System.unique_integer([:positive])}@example.test"
      _ = user_fixture(email: email)

      assert {:error, changeset} =
               Accounts.register_user(%{
                 email: email,
                 password: "a-12-char-password"
               })

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns the user when found" do
      user = user_fixture()
      assert {:ok, %User{id: id}} = Accounts.fetch_user_by_email(user.email)
      assert id == user.id
    end

    test "returns :not_found for unknown email" do
      assert {:error, :not_found} =
               Accounts.fetch_user_by_email("nobody-#{System.unique_integer()}@example.test")
    end
  end

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

      # No partial membership stuck around.
      assert {:ok, [], _} = Accounts.list_accounts_for_user(user)
    end
  end

  describe "fetch_membership_for_session/2" do
    test "with no account_id, returns the most-recent non-disabled membership" do
      user = user_fixture()
      a1 = account_fixture()
      a2 = account_fixture()
      _ = membership_fixture(account_id: a1.id, user_id: user.id)
      m2 = membership_fixture(account_id: a2.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{}, user: %User{}}} =
               Accounts.fetch_membership_for_session(user, nil)

      assert id == m2.id
    end

    test "with a matching account_id, returns that specific membership even if older" do
      user = user_fixture()
      a1 = account_fixture()
      a2 = account_fixture()
      m1 = membership_fixture(account_id: a1.id, user_id: user.id)
      _ = membership_fixture(account_id: a2.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = a}} =
               Accounts.fetch_membership_for_session(user, a1.id)

      assert id == m1.id
      assert a.id == a1.id
    end

    test "with a stale or unknown account_id, falls back to the primary" do
      user = user_fixture()
      a1 = account_fixture()
      _ = membership_fixture(account_id: a1.id, user_id: user.id)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, Ecto.UUID.generate())

      assert returned_account_id == a1.id
    end

    test "with a suspended membership on the requested account, falls back" do
      user = user_fixture()
      a1 = account_fixture()
      _ = membership_fixture(account_id: a1.id, user_id: user.id)

      {_owner_user, a2, owner_subject} = owner_subject_fixture()

      m2 =
        membership_fixture(account_id: a2.id, user_id: user.id, role: "operator")

      assert {:ok, _} = Accounts.suspend_membership(m2, owner_subject)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, a2.id)

      refute returned_account_id == a2.id
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
                user: %User{} = u,
                invitation_token: token,
                created?: true
              }} =
               Accounts.invite_user_to_account(email, "admin", subject)

      assert u.email == email
      refute u.hashed_password
      assert is_binary(token)
    end

    test "reuses the existing user when one is already registered" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      assert {:ok, %{user: %User{id: id}, created?: false}} =
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
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token

      # User row is untouched: same hashed_password (nil for a placeholder
      # user), same email.
      reloaded = Accounts.fetch_user_by_id!(user.id)
      assert reloaded.email == user.email
      assert reloaded.hashed_password == user.hashed_password
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

      assert {:ok, %Membership{}} = Accounts.delete_membership(target, subject)
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
  end

  describe "update_user_email/4" do
    test "updates the email when the current password verifies" do
      password = "current-password-12-chars"
      user = user_fixture(password: password)
      subject = Emisar.Auth.Subject.system()

      new = "new-#{System.unique_integer([:positive])}@example.test"
      assert {:ok, updated} = Accounts.update_user_email(user, new, password, subject)
      assert updated.email == new
    end

    test "refuses when the current password is wrong" do
      user = user_fixture()
      subject = Emisar.Auth.Subject.system()

      assert {:error, :invalid_current_password} =
               Accounts.update_user_email(user, "x@y.test", "not-the-password", subject)
    end

    test "rejects a malformed email even with the right password" do
      password = "right-password-12-chars"
      user = user_fixture(password: password)
      subject = Emisar.Auth.Subject.system()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_user_email(user, "not-an-email", password, subject)
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
      # the second owner tries to suspend the first.
      second_owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: second_owner.id, role: "owner")
      second_owner_subject = subject_for(second_owner, account, role: :owner)
      assert {:ok, _} = Accounts.suspend_membership(owner_membership, second_owner_subject)

      # Now `second_owner` is the last active owner — can't be suspended.
      second_owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, second_owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      # Need an actor who can call — use the originally-suspended owner,
      # but they're suspended so unauthorized. Reinstate them first.
      {:ok, _} = Accounts.reinstate_membership(owner_membership, second_owner_subject)

      assert {:error, :last_owner} =
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

      _ = Emisar.Auth.create_session_token!(target_user)
      assert {:ok, [_], _} = Emisar.Auth.list_sessions_for_user(target_user)

      owner_subject = subject_for(owner, account, role: :owner)
      assert :ok = Accounts.force_password_reset(target, owner_subject)
      assert {:ok, [], _} = Emisar.Auth.list_sessions_for_user(target_user)

      events =
        Emisar.Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 10])
        |> elem(1)

      assert Enum.any?(events, &(&1.event_type == "user.password_reset_forced"))
    end
  end
end
