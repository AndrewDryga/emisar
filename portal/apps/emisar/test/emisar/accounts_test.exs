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

  describe "get_user_by_email/1" do
    test "returns the user when found" do
      user = user_fixture()
      assert %User{id: id} = Accounts.get_user_by_email(user.email)
      assert id == user.id
    end

    test "returns nil for unknown email" do
      refute Accounts.get_user_by_email("nobody-#{System.unique_integer()}@example.test")
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

      membership = Accounts.get_membership(account.id, user.id)
      assert %Membership{role: "owner"} = membership
    end

    test "rolls back when the account changeset is invalid" do
      user = user_fixture()

      # Slug too short — fails the format regex (>=3 chars).
      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_account_with_owner(%{name: "x", slug: "x"}, user)

      # No partial membership stuck around.
      assert Accounts.list_accounts_for_user(user) == []
    end
  end

  describe "primary_membership/1" do
    test "returns the most-recent non-disabled membership" do
      user = user_fixture()
      a1 = account_fixture()
      a2 = account_fixture()
      _ = membership_fixture(account_id: a1.id, user_id: user.id)
      m2 = membership_fixture(account_id: a2.id, user_id: user.id)

      assert %Membership{id: id, account: %Account{}, user: %User{}} =
               Accounts.primary_membership(user)

      assert id == m2.id
    end

    test "returns nil for a user with no memberships" do
      refute Accounts.primary_membership(user_fixture())
    end
  end

  describe "invite_user_to_account/4" do
    test "creates a placeholder user for an unknown email" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %{membership: %Membership{role: "admin"}, user: %User{} = u, invitation_token: token, created?: true}} =
               Accounts.invite_user_to_account(account.id, email, "admin", inviter.id)

      assert u.email == email
      refute u.hashed_password
      assert is_binary(token)
    end

    test "reuses the existing user when one is already registered" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()

      assert {:ok, %{user: %User{id: id}, created?: false}} =
               Accounts.invite_user_to_account(account.id, existing.email, "operator", inviter.id)

      assert id == existing.id
    end

    test "refuses duplicate memberships" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: existing.id)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(account.id, existing.email, "operator", inviter.id)
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

  describe "update_membership_role/2" do
    test "promotes operator to admin" do
      m = membership_fixture(role: "operator")
      assert {:ok, %Membership{role: "admin"}} = Accounts.update_membership_role(m, "admin")
    end

    test "rejects an unknown role" do
      m = membership_fixture(role: "operator")
      assert {:error, cs} = Accounts.update_membership_role(m, "supreme-leader")
      assert "is invalid" in errors_on(cs).role
    end
  end
end
