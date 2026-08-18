defmodule Emisar.InvitationTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Fixtures

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
      assert Accounts.runner_access_for_membership(membership.account_id, membership.id) ==
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
  end

  describe "mark_invitation_accepted/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)
      invitee = Fixtures.Users.create_user()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: invitee.email, role: "viewer"),
          subject
        )

      %{membership: membership, invitee: invitee}
    end

    test "in-place accept burns the token; a replay is :not_found", %{
      membership: membership,
      invitee: invitee
    } do
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, invitee)
      assert accepted.invitation_accepted_at
      assert is_nil(accepted.invitation_token_digest)

      # The stale struct replayed: the fresh row is no longer pending.
      assert Accounts.mark_invitation_accepted(membership, invitee) == {:error, :not_found}
    end

    test "a different signed-in user cannot burn the invitation", %{membership: membership} do
      bystander = Fixtures.Users.create_user()

      assert Accounts.mark_invitation_accepted(membership, bystander) == {:error, :unauthorized}
    end
  end

  describe "accept_invitation/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      {_inviter, subject} = inviter_subject(account)

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: "carol@example.test", role: "operator"),
          subject
        )

      %{membership: membership}
    end

    test "sets the user's full_name, confirms, clears the token", %{
      membership: membership
    } do
      attrs = %{"full_name" => "Carol"}

      assert {:ok, %{user: user, membership: accepted_membership}} =
               Accounts.accept_invitation(membership, attrs)

      assert user.full_name == "Carol"
      # Accepting the invite proves email ownership — the user is confirmed and
      # signs in by magic link (no password is set).
      assert user.confirmed_at
      assert is_nil(accepted_membership.invitation_token_digest)
      assert accepted_membership.invitation_accepted_at
    end

    test "a second accept with the same (stale) membership loses — first wins", %{
      membership: membership
    } do
      assert {:ok, %{user: user}} =
               Accounts.accept_invitation(membership, %{"full_name" => "Carol"})

      # A second link holder submits after the token is burnt: judged on
      # the locked fresh row, it must fail — and crucially must NOT have
      # overwritten the winner's full_name.
      assert Accounts.accept_invitation(membership, %{"full_name" => "Mallory"}) ==
               {:error, :not_found}

      assert {:ok, %{full_name: "Carol"}} = Emisar.Users.fetch_user_by_id(user.id)
    end
  end
end
