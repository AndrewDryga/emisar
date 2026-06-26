defmodule Emisar.UsersTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Users
  alias Emisar.Users.User

  describe "register_user/1" do
    test "creates a user" do
      email = "reg-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} =
               Users.register_user(%{email: email, full_name: "Reggie"})

      assert user.email == email
      assert user.full_name == "Reggie"
    end

    test "rejects duplicate emails" do
      email = "dup-#{System.unique_integer([:positive])}@example.test"
      _ = user_fixture(email: email)

      assert {:error, changeset} = Users.register_user(%{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    # the email length cap (160) is inclusive: a 160-char
    # otherwise-valid address registers.
    test "accepts an email exactly 160 chars long" do
      email = String.duplicate("a", 160 - String.length("@example.test")) <> "@example.test"
      assert String.length(email) == 160

      assert {:ok, %User{}} = Users.register_user(%{email: email, full_name: "Edge"})
    end

    # one char over the 160 cap is rejected and nothing is
    # written.
    test "rejects an email over 160 chars with no user written" do
      email = String.duplicate("a", 161 - String.length("@example.test")) <> "@example.test"
      assert String.length(email) == 161

      assert {:error, changeset} = Users.register_user(%{email: email, full_name: "TooLong"})

      assert changeset.errors[:email]
      assert {:error, :not_found} = Users.fetch_user_by_email(email)
    end

    # the email format rule (`^[^\s]+@[^\s]+$`) rejects an
    # address with a space or no @, server-side (not just the form's type=email).
    test "rejects a malformed email (space, or no @)" do
      for bad <- ["foo bar@example.test", "nodomain"] do
        assert {:error, changeset} =
                 Users.register_user(%{email: bad, full_name: "Malformed"})

        assert "must have the @ sign and no spaces" in errors_on(changeset).email
      end
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

  describe "update_user_email/2" do
    test "updates the email — the authenticated session is the proof (no password)" do
      user = user_fixture()
      subject = %Emisar.Auth.Subject{actor: user}

      new = "new-#{System.unique_integer([:positive])}@example.test"
      assert {:ok, updated} = Users.update_user_email(new, subject)
      assert updated.email == new
    end

    test "rejects a malformed email" do
      user = user_fixture()
      subject = %Emisar.Auth.Subject{actor: user}

      assert {:error, %Ecto.Changeset{}} = Users.update_user_email("not-an-email", subject)
    end

    test "accepts an email of exactly 160 characters" do
      user = user_fixture()
      subject = %Emisar.Auth.Subject{actor: user}

      # local-part (147) + "@" + "example.test" (12) = 160 chars, the inclusive max.
      local = String.duplicate("a", 147)
      email = "#{local}@example.test"
      assert String.length(email) == 160

      assert {:ok, updated} = Users.update_user_email(email, subject)
      assert updated.email == email
    end

    test "rejects an email of 161 characters (over the max)" do
      user = user_fixture()
      subject = %Emisar.Auth.Subject{actor: user}

      email = "#{String.duplicate("a", 148)}@example.test"
      assert String.length(email) == 161

      assert {:error, changeset} = Users.update_user_email(email, subject)
      assert "should be at most 160 character(s)" in errors_on(changeset).email
      # Nothing was written — the original email stands.
      assert Repo.reload!(user).email == user.email
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

      assert {:ok, updated} = Users.record_sign_in(user, "magic_link")
      assert %DateTime{} = updated.last_sign_in_at

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["user.signed_in"]])

      assert event.payload["method"] == "magic_link"
      _ = account
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

    test "casts only full_name — a smuggled email is dropped by the whitelist" do
      account = account_fixture()
      user = user_fixture(email: "keep-me@example.test")
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      subject = subject_for(user, account, role: :owner)

      assert {:ok, %User{} = updated} =
               Users.update_user_profile(
                 %{
                   "full_name" => "Renamed Person",
                   "email" => "hijacked@example.test",
                   "role" => "owner"
                 },
                 subject
               )

      # Only the whitelisted field changed; email is untouched (the profile
      # changeset casts `[:full_name]` and nothing else).
      assert updated.full_name == "Renamed Person"
      assert updated.email == "keep-me@example.test"
    end

    test "writes against the freshly-fetched row, not the (possibly stale) subject snapshot" do
      account = account_fixture()
      user = user_fixture(email: "before@example.test")
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")

      # Build the subject from the ORIGINAL snapshot, then mutate the row out of
      # band (as a concurrent session would) so the snapshot is stale.
      subject = subject_for(user, account, role: :owner)

      {:ok, _} =
        user |> Ecto.Changeset.change(email: "after@example.test") |> Repo.update()

      # The self-service write re-reads under the row lock, so it preserves the
      # out-of-band email rather than clobbering it back to the stale snapshot.
      assert {:ok, %User{} = updated} =
               Users.update_user_profile(%{"full_name" => "Fresh Name"}, subject)

      assert updated.full_name == "Fresh Name"
      assert updated.email == "after@example.test"
      assert Repo.reload!(user).email == "after@example.test"
    end
  end
end
