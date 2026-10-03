defmodule Emisar.UsersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.Mail
  alias Emisar.Marketing
  alias Emisar.Users
  alias Emisar.Users.User

  describe "delete_by_id/2" do
    test "hard-deletes the login row and the legacy memberships still keyed on it" do
      user = legacy_login("legacy-login@example.test")
      account = Fixtures.Accounts.create_account()
      member = legacy_member(account, user)
      user_id = user.id

      assert {:ok, %User{id: ^user_id}} = Users.delete_by_id(user_id, repo: Repo)

      assert Repo.one(User.Query.all() |> User.Query.by_id(user_id)) == nil

      assert Repo.one(
               Emisar.Accounts.Membership.Query.all()
               |> Emisar.Accounts.Membership.Query.by_user_id(user_id)
             ) == nil

      refute Repo.reload(member)
    end

    test "erases the address from the suppression and marketing lists too" do
      user = legacy_login("erased-login@example.test")
      {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "HardBounce")
      {:ok, _signup} = Marketing.capture_signup(%{email: user.email, source: "pricing"})

      assert {:ok, _deleted} = Users.delete_by_id(user.id, repo: Repo)

      # Neither table has an account foreign key, so the row cascade cannot
      # reach them and no retention sweep ages them out — an erasure that left
      # them behind would keep the person's address forever.
      refute Mail.suppressed?(user.email)
      refute Repo.one(Marketing.Signup.Query.by_email(user.email))
    end

    test "returns not_found for malformed or unknown ids" do
      assert Users.delete_by_id("not-a-uuid", repo: Repo) == {:error, :not_found}
      assert Users.delete_by_id(Ecto.UUID.generate(), repo: Repo) == {:error, :not_found}
    end
  end

  # The `users` table has no writer left: its rows are history until S3 drops
  # it, so the only way to arrange one is to insert it directly.
  defp legacy_login(email) do
    %User{}
    |> Ecto.Changeset.change(
      email: email,
      full_name: "Legacy Login",
      confirmed_at: DateTime.utc_now()
    )
    |> Repo.insert!()
  end

  defp legacy_member(account, %User{} = user) do
    Fixtures.Memberships.create_membership(account_id: account.id, email: user.email)
    |> Ecto.Changeset.change(user_id: user.id)
    |> Repo.update!()
  end
end
