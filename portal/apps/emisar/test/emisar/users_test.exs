defmodule Emisar.UsersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Crypto
  alias Emisar.Fixtures
  alias Emisar.Users
  alias Emisar.Users.User

  describe "fetch_and_lock_user_by_id/2" do
    test "returns the user, held for the rest of the transaction" do
      user = Fixtures.Users.create_user()

      assert {:ok, locked} = Users.fetch_and_lock_user_by_id(user.id, Repo)
      assert locked.id == user.id
    end

    test "a missing user is not found" do
      assert Users.fetch_and_lock_user_by_id(Ecto.UUID.generate(), Repo) == {:error, :not_found}
    end
  end

  describe "fetch_user_by_id/1" do
    test "a malformed id is a clean :not_found" do
      assert Users.fetch_user_by_id("not-a-uuid") == {:error, :not_found}
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns the user when found" do
      user = Fixtures.Users.create_user()
      assert {:ok, %User{id: id}} = Users.fetch_user_by_email(user.email)
      assert id == user.id
    end

    test "returns :not_found for unknown email" do
      assert Users.fetch_user_by_email("nobody-#{System.unique_integer()}@example.test") ==
               {:error, :not_found}
    end
  end

  describe "register_user/2" do
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

    # one char over the RFC 5321 maximum is rejected and nothing is written.
    test "rejects an email past the RFC 5321 maximum with no user written" do
      email = String.duplicate("a", 255 - String.length("@example.test")) <> "@example.test"
      assert String.length(email) == 255

      assert {:error, changeset} = Users.register_user(%{email: email, full_name: "TooLong"})

      assert "should be at most 254 character(s)" in errors_on(changeset).email
      assert Users.fetch_user_by_email(email) == {:error, :not_found}
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

  describe "put_sign_in/4" do
    test "composes the sign-in update and audit into the caller's transaction" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %{caller_step: :kept, sign_in: updated}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:caller_step, fn _repo, _changes -> {:ok, :kept} end)
               |> Users.put_sign_in(user, "magic_link", %Emisar.RequestContext{})
               |> Repo.commit_multi()

      assert %DateTime{} = updated.last_sign_in_at

      assert {:ok, [event], _} =
               Audit.list_events(subject, filter: [event_type: ["user.signed_in"]])

      assert event.payload["method"] == "magic_link"
    end
  end

  describe "put_mfa_enrollment/6" do
    test "composes the credential update and audit into the caller's transaction" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      enabled_at = DateTime.utc_now()
      recovery_digest = Crypto.hash("recovery-code")

      assert {:ok, %{mfa_enrollment: updated}} =
               Ecto.Multi.new()
               |> Users.put_mfa_enrollment(
                 user,
                 "mfa-secret",
                 enabled_at,
                 [recovery_digest],
                 %Emisar.RequestContext{}
               )
               |> Repo.commit_multi()

      assert updated.mfa_secret == "mfa-secret"
      assert updated.mfa_enabled_at == enabled_at
      assert updated.mfa_recovery_codes == [recovery_digest]

      assert {:ok, [event], _} =
               Audit.list_events(subject, filter: [event_type: ["user.mfa_enabled"]])

      assert event.actor_id == user.id
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
      assert {:error, changeset} = Users.update_user_email("not-an-email", subject)
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end

    test "accepts an email of exactly 160 characters", %{subject: subject} do
      # local-part (147) + "@" + "example.test" (12) = 160 chars, the inclusive max.
      local = String.duplicate("a", 147)
      email = "#{local}@example.test"
      assert String.length(email) == 160

      assert {:ok, updated} = Users.update_user_email(email, subject)
      assert updated.email == email
    end

    test "rejects an email past the RFC 5321 maximum", %{user: user, subject: subject} do
      email = "#{String.duplicate("a", 242)}@example.test"
      assert String.length(email) == 255

      assert {:error, changeset} = Users.update_user_email(email, subject)
      assert "should be at most 254 character(s)" in errors_on(changeset).email
      # Nothing was written — the original email stands.
      assert Repo.reload!(user).email == user.email
    end

    test "accepts an address at the maximum", %{subject: subject} do
      email = "#{String.duplicate("a", 241)}@example.test"
      assert String.length(email) == 254

      assert {:ok, updated} = Users.update_user_email(email, subject)
      assert updated.email == email
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

      assert changeset.valid?
      assert changeset.changes == %{full_name: "Renamed"}
      assert Repo.reload!(user).full_name == user.full_name
    end

    test "with no attrs, yields a valid, change-free changeset" do
      user = Fixtures.Users.create_user()

      changeset = Users.change_user(user)

      assert changeset.valid?
      assert changeset.changes == %{}
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
      refute is_nil(user.confirmed_at)
    end

    test "provisions a no-email user (a no-email IdP / unverified claim → nil)" do
      assert {:ok, %User{email: nil} = user} =
               Users.provision_sso_user(%{full_name: "Anonymous SSO"})

      refute is_nil(user.confirmed_at)
    end

    test "a colliding email is :email_taken, never a silent merge (takeover guard §9 C1)" do
      existing = Fixtures.Users.create_user(email: "taken@example.test")

      assert Users.provision_sso_user(%{email: "taken@example.test", full_name: "Impostor"}) ==
               {:error, :email_taken}

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

  describe "regenerate_user_mfa_recovery_codes/5" do
    test "proves a recovery digest and replaces the set in the same locked update" do
      {user, _account, _subject} = enrolled_owner()
      proof_digest = Crypto.hash("current-proof")
      new_digests = [Crypto.hash("fresh-1"), Crypto.hash("fresh-2"), Crypto.hash("fresh-3")]

      {:ok, user} =
        Users.update_user_mfa(
          user.id,
          user.mfa_secret,
          user.mfa_enabled_at,
          [proof_digest],
          audit: &Audit.user_changesets(&1, "user.mfa_enabled")
        )

      assert {:ok, %User{} = updated} =
               Users.regenerate_user_mfa_recovery_codes(
                 user.id,
                 {:recovery_code, proof_digest},
                 new_digests,
                 DateTime.utc_now(),
                 audit: &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated")
               )

      assert updated.mfa_recovery_codes == new_digests
      assert Repo.reload!(user).mfa_recovery_codes == new_digests
    end

    test "refuses with :mfa_not_enabled when MFA is off — judged on the locked row" do
      user = Fixtures.Users.create_user()

      assert Users.regenerate_user_mfa_recovery_codes(
               user.id,
               {:totp, "000000"},
               [Crypto.hash("nope")],
               DateTime.utc_now(),
               audit: &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated")
             ) == {:error, :mfa_not_enabled}

      assert Repo.reload!(user).mfa_recovery_codes == []
    end
  end

  describe "consume_user_mfa_recovery_code/3" do
    setup do
      {user, account, subject} = enrolled_owner()
      digest_a = Crypto.hash("recover-a")
      digest_b = Crypto.hash("recover-b")

      {:ok, _} =
        Users.update_user_mfa(
          user.id,
          user.mfa_secret,
          user.mfa_enabled_at,
          [digest_a, digest_b],
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

      assert updated.mfa_recovery_codes == [digest_b]

      assert Users.consume_user_mfa_recovery_code(user.id, digest_a,
               audit: &Audit.user_changesets(&1, "user.mfa_recovery_code_used")
             ) == {:error, :invalid}
    end

    test "an unknown digest is :invalid and consumes nothing", %{
      user: user,
      digest_a: digest_a,
      digest_b: digest_b
    } do
      assert Users.consume_user_mfa_recovery_code(user.id, Crypto.hash("never-issued"),
               audit: &Audit.user_changesets(&1, "user.mfa_recovery_code_used")
             ) == {:error, :invalid}

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

      assert {:ok, %User{}} = Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now())
      assert %DateTime{} = Repo.reload!(user).mfa_last_used_at
    end

    test "the same code re-submitted in its 30s bucket is a :replay", %{
      user: user,
      secret: secret
    } do
      at = DateTime.utc_now()
      otp = NimbleTOTP.verification_code(secret, time: at)

      assert {:ok, %User{}} = Users.verify_and_consume_mfa(user.id, otp, at)
      assert Users.verify_and_consume_mfa(user.id, otp, at) == {:error, :replay}
    end

    test "a wrong code is :invalid", %{user: user} do
      assert Users.verify_and_consume_mfa(user.id, "000000", DateTime.utc_now()) ==
               {:error, :invalid}
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

      assert Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now()) == {:error, :invalid}
    end
  end

  describe "fetch_or_create_user_by_email/1" do
    test "creates a placeholder user for an unknown email" do
      email = "invite-#{System.unique_integer([:positive])}@example.test"

      assert {:ok, %User{} = user} = Users.fetch_or_create_user_by_email(email)
      assert user.email == email
      assert is_nil(user.confirmed_at)
    end

    test "returns the existing row for a known email — no duplicate, idempotent" do
      existing = Fixtures.Users.create_user(email: "already@example.test")

      assert {:ok, %User{id: id}} = Users.fetch_or_create_user_by_email("already@example.test")
      assert id == existing.id

      assert {:ok, %User{id: ^id}} = Users.fetch_or_create_user_by_email("already@example.test")
    end
  end

  describe "register_invited_user/2" do
    test "sets the full_name and marks the invited user confirmed" do
      {:ok, user} = Users.fetch_or_create_user_by_email("joiner@example.test")
      assert is_nil(user.confirmed_at)

      assert {:ok, %User{} = registered} =
               Users.register_invited_user(user, %{full_name: "Joined Member"})

      assert registered.full_name == "Joined Member"
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

      member =
        Fixtures.Users.set_mfa_state(Fixtures.Users.create_user(),
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: [Crypto.hash("digest-a"), Crypto.hash("digest-b")]
        )

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

  describe "delete_by_id/2" do
    test "hard-deletes the user row and user-owned memberships" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
      user_id = user.id

      assert {:ok, %User{id: ^user_id}} = Users.delete_by_id(user_id, repo: Repo)

      assert Repo.one(User.Query.all() |> User.Query.by_id(user_id)) == nil

      assert Repo.one(
               Emisar.Accounts.Membership.Query.all()
               |> Emisar.Accounts.Membership.Query.by_user_id(user_id)
             ) == nil
    end

    test "returns not_found for malformed or unknown ids" do
      assert Users.delete_by_id("not-a-uuid", repo: Repo) == {:error, :not_found}
      assert Users.delete_by_id(Ecto.UUID.generate(), repo: Repo) == {:error, :not_found}
    end
  end

  # An owner user with MFA enrolled (secret + enrolled-at), so the locked-row
  # MFA-enabled guard in regenerate_user_mfa_recovery_codes / consume passes. Returns
  # the {user, account, subject} tuple owner_subject/0 yields.
  defp enrolled_owner do
    {user, account, subject} = Fixtures.Subjects.owner_subject()

    {:ok, enrolled} =
      Users.update_user_mfa(user.id, "JBSWY3DPEHPK3PXP", DateTime.utc_now(), [],
        audit: &Audit.user_changesets(&1, "user.mfa_enabled")
      )

    {enrolled, account, subject}
  end
end
