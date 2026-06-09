defmodule Emisar.InvitationTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Accounts

  defp inviter_subject(account) do
    inviter = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
    {inviter, subject_for(inviter, account, role: :owner)}
  end

  describe "invite_user_to_account/3" do
    test "creates a placeholder user for a brand-new email" do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)

      assert {:ok,
              %{
                membership: membership,
                user: invitee,
                invitation_token: token,
                created?: true
              }} = Accounts.invite_user_to_account("new@example.test", "admin", subject)

      assert invitee.email == "new@example.test"
      assert is_binary(token)
      assert byte_size(token) > 16
      assert membership.role == :admin
      assert membership.invitation_token == token
      assert is_nil(membership.invitation_accepted_at)
    end

    test "reuses an existing user when the email already exists" do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)
      existing = user_fixture(email: "alice@example.test")

      assert {:ok, %{user: invitee, created?: false}} =
               Accounts.invite_user_to_account("alice@example.test", "operator", subject)

      assert invitee.id == existing.id
    end

    test "lowercases + trims email" do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)

      assert {:ok, %{user: invitee}} =
               Accounts.invite_user_to_account(
                 "  HELLO@Example.Test  ",
                 "viewer",
                 subject
               )

      assert invitee.email == "hello@example.test"
    end

    test "rolls back when the user already belongs to the account" do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)
      existing = user_fixture()
      _existing_membership = membership_fixture(account_id: account.id, user_id: existing.id)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(existing.email, "admin", subject)
    end
  end

  describe "fetch_invitation_by_token/1" do
    setup do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: m, invitation_token: token, user: u}} =
        Accounts.invite_user_to_account("bob@example.test", "admin", subject)

      %{membership: m, token: token, invitee: u, account: account}
    end

    test "returns the membership with preloads", %{token: token, account: account, invitee: u} do
      assert {:ok, m} = Accounts.fetch_invitation_by_token(token)
      assert m.account.id == account.id
      assert m.user.id == u.id
    end

    test "returns :not_found for an unknown token" do
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("bogus")
    end

    test "returns :not_found for nil / empty token (no leaky scan)" do
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(nil)
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("")
    end
  end

  describe "accept_invitation/2" do
    setup do
      account = account_fixture()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: m}} =
        Accounts.invite_user_to_account("carol@example.test", "operator", subject)

      %{membership: m}
    end

    test "sets the user's password + full_name, confirms, clears the token", %{membership: m} do
      attrs = %{"full_name" => "Carol", "password" => "very-long-password-1234"}

      assert {:ok, %{user: user, membership: m2}} = Accounts.accept_invitation(m, attrs)

      assert user.full_name == "Carol"
      assert user.confirmed_at
      assert is_nil(m2.invitation_token)
      assert m2.invitation_accepted_at

      # And the user can now actually sign in.
      assert {:ok, %_{}} =
               Emisar.Auth.fetch_user_by_email_and_password(user.email, "very-long-password-1234")
    end

    test "rejects too-short passwords", %{membership: m} do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.accept_invitation(m, %{"full_name" => "Carol", "password" => "short"})
    end
  end
end
