defmodule Emisar.InvitationTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Billing, Crypto, Fixtures, Repo, RequestContext, Users}
  alias Emisar.Accounts.{Account, Membership, RunnerAccess}

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

    test "creates a Member for the address and no personal login", %{subject: subject} do
      assert {:ok, %{membership: membership, invitation_token: token} = result} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: "new@example.test", role: "admin"),
                 subject
               )

      refute Map.has_key?(result, :user)
      assert is_nil(membership.user_id)
      assert membership.invitation_sent_to == "new@example.test"
      assert membership.contact_email == "new@example.test"
      assert Users.fetch_user_by_email("new@example.test") == {:error, :not_found}
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

    test "an existing personal login for the address is neither linked nor changed", %{
      subject: subject
    } do
      existing = Fixtures.Users.create_user(email: "alice@example.test")

      assert {:ok, %{membership: membership}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: "alice@example.test",
                   role: "operator",
                   runner_access_mode: "all"
                 ),
                 subject
               )

      assert is_nil(membership.user_id)
      assert Repo.reload!(existing) == existing
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

      assert {event.target_kind, event.target_id} == {"membership", membership.id}

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

    test "trims the email; the citext columns own case-insensitive identity", %{subject: subject} do
      assert {:ok, %{membership: invitation, invitation_token: token}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(
                   email: "  HELLO@Example.Test  ",
                   role: "viewer"
                 ),
                 subject
               )

      # Stored as typed (whitespace trimmed) — no app-side downcase.
      assert invitation.invitation_sent_to == "HELLO@Example.Test"

      # A differently-cased address is the same one: the citext contact already
      # lists it, and the login that owns it accepts.
      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(email: "hello@example.test", role: "viewer"),
               subject
             ) == {:error, :already_member}

      owner = Fixtures.Users.create_user(email: "hello@example.test")
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(invitation, token, owner)
      assert accepted.user_id == owner.id
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
      assert {:ok, %{membership: %Membership{account_id: account_id}}} =
               Accounts.invite_user_to_account(
                 Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
                 subject_b
               )

      assert account_id == account_b.id
      # And nothing was written into A: no seat there names the address.
      assert Accounts.list_sync_memberships_by_contact_email(account_a.id, email) == []
    end
  end

  describe "fetch_invitation_by_token/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "bob@example.test", role: "admin"),
          subject
        )

      %{membership: membership, token: token, account: account}
    end

    test "preloads are caller-driven: opted-in assocs load, the default loads none", %{
      token: token,
      account: account
    } do
      assert {:ok, membership} = Accounts.fetch_invitation_by_token(token, preload: [:account])

      assert membership.account.id == account.id
      assert is_nil(membership.user_id)

      # Without the opt the row comes back bare — callers that only need
      # the membership itself pay for no joins.
      assert {:ok, bare} = Accounts.fetch_invitation_by_token(token)
      assert %Ecto.Association.NotLoaded{} = bare.account
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

      assert {:ok, %Membership{account: %Account{}}} =
               Accounts.fetch_invitation_by_token(token, preload: [:account])
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
      user = Fixtures.Users.create_user()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: user.email,
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

    test "links the signed-in login that owns the address and burns the token; a replay is :not_found",
         %{membership: membership, invitee: invitee, token: token} do
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, token, invitee)
      assert accepted.user_id == invitee.id
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

      assert Repo.reload!(membership) == membership
    end

    test "the address owner must have confirmed it", %{
      membership: membership,
      invitee: invitee,
      token: token
    } do
      unconfirmed =
        invitee |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()

      assert Accounts.mark_invitation_accepted(membership, token, unconfirmed) ==
               {:error, :unauthorized}

      assert Repo.reload!(membership) == membership
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
      user = Fixtures.Users.create_user(full_name: "Personal Name")

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: user.email,
            role: "operator",
            runner_access_mode: "all"
          ),
          subject
        )

      # No workspace name set — the signed-in-as-self path skips the profile
      # changeset entirely.
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, token, user)
      assert accepted.invitation_accepted_at != nil
      assert accepted.user_id == user.id
      refute accepted.invitation_token_digest

      # User row is untouched: same email, same full_name.
      assert Repo.reload!(user) == user
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
      user = Fixtures.Users.create_user()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: user.email,
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
      assert is_nil(reloaded.user_id)
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

      # An invitation an earlier build left holding credentials, without the
      # personal login the migration detached from it.
      pending =
        membership
        |> Ecto.Changeset.change(
          user_id: nil,
          invitation_token_digest: digest,
          invitation_sent_to: user.email,
          invitation_accepted_at: nil
        )
        |> Repo.update!()

      assert {:ok, accepted} = Accounts.mark_invitation_accepted(pending, token, user)
      assert accepted.user_id == user.id
      assert Repo.reload!(key).revoked_at
      assert Repo.reload!(grant).status == :denied
    end
  end

  describe "prepare_invitation_acceptance/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "carol@example.test", role: "operator"),
          subject
        )

      %{membership: membership, token: token, subject: subject}
    end

    test "names the invited address and the intent, and writes nothing", %{
      membership: membership,
      token: token
    } do
      assert Accounts.prepare_invitation_acceptance(token, %{
               "display_name" => "Carol",
               "email" => "attacker@example.test"
             }) ==
               {:ok, "carol@example.test",
                %{
                  account_id: membership.account_id,
                  membership_id: membership.id,
                  token_digest: Crypto.user_invite_token_digest(token),
                  display_name: "Carol"
                }}

      assert Users.fetch_user_by_email("carol@example.test") == {:error, :not_found}
      assert Users.fetch_user_by_email("attacker@example.test") == {:error, :not_found}
      assert Repo.reload!(membership) == membership
    end

    test "a blank or overlong name is a field error", %{token: token} do
      for name <- ["", String.duplicate("x", 256)] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Accounts.prepare_invitation_acceptance(token, %{"display_name" => name})

        assert errors_on(changeset)[:display_name]
      end
    end

    test "an accepted, rotated, expired or unaddressed invitation, or a garbage token, is refused",
         %{membership: membership, token: token, subject: subject} do
      assert {:ok, %{membership: refreshed, invitation_token: new_token}} =
               Accounts.resend_account_invitation(membership, subject)

      assert Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Old"}) ==
               {:error, :not_found}

      refreshed
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -8, :day))
      |> Repo.update!()

      assert Accounts.prepare_invitation_acceptance(new_token, %{"display_name" => "Late"}) ==
               {:error, :expired}

      refreshed |> Ecto.Changeset.change(invitation_sent_to: nil) |> Repo.update!()

      assert Accounts.prepare_invitation_acceptance(new_token, %{"display_name" => "Anyone"}) ==
               {:error, :not_found}

      assert Accounts.prepare_invitation_acceptance("garbage", %{}) == {:error, :not_found}
    end
  end

  describe "put_invitation_acceptance/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      email = "carol-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      {:ok, ^email, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Carol"})

      %{account: account, subject: subject, membership: membership, token: token, intent: intent}
    end

    # The completion transaction's shape: the account, then the person who
    # proved the mailbox, then the acceptance.
    defp accept_in_transaction(%Users.User{} = user, intent) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(intent.account_id, repo: repo)
      end)
      |> Ecto.Multi.run(:user, fn repo, _changes ->
        Users.fetch_and_lock_user_by_id(user.id, repo)
      end)
      |> Ecto.Multi.merge(fn %{user: locked} ->
        Accounts.put_invitation_acceptance(Ecto.Multi.new(), locked, intent)
      end)
      |> Repo.transaction()
    end

    test "links the proving login, names the Member, burns the token and audits once", %{
      membership: membership,
      intent: intent
    } do
      {:ok, user} = Users.fetch_or_create_user_by_email(membership.invitation_sent_to)

      assert {:ok, %{accepted: accepted, invitation_audit: audit}} =
               accept_in_transaction(user, intent)

      assert {accepted.id, accepted.user_id, accepted.display_name, accepted.contact_email} ==
               {membership.id, user.id, "Carol", membership.invitation_sent_to}

      assert is_nil(accepted.invitation_token_digest)
      assert accepted.invitation_accepted_at
      assert {audit.event_type, audit.actor_id} == {"user.invitation_accepted", membership.id}
      assert Repo.reload!(user) == user

      assert {:error, :membership, :invitation_invalid, _changes} =
               accept_in_transaction(user, intent)

      assert Repo.reload!(accepted).display_name == "Carol"
    end

    test "nil is an ordinary sign-in and adds nothing" do
      user = Fixtures.Users.create_user()
      multi = Ecto.Multi.new()
      assert Accounts.put_invitation_acceptance(multi, user, nil) == multi
    end

    test "a rotated, cross-account or forged intent fails closed", %{
      account: account,
      subject: subject,
      membership: membership,
      intent: intent
    } do
      {:ok, user} = Users.fetch_or_create_user_by_email(membership.invitation_sent_to)
      {_other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: other_invitation}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: user.email, role: "operator"),
          other_subject
        )

      assert {:ok, %{membership: _refreshed}} =
               Accounts.resend_account_invitation(membership, subject)

      for forged <- [
            intent,
            %{intent | account_id: other_account.id},
            %{intent | account_id: other_account.id, membership_id: other_invitation.id}
          ] do
        assert {:error, :membership, :invitation_invalid, _changes} =
                 accept_in_transaction(user, forged)
      end

      assert is_nil(Repo.reload!(membership).user_id)
      assert is_nil(Repo.reload!(other_invitation).user_id)
      assert account.id != other_account.id
    end

    test "a login already seated here, or no longer owning the address, is refused", %{
      account: account,
      membership: membership,
      intent: intent
    } do
      {:ok, owner} = Users.fetch_or_create_user_by_email(membership.invitation_sent_to)

      seat =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          contact_email: "work-#{System.unique_integer([:positive])}@example.test"
        )

      assert {:error, :linked, :invitation_invalid, _changes} =
               accept_in_transaction(owner, intent)

      stranger = Fixtures.Users.create_user()

      assert {:error, :membership, :invitation_invalid, _changes} =
               accept_in_transaction(stranger, intent)

      assert Repo.reload!(seat) == seat
      assert is_nil(Repo.reload!(membership).user_id)
    end

    test "credential revocation commits only with the acceptance" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
      user = Fixtures.Users.create_user()

      {:ok, %{membership: invitation, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: user.email, role: "operator"),
          subject
        )

      # An earlier build let a linked invitation hold credentials; the migration
      # then detached its personal login.
      temporarily_authorized =
        invitation
        |> Ecto.Changeset.change(
          user_id: user.id,
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

      temporarily_authorized
      |> Ecto.Changeset.change(
        user_id: nil,
        invitation_token_digest: invitation.invitation_token_digest,
        invitation_accepted_at: nil
      )
      |> Repo.update!()

      {:ok, _address, intent} =
        Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Accepted Member"})

      assert {:error, :accepted, %Ecto.Changeset{}, _changes} =
               accept_in_transaction(user, %{intent | display_name: String.duplicate("x", 256)})

      assert is_nil(Repo.reload!(key).revoked_at)
      assert Repo.reload!(grant).status == :approved

      assert {:ok, %{accepted: accepted}} = accept_in_transaction(user, intent)
      assert Membership.authorizable?(accepted)
      assert accepted.user_id == user.id
      assert Repo.reload!(key).revoked_at
      assert Repo.reload!(grant).status == :denied
    end
  end

  describe "invitation address and rotation binding" do
    test "an invitation stays with its address, never the login that moved off it" do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      original_email = "old-inbox-#{System.unique_integer([:positive])}@example.test"
      current_email = "new-inbox-#{System.unique_integer([:positive])}@example.test"
      moved = Fixtures.Users.create_user(email: original_email)

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: original_email, role: "operator"),
          subject
        )

      moved = Fixtures.Users.update_email(moved, current_email) |> Fixtures.Users.confirm_user()

      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(token)
      assert id == membership.id

      # The login no longer owns the address the invitation was sent to.
      assert Accounts.mark_invitation_accepted(membership, token, moved) ==
               {:error, :unauthorized}

      # Whoever proves the address joins, with a login of its own.
      assert {:ok, ^original_email, _intent} =
               Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Inbox Owner"})

      assert {:ok, accepted} = Users.fetch_or_create_user_by_email(original_email)
      refute accepted.id == moved.id
      assert is_nil(Fixtures.Memberships.fetch_membership(account.id, moved.id))
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

    test "a historical invitation without a sent address refuses implicit retargeting" do
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

      assert Accounts.prepare_invitation_acceptance(old_token, %{"display_name" => "Anyone"}) ==
               {:error, :not_found}

      assert {:error, :stale_invitation_contact} =
               Accounts.resend_account_invitation(membership, subject)

      assert Repo.reload!(membership) == membership
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

      assert Accounts.prepare_invitation_acceptance(token, %{"display_name" => "Forged"}) ==
               {:error, :not_found}

      assert other_account.id != membership.account_id

      reloaded = Repo.reload!(membership)
      refute reloaded.invitation_accepted_at
      assert is_binary(reloaded.invitation_token_digest)
    end
  end
end
