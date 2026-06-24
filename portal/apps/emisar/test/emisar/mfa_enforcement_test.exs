defmodule Emisar.MfaEnforcementTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, Repo, Users}
  alias Emisar.Accounts.Account
  alias Emisar.Users.User

  describe "update_account/3 (require_mfa)" do
    test "owner can enable; flips the column" do
      user = user_fixture()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          user
        )

      refute account.require_mfa
      owner_subject = subject_for(user, account, role: :owner)

      {:ok, account} = Accounts.update_account(account, %{require_mfa: true}, owner_subject)
      assert account.require_mfa

      {:ok, account} = Accounts.update_account(account, %{require_mfa: false}, owner_subject)
      refute account.require_mfa
    end

    test "an operator is rejected (owners + admins manage security settings)" do
      owner = user_fixture()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          owner
        )

      owner_subject = subject_for(owner, account, role: :owner)

      email = "operator-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{user: operator_user, membership: m}} =
        Accounts.invite_user_to_account(email, "operator", owner_subject)

      confirm_user(operator_user)
      {:ok, _} = Accounts.mark_invitation_accepted(m, operator_user)
      operator_subject = subject_for(operator_user, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(account, %{require_mfa: true}, operator_subject)
    end
  end

  describe "User.valid_password?/2 after force_password_reset" do
    test "old password stops working immediately" do
      owner = user_fixture()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          owner
        )

      owner_subject = subject_for(owner, account, role: :owner)

      email = "t-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Users.register_user(%{email: email, password: "Hunter222-original", full_name: "T"})

      user = confirm_user(user)
      {:ok, _} = Accounts.invite_user_to_account(email, "operator", owner_subject)
      {:ok, m} = Accounts.fetch_membership_for_session(user, nil)

      # Verify old password works pre-reset.
      assert User.valid_password?(user, "Hunter222-original")

      :ok = Accounts.force_password_reset(m, owner_subject)

      # Reload and check.
      reloaded = Repo.get!(User, user.id)
      refute User.valid_password?(reloaded, "Hunter222-original")
      assert is_nil(reloaded.hashed_password)
    end
  end

  describe "require_mfa default" do
    test "new accounts default to require_mfa: false (signup never blocks)" do
      user = user_fixture()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Fresh", slug: "fresh-#{System.unique_integer()}", plan: "free"},
          user
        )

      assert account.require_mfa == false
      assert %Account{} = account
    end
  end
end
