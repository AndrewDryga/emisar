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

  describe "fetch_user_by_id/1" do
    test "a malformed id is a clean :not_found" do
      assert {:error, :not_found} = Users.fetch_user_by_id("not-a-uuid")
    end
  end

  describe "user_labels_for_ids/1" do
    test "labels by full name, falls back to email, skips nils and dedupes" do
      named = user_fixture(full_name: "Ada Lovelace")
      unnamed = user_fixture(full_name: nil)

      labels = Users.user_labels_for_ids([named.id, unnamed.id, nil, named.id])

      assert labels[named.id] == "Ada Lovelace"
      assert labels[unnamed.id] == unnamed.email
      assert map_size(labels) == 2
      assert Users.user_labels_for_ids([]) == %{}
    end
  end

  describe "record_sign_in/2" do
    test "stamps the sign-in and audits user.signed_in with the method" do
      {user, account, subject} = owner_subject_fixture()

      assert {:ok, updated} = Users.record_sign_in(user, "password")
      assert %DateTime{} = updated.last_sign_in_at

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["user.signed_in"]])

      assert event.payload["method"] == "password"
      _ = account
    end
  end

  describe "change_password/2" do
    test "validates without hashing so the form can round-trip the field" do
      user = user_fixture()

      changeset = Users.change_password(user, %{"password" => "short"})
      refute changeset.valid?

      changeset = Users.change_password(user, %{"password" => "long-enough-password-123"})
      assert changeset.valid?
      # hash_password: false keeps it pure — nothing consumed the field.
      assert Ecto.Changeset.get_change(changeset, :password)
      refute Ecto.Changeset.get_change(changeset, :hashed_password)
    end
  end

  describe "change_user_password/3 (self-service)" do
    setup do
      pw = "current-password-1234"
      account = account_fixture()
      user = user_fixture(password: pw)
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      %{user: user, subject: subject_for(user, account, role: :owner), pw: pw}
    end

    test "with the correct current password, rotates the credential", %{
      user: user,
      subject: subject,
      pw: pw
    } do
      assert {:ok, %User{}} = Users.change_user_password(pw, "a-new-password-5678", subject)
      assert User.valid_password?(Repo.reload!(user), "a-new-password-5678")
    end

    test "with the wrong current password, refuses with :invalid_current_password", %{
      subject: subject
    } do
      assert {:error, :invalid_current_password} =
               Users.change_user_password("wrong-current-xxxx", "a-new-password-5678", subject)
    end
  end

  describe "update_user_profile/2 (self-service)" do
    test "updates the caller's own full name" do
      account = account_fixture()
      user = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)

      assert {:ok, %User{full_name: "Renamed Person"}} =
               Users.update_user_profile(%{"full_name" => "Renamed Person"}, subject)
    end
  end
end
