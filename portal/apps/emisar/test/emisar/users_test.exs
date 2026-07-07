defmodule Emisar.UsersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Crypto
  alias Emisar.Fixtures
  alias Emisar.Users
  alias Emisar.Users.User

  describe "fetch_user_by_id/1" do
    test "a malformed id is a clean :not_found" do
      assert {:error, :not_found} = Users.fetch_user_by_id("not-a-uuid")
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns the user when found" do
      user = Fixtures.Users.create_user()
      assert {:ok, %User{id: id}} = Users.fetch_user_by_email(user.email)
      assert id == user.id
    end

    test "returns :not_found for unknown email" do
      assert {:error, :not_found} =
               Users.fetch_user_by_email("nobody-#{System.unique_integer()}@example.test")
    end
  end

  describe "user_labels_for_ids/1" do
    test "labels by full name, falls back to email, skips nils and dedupes" do
      named = Fixtures.Users.create_user(full_name: "Ada Lovelace")
      unnamed = Fixtures.Users.create_user(full_name: nil)

      labels = Users.user_labels_for_ids([named.id, unnamed.id, nil, named.id])

      assert labels[named.id] == "Ada Lovelace"
      assert labels[unnamed.id] == unnamed.email
      assert map_size(labels) == 2
      assert Users.user_labels_for_ids([]) == %{}
    end
  end

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
      _ = Fixtures.Users.create_user(email: email)

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

  describe "record_sign_in/3" do
    test "stamps the sign-in and audits user.signed_in with the method" do
      {user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, updated} = Users.record_sign_in(user, "magic_link")
      assert %DateTime{} = updated.last_sign_in_at

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["user.signed_in"]])

      assert event.payload["method"] == "magic_link"
      _ = account
    end
  end

  describe "update_user_profile/2 (self-service)" do
    setup do
      %{account: Fixtures.Accounts.create_account()}
    end

    test "updates the caller's own full name", %{account: account} do
      user = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      assert {:ok, %User{full_name: "Renamed Person"}} =
               Users.update_user_profile(%{"full_name" => "Renamed Person"}, subject)
    end

    test "casts only full_name — a smuggled email is dropped by the whitelist", %{
      account: account
    } do
      user = Fixtures.Users.create_user(email: "keep-me@example.test")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

    test "writes against the freshly-fetched row, not the (possibly stale) subject snapshot",
         %{account: account} do
      user = Fixtures.Users.create_user(email: "before@example.test")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      # Build the subject from the ORIGINAL snapshot, then mutate the row out of
      # band (as a concurrent session would) so the snapshot is stale.
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

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

  describe "update_user_email/2" do
    setup do
      user = Fixtures.Users.create_user()
      subject = %Subject{actor: user}
      %{user: user, subject: subject}
    end

    test "updates the email — the authenticated session is the proof (no password)", %{
      subject: subject
    } do
      new = "new-#{System.unique_integer([:positive])}@example.test"
      assert {:ok, updated} = Users.update_user_email(new, subject)
      assert updated.email == new
    end

    test "rejects a malformed email", %{subject: subject} do
      assert {:error, %Ecto.Changeset{}} = Users.update_user_email("not-an-email", subject)
    end

    test "accepts an email of exactly 160 characters", %{subject: subject} do
      # local-part (147) + "@" + "example.test" (12) = 160 chars, the inclusive max.
      local = String.duplicate("a", 147)
      email = "#{local}@example.test"
      assert String.length(email) == 160

      assert {:ok, updated} = Users.update_user_email(email, subject)
      assert updated.email == email
    end

    test "rejects an email of 161 characters (over the max)", %{user: user, subject: subject} do
      email = "#{String.duplicate("a", 148)}@example.test"
      assert String.length(email) == 161

      assert {:error, changeset} = Users.update_user_email(email, subject)
      assert "should be at most 160 character(s)" in errors_on(changeset).email
      # Nothing was written — the original email stands.
      assert Repo.reload!(user).email == user.email
    end
  end

  describe "correct_unconfirmed_user_email/3" do
    test "updates an unconfirmed signup email and audits the correction" do
      user = Fixtures.Users.create_user(confirmed?: false)
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      new_email = "corrected-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = updated} =
               Users.correct_unconfirmed_user_email(user.id, new_email)

      assert updated.email == new_email
      assert Repo.reload!(user).email == new_email

      {:ok, [event], _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["user.email_changed"]])

      assert event.payload["from"] == user.email
      assert event.payload["to"] == new_email
      assert event.payload["method"] == "signup_correction"
      _ = account
    end

    test "refuses after the user is confirmed" do
      user = Fixtures.Users.create_user() |> Fixtures.Users.confirm_user()
      new_email = "too-late-#{System.unique_integer([:positive])}@example.test"

      assert Users.correct_unconfirmed_user_email(user.id, new_email) ==
               {:error, :already_confirmed}

      assert Repo.reload!(user).email == user.email
    end

    test "rejects invalid replacement emails without writing" do
      user = Fixtures.Users.create_user(confirmed?: false)

      assert {:error, changeset} = Users.correct_unconfirmed_user_email(user.id, "not-an-email")
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      assert Repo.reload!(user).email == user.email
    end
  end

  describe "change_user/2" do
    test "builds a registration changeset for the form (no DB write)" do
      user = Fixtures.Users.create_user()

      changeset = Users.change_user(user, %{full_name: "Renamed"})

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :full_name) == "Renamed"
      # It's a pure builder — the row on disk is untouched.
      assert Repo.reload!(user).full_name == user.full_name
    end

    test "with no attrs, yields a valid, change-free changeset" do
      user = Fixtures.Users.create_user()

      changeset = Users.change_user(user)

      assert %Ecto.Changeset{valid?: true, changes: changes} = changeset
      assert changes == %{}
    end

    test "surfaces the email-format error for the inline form" do
      user = Fixtures.Users.create_user()

      changeset = Users.change_user(user, %{email: "no-at-sign"})

      refute changeset.valid?
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end
  end

  describe "mark_user_confirmed/1" do
    test "stamps confirmed_at on a freshly-registered (unconfirmed) user" do
      user = Fixtures.Users.create_user(confirmed?: false)
      assert is_nil(user.confirmed_at)

      assert {:ok, %User{confirmed_at: %DateTime{}} = confirmed} =
               Users.mark_user_confirmed(user)

      assert confirmed.id == user.id
      assert %DateTime{} = Repo.reload!(user).confirmed_at
    end
  end

  describe "provision_sso_user/1" do
    test "creates a confirmed, password-less user (the IdP is the credential)" do
      email = "sso-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} =
               Users.provision_sso_user(%{email: email, full_name: "SSO Person"})

      assert user.email == email
      assert user.full_name == "SSO Person"
      # The IdP is the email authority, so JIT-provisioned users are confirmed.
      refute is_nil(user.confirmed_at)
    end

    test "provisions a no-email user (a no-email IdP / unverified claim → nil)" do
      assert {:ok, %User{email: nil} = user} =
               Users.provision_sso_user(%{full_name: "Anonymous SSO"})

      refute is_nil(user.confirmed_at)
    end

    test "a colliding email is :email_taken, never a silent merge (takeover guard §9 C1)" do
      existing = Fixtures.Users.create_user(email: "taken@example.test")

      assert {:error, :email_taken} =
               Users.provision_sso_user(%{email: "taken@example.test", full_name: "Impostor"})

      # The pre-existing identity is untouched — no merge, no overwrite.
      assert Repo.reload!(existing).full_name == existing.full_name
    end
  end

  describe "update_user_mfa/5" do
    test "enabling sets the secret, enrolled-at, recovery digests, and clears the replay stamp" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      digests = [Crypto.hash("code-a"), Crypto.hash("code-b")]

      assert {:ok, %User{} = updated} =
               Users.update_user_mfa(user.id, "JBSWY3DPEHPK3PXP", DateTime.utc_now(), digests,
                 audit: &Audit.user_changesets(&1, "user.mfa_enabled")
               )

      assert updated.mfa_secret == "JBSWY3DPEHPK3PXP"
      assert %DateTime{} = updated.mfa_enabled_at
      assert updated.mfa_recovery_codes == digests
      assert is_nil(updated.mfa_last_used_at)
    end

    test "disabling clears every MFA field (secret + enrolled-at + recovery codes)" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()

      {:ok, _} =
        Users.update_user_mfa(user.id, "JBSWY3DPEHPK3PXP", DateTime.utc_now(), [Crypto.hash("x")],
          audit: &Audit.user_changesets(&1, "user.mfa_enabled")
        )

      assert {:ok, %User{} = disabled} =
               Users.update_user_mfa(user.id, nil, nil, [],
                 audit: &Audit.user_changesets(&1, "user.mfa_disabled")
               )

      assert is_nil(disabled.mfa_secret)
      assert is_nil(disabled.mfa_enabled_at)
      assert disabled.mfa_recovery_codes == []
      assert is_nil(Repo.reload!(user).mfa_enabled_at)
    end
  end

  describe "put_user_mfa_recovery_codes/3" do
    test "replaces the stored digests when MFA is enabled" do
      {user, _account, _subject} = enrolled_owner()
      new_digests = [Crypto.hash("fresh-1"), Crypto.hash("fresh-2"), Crypto.hash("fresh-3")]

      assert {:ok, %User{} = updated} =
               Users.put_user_mfa_recovery_codes(user.id, new_digests,
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated")
               )

      assert updated.mfa_recovery_codes == new_digests
      assert Repo.reload!(user).mfa_recovery_codes == new_digests
    end

    test "refuses with :mfa_not_enabled when MFA is off — judged on the locked row" do
      # A plain user has never enrolled, so the locked-row guard refuses and
      # writes nothing.
      user = Fixtures.Users.create_user()

      assert {:error, :mfa_not_enabled} =
               Users.put_user_mfa_recovery_codes(user.id, [Crypto.hash("nope")],
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated")
               )

      assert Repo.reload!(user).mfa_recovery_codes == []
    end
  end

  describe "consume_user_mfa_recovery_code/3" do
    setup do
      {user, account, subject} = enrolled_owner()
      digest_a = Crypto.hash("recover-a")
      digest_b = Crypto.hash("recover-b")

      {:ok, _} =
        Users.put_user_mfa_recovery_codes(user.id, [digest_a, digest_b],
          audit: &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated")
        )

      %{user: user, account: account, subject: subject, digest_a: digest_a, digest_b: digest_b}
    end

    test "consumes a matching code exactly once, leaving the rest", %{
      user: user,
      digest_a: digest_a,
      digest_b: digest_b
    } do
      assert {:ok, %User{} = updated} =
               Users.consume_user_mfa_recovery_code(user.id, digest_a,
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_code_used")
               )

      # The used digest is gone; the unused one remains.
      assert updated.mfa_recovery_codes == [digest_b]

      # Re-presenting the now-consumed code is :invalid — single-use.
      assert {:error, :invalid} =
               Users.consume_user_mfa_recovery_code(user.id, digest_a,
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_code_used")
               )
    end

    test "an unknown digest is :invalid and consumes nothing", %{
      user: user,
      digest_a: digest_a,
      digest_b: digest_b
    } do
      assert {:error, :invalid} =
               Users.consume_user_mfa_recovery_code(user.id, Crypto.hash("never-issued"),
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_code_used")
               )

      assert Repo.reload!(user).mfa_recovery_codes == [digest_a, digest_b]
    end
  end

  describe "verify_and_consume_mfa/3" do
    setup do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()
      secret = Crypto.totp_secret()

      {:ok, _} =
        Users.update_user_mfa(user.id, secret, DateTime.utc_now(), [],
          audit: &Audit.user_changesets(&1, "user.mfa_enabled")
        )

      %{user: user, secret: secret}
    end

    test "a valid OTP verifies and stamps the consumed bucket", %{user: user, secret: secret} do
      otp = NimbleTOTP.verification_code(secret)

      assert :ok = Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now())
      assert %DateTime{} = Repo.reload!(user).mfa_last_used_at
    end

    test "the same code re-submitted in its 30s bucket is a :replay", %{
      user: user,
      secret: secret
    } do
      at = DateTime.utc_now()
      otp = NimbleTOTP.verification_code(secret, time: at)

      assert :ok = Users.verify_and_consume_mfa(user.id, otp, at)
      # Same code, same 30-second bucket → the locked replay guard rejects it.
      assert {:error, :replay} = Users.verify_and_consume_mfa(user.id, otp, at)
    end

    test "a wrong code is :invalid", %{user: user} do
      assert {:error, :invalid} =
               Users.verify_and_consume_mfa(user.id, "000000", DateTime.utc_now())
    end

    test "MFA disabled mid-flight makes a once-valid code :invalid (judged on the locked row)", %{
      user: user,
      secret: secret
    } do
      otp = NimbleTOTP.verification_code(secret)

      {:ok, _} =
        Users.update_user_mfa(user.id, nil, nil, [],
          audit: &Audit.user_changesets(&1, "user.mfa_disabled")
        )

      assert {:error, :invalid} = Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now())
    end
  end

  describe "fetch_or_create_user_by_email/1" do
    test "creates a placeholder user for an unknown email" do
      email = "invite-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} = Users.fetch_or_create_user_by_email(email)
      assert user.email == email
      # The placeholder hangs an invitation off it — unconfirmed until accepted.
      assert is_nil(user.confirmed_at)
    end

    test "returns the existing row for a known email — no duplicate, idempotent" do
      existing = Fixtures.Users.create_user(email: "already@example.test")

      assert {:ok, %User{id: id}} = Users.fetch_or_create_user_by_email("already@example.test")
      assert id == existing.id

      # A second call still resolves the same single row (re-fetch path).
      assert {:ok, %User{id: ^id}} = Users.fetch_or_create_user_by_email("already@example.test")
    end
  end

  describe "register_invited_user/2" do
    test "sets the full_name and marks the invited user confirmed" do
      # A placeholder created by an invite is unconfirmed and nameless until
      # the invitee accepts.
      {:ok, user} = Users.fetch_or_create_user_by_email("joiner@example.test")
      assert is_nil(user.confirmed_at)

      assert {:ok, %User{} = registered} =
               Users.register_invited_user(user, %{full_name: "Joined Member"})

      assert registered.full_name == "Joined Member"
      # Accepting proves email ownership → confirmed.
      refute is_nil(registered.confirmed_at)
      assert %DateTime{} = Repo.reload!(user).confirmed_at
    end
  end

  describe "update_user_profile_as_admin/3" do
    test "edits the member's full_name on the locked row" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Users.create_user(full_name: "Old Name")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      assert {:ok, %User{full_name: "New Name"}} =
               Users.update_user_profile_as_admin(member.id, %{"full_name" => "New Name"},
                 audit: &Audit.user_changesets(&1, "user.profile_updated_by_admin")
               )

      assert Repo.reload!(member).full_name == "New Name"
    end

    test "whitelists full_name only — a smuggled email is dropped" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Users.create_user(email: "member-keep@example.test")

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      assert {:ok, %User{} = updated} =
               Users.update_user_profile_as_admin(
                 member.id,
                 %{"full_name" => "Renamed", "email" => "hijacked@example.test"},
                 audit: &Audit.user_changesets(&1, "user.profile_updated_by_admin")
               )

      assert updated.full_name == "Renamed"
      assert updated.email == "member-keep@example.test"
    end
  end

  describe "sync_user_full_name/3" do
    test "replaces the user's display name under the row lock" do
      user = Fixtures.Users.create_user(full_name: "Old Name")

      assert {:ok, %User{full_name: "Synced Name"}} =
               Users.sync_user_full_name(user.id, "Synced Name",
                 audit: &Audit.user_changesets(&1, "user.renamed_via_scim")
               )

      assert Repo.reload!(user).full_name == "Synced Name"
    end

    test "an already-matching name is a no-op — no write, no audit row" do
      user = Fixtures.Users.create_user(full_name: "Same Name")

      assert {:ok, %User{full_name: "Same Name"}} =
               Users.sync_user_full_name(user.id, "Same Name",
                 audit: &Audit.user_changesets(&1, "user.renamed_via_scim")
               )

      assert Repo.all(Emisar.Audit.Event) == []
    end

    test "an unknown user is :not_found" do
      assert Users.sync_user_full_name(Ecto.UUID.generate(), "Anyone",
               audit: &Audit.user_changesets(&1, "user.renamed_via_scim")
             ) == {:error, :not_found}
    end
  end

  describe "reset_user_mfa/2" do
    test "clears every MFA field so the member re-enrolls a fresh factor" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      member = enroll_member_mfa(Fixtures.Users.create_user())

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      assert {:ok, %User{} = reset} =
               Users.reset_user_mfa(member.id,
                 audit: &Audit.user_changesets(&1, "user.mfa_reset_by_admin")
               )

      assert is_nil(reset.mfa_secret)
      assert is_nil(reset.mfa_enabled_at)
      assert reset.mfa_recovery_codes == []

      reloaded = Repo.reload!(member)
      assert is_nil(reloaded.mfa_enabled_at)
    end
  end

  # An owner user with MFA enrolled (secret + enrolled-at), so the locked-row
  # MFA-enabled guard in put_user_mfa_recovery_codes / consume passes. Returns
  # the {user, account, subject} tuple owner_subject/0 yields.
  defp enrolled_owner do
    {user, account, subject} = Fixtures.Subjects.owner_subject()

    {:ok, enrolled} =
      Users.update_user_mfa(user.id, "JBSWY3DPEHPK3PXP", DateTime.utc_now(), [],
        audit: &Audit.user_changesets(&1, "user.mfa_enabled")
      )

    {enrolled, account, subject}
  end

  # Fully enroll a member's MFA — secret + enrolled-at + recovery codes — so
  # reset_user_mfa's "every field is wiped" assertion is meaningful.
  defp enroll_member_mfa(%User{} = user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: [Crypto.hash("digest-a"), Crypto.hash("digest-b")]
      )
      |> Repo.update()

    user
  end
end
