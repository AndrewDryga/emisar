defmodule Emisar.InvitationTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Billing, Crypto, Fixtures, Repo, RequestContext, Users}
  alias Emisar.Accounts.{Account, Membership, RunnerAccess}
  alias Emisar.Users.User

  defp inviter_subject(account) do
    inviter = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

    {inviter, Fixtures.Subjects.subject_for(inviter, account, role: :owner)}
  end

  describe "change_invitation/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      %{account: account, subject: subject}
    end

    test "defaults to an operator with no runner access", %{subject: subject} do
      assert {:ok, changeset} = Accounts.change_invitation(%{}, subject)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).email
      assert Ecto.Changeset.get_field(changeset, :role) == "operator"
      assert Ecto.Changeset.get_field(changeset, :runner_access_mode) == "none"
      assert Ecto.Changeset.get_field(changeset, :runner_access) == RunnerAccess.none()
    end

    test "reports a malformed email and an out-of-set role on their fields", %{subject: subject} do
      attrs = Fixtures.Accounts.invitation_attrs(email: "b ob@x.com", role: "superadmin")

      assert {:ok, changeset} = Accounts.change_invitation(attrs, subject)

      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      assert "is invalid" in errors_on(changeset).role
    end

    test "canonicalizes a group + runner selection, dropping the covered runner", %{
      account: account,
      subject: subject
    } do
      database = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      web = Fixtures.Runners.create_runner(account_id: account.id, group: "web")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          runner_access_mode: "restricted",
          scope: ["group:database", "runner:#{database.id}", "runner:#{web.id}"]
        )

      assert {:ok, changeset} = Accounts.change_invitation(attrs, subject)

      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :runner_access) == %RunnerAccess{
               mode: :restricted,
               groups: ["database"],
               runner_ids: [web.id]
             }

      assert Ecto.Changeset.get_field(changeset, :scope) ==
               ["group:database", "runner:#{web.id}"]
    end

    test "rejects an empty, malformed, or foreign selection on the mode field", %{
      account: account,
      subject: subject
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      foreign_runner = Fixtures.Runners.create_runner(group: "database")

      for scope <- [[], ["all-runners"], ["group:staging"], ["runner:#{foreign_runner.id}"]] do
        attrs =
          Fixtures.Accounts.invitation_attrs(runner_access_mode: "restricted", scope: scope)

        assert {:ok, changeset} = Accounts.change_invitation(attrs, subject)

        assert "requires at least one runner group or runner" in errors_on(changeset).runner_access_mode
      end
    end

    test "a member without invite permission gets no changeset", %{account: account} do
      viewer_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      subject = Fixtures.Subjects.membership_subject(viewer_membership)

      assert Accounts.change_invitation(%{}, subject) == {:error, :unauthorized}
    end
  end

  describe "invite_user_to_account/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      %{account: account, subject: subject}
    end

    test "creates a placeholder user for a brand-new email", %{subject: subject} do
      assert {:ok,
              %{
                membership: membership,
                user: invitee,
                invitation_token: token
              }} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: "new@example.test", role: "admin"),
                 subject
               )

      assert invitee.email == "new@example.test"
      assert is_binary(token)
      assert byte_size(token) > 16
      assert membership.role == :admin
      assert membership.runner_access_mode == :none

      assert Accounts.runner_access_for_membership(membership.account_id, membership.id) ==
               RunnerAccess.none()

      # Only the digest is at rest — a DB leak must not expose the live link.
      assert membership.invitation_token_digest == Emisar.Crypto.user_invite_token_digest(token)
      refute membership.invitation_token_digest == token
      assert is_nil(membership.invitation_accepted_at)
    end

    test "Free advertises one user but does not enforce the member allowance", %{
      account: account,
      subject: subject
    } do
      assert Billing.plan("free").members_limit == 1

      for email <- ["first@example.test", "second@example.test"] do
        assert {:ok, %{membership: membership}} =
                 Accounts.invite_user_to_account(
                   Fixtures.Accounts.invitation_attrs(email: email),
                   subject
                 )

        assert membership.account_id == account.id
      end

      assert Accounts.count_memberships(account.id) == 3
    end

    test "reuses an existing user when the email already exists", %{subject: subject} do
      existing = Fixtures.Users.create_user(email: "alice@example.test")

      assert {:ok, %{user: invitee}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: "alice@example.test",
                   role: "operator",
                   runner_access_mode: "all"
                 ),
                 subject
               )

      assert invitee.id == existing.id
    end

    test "persists and audits normalized selected runner access on the invitation", %{
      account: account,
      subject: subject
    } do
      production = Fixtures.Runners.create_runner(account_id: account.id, group: "production")
      staging = Fixtures.Runners.create_runner(account_id: account.id, group: "staging")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          email: "scoped@example.test",
          runner_access_mode: "restricted",
          scope: [
            "group:production",
            "group:production",
            "runner:#{production.id}",
            "runner:#{staging.id}"
          ]
        )

      assert {:ok, %{membership: membership}} =
               Accounts.invite_user_to_account(attrs, subject)

      # The duplicate group collapses and the production runner disappears —
      # its group already covers it.
      assert Accounts.runner_access_for_memberships([membership])[membership.id] ==
               %RunnerAccess{
                 mode: :restricted,
                 groups: ["production"],
                 runner_ids: [staging.id]
               }

      assert {:ok, [event], _meta} =
               Emisar.Audit.list_events(subject, filter: [event_type: ["user.invited"]])

      assert event.payload["runner_access"] == %{
               "mode" => "restricted",
               "groups" => ["production"],
               "runner_ids" => [staging.id],
               "pack_mode" => "all",
               "pack_ids" => []
             }
    end

    test "rejects a runner or group from another account, writing nothing", %{subject: subject} do
      foreign_runner = Fixtures.Runners.create_runner(group: "foreign")

      for scope <- [["runner:#{foreign_runner.id}"], ["group:foreign"]] do
        attrs =
          Fixtures.Accounts.invitation_attrs(
            email: "foreign-scope@example.test",
            runner_access_mode: "restricted",
            scope: scope
          )

        assert {:error, changeset} = Accounts.invite_user_to_account(attrs, subject)

        assert "requires at least one runner group or runner" in errors_on(changeset).runner_access_mode
      end

      assert Emisar.Users.fetch_user_by_email("foreign-scope@example.test") ==
               {:error, :not_found}

      assert {:ok, [], _meta} = Emisar.Audit.list_events(subject)
    end

    test "refuses runner access beyond the inviter's current grant", %{
      account: account,
      subject: owner_subject
    } do
      database = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      _web = Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      {:ok, database_access} = RunnerAccess.restricted([], [database.id])
      admin = Fixtures.Memberships.force_runner_access(admin, database_access)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      attrs =
        Fixtures.Accounts.invitation_attrs(
          email: "over-grant@example.test",
          runner_access_mode: "restricted",
          scope: ["group:web"]
        )

      assert Accounts.invite_user_to_account(attrs, admin_subject) ==
               {:error, :runner_access_exceeds_subject}

      assert Emisar.Users.fetch_user_by_email("over-grant@example.test") == {:error, :not_found}
      assert {:ok, [], _meta} = Emisar.Audit.list_events(owner_subject)
    end

    test "a runner deleted after the form validated is refused at the write", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          email: "stale-scope@example.test",
          runner_access_mode: "restricted",
          scope: ["runner:#{runner.id}"]
        )

      # Advisory validation passes while the runner is live…
      assert {:ok, changeset} = Accounts.change_invitation(attrs, subject)
      assert changeset.valid?

      # …then it is retired before the operator submits.
      Fixtures.Runners.mark_deleted(runner)

      assert {:error, changeset} = Accounts.invite_user_to_account(attrs, subject)

      assert "requires at least one runner group or runner" in errors_on(changeset).runner_access_mode

      assert Emisar.Users.fetch_user_by_email("stale-scope@example.test") == {:error, :not_found}
    end

    test "an invalid submission returns the form changeset with nothing written", %{
      subject: subject
    } do
      attrs = Fixtures.Accounts.invitation_attrs(email: "not-an-email", role: "superadmin")

      assert {:error, changeset} = Accounts.invite_user_to_account(attrs, subject)

      assert changeset.action == :insert
      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      assert "is invalid" in errors_on(changeset).role
      assert {:ok, [], _meta} = Emisar.Audit.list_events(subject)
    end

    test "trims the email; the citext column owns case-insensitive identity", %{subject: subject} do
      assert {:ok, %{user: invitee}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: "  HELLO@Example.Test  ",
                   role: "viewer"
                 ),
                 subject
               )

      # Stored as typed (whitespace trimmed) — no app-side downcase.
      assert invitee.email == "HELLO@Example.Test"

      # A differently-cased invite resolves to the SAME user row: the
      # unique citext index is the guarantee, not normalization.
      other_account = Fixtures.Accounts.create_account()
      {_inviter, other_subject} = inviter_subject(other_account)

      assert {:ok, %{user: same_user}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: "hello@example.test", role: "viewer"),
                 other_subject
               )

      assert same_user.id == invitee.id
    end

    test "rolls back when the user already belongs to the account", %{
      account: account,
      subject: subject
    } do
      existing = Fixtures.Users.create_user()

      _existing_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: existing.id)

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(email: existing.email, role: "admin"),
               subject
             ) == {:error, :already_member}
    end

    test "persists selected pack access on the invited membership" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")

      attrs =
        Fixtures.Accounts.invitation_attrs(
          role: "viewer",
          runner_access_mode: "all",
          pack_access_mode: "restricted",
          pack_scope: ["pack:postgres"]
        )

      assert {:ok, %{membership: membership}} = Accounts.invite_user_to_account(attrs, subject)

      assert Accounts.runner_access_for_memberships([membership])[membership.id] ==
               %RunnerAccess{
                 mode: :all,
                 groups: [],
                 runner_ids: [],
                 pack_mode: :restricted,
                 pack_ids: ["postgres"]
               }
    end

    test "a member without invite permission cannot invite a user" do
      account = Fixtures.Accounts.create_account()

      viewer_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      subject = Fixtures.Subjects.membership_subject(viewer_membership)
      email = "denied-invite-#{System.unique_integer([:positive])}@example.test"

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: email,
                 role: "operator",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :unauthorized}
    end

    test "refuses duplicate memberships" do
      inviter = Fixtures.Users.create_user()
      existing = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      Fixtures.Memberships.create_membership(account_id: account.id, user_id: existing.id)
      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: existing.email,
                 role: "operator",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :already_member}
    end

    test "an admin cannot invite an owner (can't grant a role it doesn't hold)" do
      admin = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      email = "owner-invite-#{System.unique_integer([:positive])}@example.test"

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: email,
                 role: "owner",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :insufficient_privileges}
    end

    test "member allowance is not enforced — a Free account can invite a large roster" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      # Free is advertised for one user, but invitation is deliberately not a
      # billing-enforcement boundary, so a large batch of invites all lands.
      for n <- 1..12 do
        email = "seat-#{n}-#{System.unique_integer([:positive])}@example.test"

        assert {:ok, %{membership: %Membership{}}} =
                 Accounts.invite_user_to_account(
                   Fixtures.Accounts.invitation_attrs(
                     email: email,
                     role: "viewer",
                     runner_access_mode: "all"
                   ),
                   subject
                 )
      end

      # All twelve invitees plus the owner are members — none was capped.
      assert Accounts.count_memberships(account.id) == 13
    end

    test "an invite always lands in the SUBJECT's account — B's owner can't seed account A" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      subject_b = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account_b)

      email = "cross-#{System.unique_integer([:positive])}@example.test"

      # The membership's account is read off `subject.account`, so B's owner can
      # only ever invite into B — there is no caller-supplied account id to
      # redirect the invite into A.
      assert {:ok, %{membership: %Membership{account_id: account_id}, user: invitee}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 subject_b
               )

      assert account_id == account_b.id
      # And nothing was written into A: the invitee has no membership there.
      assert is_nil(Fixtures.Memberships.fetch_membership(account_a.id, invitee.id))
    end
  end

  describe "fetch_invitation_by_token/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: token, user: invitee}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "bob@example.test", role: "admin"),
          subject
        )

      %{membership: membership, token: token, invitee: invitee, account: account}
    end

    test "preloads are caller-driven: opted-in assocs load, the default loads none", %{
      token: token,
      account: account,
      invitee: invitee
    } do
      assert {:ok, membership} =
               Accounts.fetch_invitation_by_token(token, preload: [:account, :user])

      assert membership.account.id == account.id
      assert membership.user.id == invitee.id

      # Without the opt the row comes back bare — callers that only need
      # the membership itself pay for no joins.
      assert {:ok, bare} = Accounts.fetch_invitation_by_token(token)
      assert %Ecto.Association.NotLoaded{} = bare.account
      assert %Ecto.Association.NotLoaded{} = bare.user
    end

    test "returns :not_found for an unknown token" do
      assert Accounts.fetch_invitation_by_token("bogus") == {:error, :not_found}
    end

    test "returns :not_found for nil / empty token (no leaky scan)" do
      # the lookup's head requires a non-empty binary
      # (`is_binary(token) and byte_size(token) > 0`); a nil or "" token falls to
      # the catch-all `:not_found` clause rather than scanning. So an empty token
      # param can never resolve an invite — the accept LV renders that
      # `:not_found` as the cause-neutral "Invitation unavailable" page.
      assert Accounts.fetch_invitation_by_token(nil) == {:error, :not_found}
      assert Accounts.fetch_invitation_by_token("") == {:error, :not_found}
    end

    test "an expired invitation reports :expired (the bearer holds the real token)",
         %{membership: membership, token: token} do
      # inserted_at IS the invite time (re-invites insert fresh rows) —
      # backdate it past the validity window.
      nine_days_ago = DateTime.add(DateTime.utc_now(), -9 * 24 * 3600, :second)
      {:ok, _} = membership |> Ecto.Changeset.change(inserted_at: nine_days_ago) |> Repo.update()

      assert Accounts.fetch_invitation_by_token(token) == {:error, :expired}
    end

    # the 7-day window (Membership.Query.invitation_not_expired).
    test "an invite just inside 7 days still resolves", %{membership: membership, token: token} do
      almost_seven = DateTime.add(DateTime.utc_now(), -(7 * 24 * 3600 - 3600), :second)
      {:ok, _} = membership |> Ecto.Changeset.change(inserted_at: almost_seven) |> Repo.update()

      assert {:ok, _} = Accounts.fetch_invitation_by_token(token)
    end

    test "an invite just past 7 days reports :expired", %{membership: membership, token: token} do
      just_over_seven = DateTime.add(DateTime.utc_now(), -(7 * 24 * 3600 + 3600), :second)

      {:ok, _} =
        membership |> Ecto.Changeset.change(inserted_at: just_over_seven) |> Repo.update()

      assert Accounts.fetch_invitation_by_token(token) == {:error, :expired}
    end

    test "resolves a pending invitation by its raw token" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(token)
      assert id == membership.id
    end

    test "honors the :preload option for the accept page's render" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-preload-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, %Membership{account: %Account{}, user: %User{}}} =
               Accounts.fetch_invitation_by_token(token, preload: [:account, :user])
    end

    test "does not resolve an invitation for a disabled account" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "an empty/blank/nil token is :not_found (the guard clauses)" do
      assert Accounts.fetch_invitation_by_token("") == {:error, :not_found}
      assert Accounts.fetch_invitation_by_token(nil) == {:error, :not_found}
      assert Accounts.fetch_invitation_by_token("not-a-real-token") == {:error, :not_found}
    end

    test "an accepted invitation no longer resolves (pending-only)" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "tok-accepted-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      {:ok, _} = Accounts.mark_invitation_accepted(membership, token, user)

      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end
  end

  describe "mark_invitation_accepted/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      invitee = Fixtures.Users.create_user()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: invitee.email, role: "viewer"),
          subject
        )

      %{membership: membership, invitee: invitee, token: token}
    end

    test "in-place accept burns the token; a replay is :not_found", %{
      membership: membership,
      invitee: invitee,
      token: token
    } do
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, token, invitee)
      assert accepted.invitation_accepted_at
      assert is_nil(accepted.invitation_token_digest)
      assert is_nil(accepted.invitation_sent_to)

      # The stale struct replayed: the fresh row is no longer pending.
      assert Accounts.mark_invitation_accepted(membership, token, invitee) ==
               {:error, :not_found}
    end

    test "a different signed-in user cannot burn the invitation", %{
      membership: membership,
      token: token
    } do
      bystander = Fixtures.Users.create_user()

      assert Accounts.mark_invitation_accepted(membership, token, bystander) ==
               {:error, :unauthorized}
    end

    test "stamps invitation_accepted_at + clears the token without touching the user" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "joiner-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      # No full_name set — the signed-in-as-self path skips the registration
      # changeset entirely.
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, token, user)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest

      # User row is untouched: same email, same full_name.
      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.email == user.email
      assert reloaded.full_name == user.full_name
    end

    test "a different signed-in user can't accept (burn) someone else's invite" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: inviter.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      attacker = Fixtures.Users.create_user()

      assert Accounts.mark_invitation_accepted(membership, token, attacker) ==
               {:error, :unauthorized}

      # The token survives, so the real invitee can still accept.
      assert {:ok, found} = Accounts.fetch_invitation_by_token(token)
      assert found.id == membership.id
    end

    test "a stale invitation cannot be accepted after the account is disabled" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "mark-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Accounts.mark_invitation_accepted(membership, token, user) ==
               {:error, :not_found}

      reloaded = Repo.reload!(membership)
      assert is_nil(reloaded.invitation_accepted_at)
      assert is_binary(reloaded.invitation_token_digest)
    end

    test "acceptance revokes credentials that predate the invitation boundary" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.membership_subject(membership)

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: user.id)

      {:ok, _device_code, _user_code, pending_grant} =
        Emisar.ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, grant} = Emisar.ApiKeys.approve_device_grant(pending_grant, subject)
      {token, digest} = Crypto.user_invite_token()

      pending =
        membership
        |> Ecto.Changeset.change(
          invitation_token_digest: digest,
          invitation_sent_to: user.email,
          invitation_email_changed_at: user.email_changed_at,
          invitation_accepted_at: nil
        )
        |> Repo.update!()

      assert {:ok, _accepted} = Accounts.mark_invitation_accepted(pending, token, user)
      assert Repo.reload!(key).revoked_at
      assert Repo.reload!(grant).status == :denied
    end
  end

  describe "accept_invitation/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "carol@example.test", role: "operator"),
          subject
        )

      %{membership: membership, token: token}
    end

    test "sets the user's full_name, confirms, clears the token", %{
      membership: membership,
      token: token
    } do
      attrs = %{"full_name" => "Carol"}

      assert {:ok, %{user: user, membership: accepted_membership}} =
               Accounts.accept_invitation(membership, token, attrs)

      assert user.full_name == "Carol"
      # Accepting the invite proves email ownership — the user is confirmed and
      # signs in by magic link (no password is set).
      assert user.confirmed_at
      assert is_nil(accepted_membership.invitation_token_digest)
      assert accepted_membership.invitation_accepted_at
    end

    test "the proved invitation cannot replace the address it was sent to", %{
      membership: membership,
      token: token
    } do
      assert {:ok, %{user: user}} =
               Accounts.accept_invitation(membership, token, %{
                 "email" => "attacker@example.test",
                 "full_name" => "Carol"
               })

      assert user.email == "carol@example.test"
      assert Repo.reload!(user).email == "carol@example.test"
    end

    test "a second accept with the same (stale) membership loses — first wins", %{
      membership: membership,
      token: token
    } do
      assert {:ok, %{user: user}} =
               Accounts.accept_invitation(membership, token, %{"full_name" => "Carol"})

      # A second link holder submits after the token is burnt: judged on
      # the locked fresh row, it must fail — and crucially must NOT have
      # overwritten the winner's full_name.
      assert Accounts.accept_invitation(membership, token, %{"full_name" => "Mallory"}) ==
               {:error, :not_found}

      assert {:ok, %{full_name: "Carol"}} = Emisar.Users.fetch_user_by_id(user.id)
    end

    test "the first acceptor wins — a second accept on the burnt token is :not_found" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "race-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      first_attrs = %{"full_name" => "First"}

      assert {:ok, _} = Accounts.accept_invitation(membership, token, first_attrs)

      # The locked re-judge of the (now non-pending) invitation refuses the
      # second submit before it could overwrite the winner's display name.
      second_attrs = %{"full_name" => "Second"}

      assert Accounts.accept_invitation(membership, token, second_attrs) ==
               {:error, :not_found}
    end

    test "a stale invitation cannot provision a user after the account is disabled" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: invitee, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "accept-disabled-#{System.unique_integer([:positive])}@example.test",
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      late_attrs = %{"full_name" => "Late Member"}

      assert Accounts.accept_invitation(membership, token, late_attrs) ==
               {:error, :not_found}

      {:ok, reloaded} = Users.fetch_user_by_id(invitee.id)
      assert is_nil(reloaded.confirmed_at)
      assert is_nil(reloaded.full_name)
    end

    test "credential revocation rolls back with a rejected acceptance, then commits with it" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: invitation, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "accept-rollback-#{System.unique_integer([:positive])}@example.test",
            role: "operator"
          ),
          subject
        )

      temporarily_authorized =
        invitation
        |> Ecto.Changeset.change(
          invitation_token_digest: nil,
          invitation_accepted_at: DateTime.utc_now()
        )
        |> Repo.update!()

      legacy_subject = Fixtures.Subjects.membership_subject(temporarily_authorized)

      {:ok, _raw, key} =
        Emisar.ApiKeys.create_key(%{name: "legacy pending key"}, legacy_subject)

      {:ok, _device_code, _user_code, pending_grant} =
        Emisar.ApiKeys.open_device_grant(["claude-code"], %RequestContext{})

      {:ok, grant} = Emisar.ApiKeys.approve_device_grant(pending_grant, legacy_subject)

      pending =
        temporarily_authorized
        |> Ecto.Changeset.change(
          invitation_token_digest: invitation.invitation_token_digest,
          invitation_accepted_at: nil
        )
        |> Repo.update!()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.accept_invitation(pending, token, %{
                 "full_name" => String.duplicate("x", 256)
               })

      assert is_nil(Repo.reload!(key).revoked_at)
      assert Repo.reload!(grant).status == :approved
      assert Membership.invitation_pending?(Repo.reload!(pending))

      assert {:ok, %{membership: accepted}} =
               Accounts.accept_invitation(pending, token, %{"full_name" => "Accepted Member"})

      assert Membership.authorizable?(accepted)
      assert Repo.reload!(key).revoked_at
      assert Repo.reload!(grant).status == :denied
      assert Repo.reload!(user).confirmed_at
    end
  end

  describe "invitation address and rotation binding" do
    test "an old-address link fails until an owner resends to the current address" do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      original_email = "old-inbox-#{System.unique_integer([:positive])}@example.test"
      current_email = "new-inbox-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user, invitation_token: old_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: original_email, role: "operator"),
          subject
        )

      user =
        user
        |> Emisar.Users.User.Changeset.email(%{email: current_email})
        |> Repo.update!()

      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}

      assert Accounts.accept_invitation(membership, old_token, %{"full_name" => "Wrong Proof"}) ==
               {:error, :not_found}

      # Returning to the same address does not resurrect the old-inbox proof:
      # the invitation is bound to the exact email generation too.
      user =
        user
        |> Emisar.Users.User.Changeset.email(%{email: original_email})
        |> Repo.update!()

      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}

      user
      |> Emisar.Users.User.Changeset.email(%{email: current_email})
      |> Repo.update!()

      assert {:ok, %{membership: refreshed, invitation_token: current_token}} =
               Accounts.resend_account_invitation(membership, subject)

      assert refreshed.invitation_sent_to == current_email
      refute current_token == old_token
      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}

      assert {:ok, %{user: accepted}} =
               Accounts.accept_invitation(refreshed, current_token, %{
                 "full_name" => "Inbox Owner"
               })

      assert accepted.email == current_email
      assert accepted.confirmed_at
      assert accepted.full_name == "Inbox Owner"
    end

    test "a rotated token defeats a holder who mounted the old token" do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      invitee = Fixtures.Users.create_user()

      {:ok, %{membership: membership, invitation_token: old_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: invitee.email, role: "viewer"),
          subject
        )

      assert {:ok, %{membership: refreshed, invitation_token: new_token}} =
               Accounts.resend_account_invitation(membership, subject)

      assert Accounts.mark_invitation_accepted(membership, old_token, invitee) ==
               {:error, :not_found}

      assert {:ok, accepted} =
               Accounts.mark_invitation_accepted(refreshed, new_token, invitee)

      assert accepted.invitation_accepted_at
    end

    test "a historical invitation without a sent address fails closed until resend" do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: old_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "historical-#{System.unique_integer([:positive])}@example.test",
            role: "operator"
          ),
          subject
        )

      membership =
        membership
        |> Ecto.Changeset.change(invitation_sent_to: nil)
        |> Repo.update!()

      assert Accounts.fetch_invitation_by_token(old_token) == {:error, :not_found}

      assert {:ok, %{membership: refreshed, invitation_token: new_token}} =
               Accounts.resend_account_invitation(membership, subject)

      assert is_binary(refreshed.invitation_sent_to)
      assert {:ok, _membership} = Accounts.fetch_invitation_by_token(new_token)
    end

    test "a forged stale account id cannot bypass the real account lock" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      other_account = Fixtures.Accounts.create_account()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: "forged-account-#{System.unique_integer([:positive])}@example.test",
            role: "operator"
          ),
          subject
        )

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      forged = %{membership | account_id: other_account.id}

      assert Accounts.accept_invitation(forged, token, %{"full_name" => "Forged"}) ==
               {:error, :not_found}

      reloaded = Repo.reload!(membership)
      refute reloaded.invitation_accepted_at
      assert is_binary(reloaded.invitation_token_digest)
    end
  end
end
