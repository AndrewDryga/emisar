defmodule Emisar.MfaEnforcementTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.Fixtures

  describe "update_account/3 (require_mfa)" do
    test "owner can enable; flips the column" do
      user = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          user
        )

      refute account.settings.require_mfa
      owner_subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: true}}, owner_subject)

      assert account.settings.require_mfa

      {:ok, account} =
        Accounts.update_account(account, %{settings: %{require_mfa: false}}, owner_subject)

      refute account.settings.require_mfa
    end

    test "an operator is rejected (owners + admins manage security settings)" do
      owner = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "A", slug: "a-#{System.unique_integer()}", plan: "free"},
          owner
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      email = "operator-#{System.unique_integer([:positive])}@example.com"

      {:ok, %{user: operator_user, membership: m}} =
        Accounts.invite_user_to_account(
          email,
          "operator",
          Accounts.RunnerAccess.all(),
          owner_subject
        )

      Fixtures.Users.confirm_user(operator_user)
      {:ok, _} = Accounts.mark_invitation_accepted(m, operator_user)
      operator_subject = Fixtures.Subjects.subject_for(operator_user, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(
                 account,
                 %{settings: %{require_mfa: true}},
                 operator_subject
               )
    end
  end

  describe "require_mfa default" do
    test "new accounts default to require_mfa: false (signup never blocks)" do
      user = Fixtures.Users.create_user()

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Fresh", slug: "fresh-#{System.unique_integer()}", plan: "free"},
          user
        )

      assert account.settings.require_mfa == false
      assert %Account{} = account
    end
  end
end
