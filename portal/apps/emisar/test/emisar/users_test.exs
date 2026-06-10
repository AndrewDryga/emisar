defmodule Emisar.UsersTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Users
  alias Emisar.Users.User

  describe "register_user/1" do
    test "creates a user with a hashed password" do
      email = "reg-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} =
               Users.register_user(%{
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
               Users.register_user(%{
                 email: email,
                 password: "a-12-char-password"
               })

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns the user when found" do
      user = user_fixture()
      assert {:ok, %User{id: id}} = Users.fetch_user_by_email(user.email)
      assert id == user.id
    end

    test "returns :not_found for unknown email" do
      assert {:error, :not_found} =
               Users.fetch_user_by_email("nobody-#{System.unique_integer()}@example.test")
    end
  end

  describe "update_user_email/3" do
    test "updates the email when the current password verifies" do
      password = "current-password-12-chars"
      user = user_fixture(password: password)
      subject = %Emisar.Auth.Subject{actor: user}

      new = "new-#{System.unique_integer([:positive])}@example.test"
      assert {:ok, updated} = Users.update_user_email(new, password, subject)
      assert updated.email == new
    end

    test "refuses when the current password is wrong" do
      user = user_fixture()
      subject = %Emisar.Auth.Subject{actor: user}

      assert {:error, :invalid_current_password} =
               Users.update_user_email("x@y.test", "not-the-password", subject)
    end

    test "rejects a malformed email even with the right password" do
      password = "right-password-12-chars"
      user = user_fixture(password: password)
      subject = %Emisar.Auth.Subject{actor: user}

      assert {:error, %Ecto.Changeset{}} =
               Users.update_user_email("not-an-email", password, subject)
    end
  end
end
