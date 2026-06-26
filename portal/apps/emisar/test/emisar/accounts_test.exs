defmodule Emisar.AccountsTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Mail
  alias Emisar.Users
  alias Emisar.Users.User

  describe "create_account_with_owner/2" do
    test "persists account + owner membership in a single transaction" do
      user = user_fixture()

      assert {:ok, %Account{} = account} =
               Accounts.create_account_with_owner(
                 %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
                 user
               )

      assert %Membership{role: :owner} = fetch_membership(account.id, user.id)
    end

    test "rolls back when the account changeset is invalid" do
      user = user_fixture()

      # Slug too short — fails the format regex (>=3 chars).
      assert {:error, %Ecto.Changeset{}} =
               Accounts.create_account_with_owner(%{name: "x", slug: "x"}, user)

      # No partial membership stuck around. The user has no account yet, so
      # the picker subject is built straight from the actor (account nil).
      subject = %Emisar.Auth.Subject{actor: user}
      assert {:ok, [], _} = Accounts.list_accounts_for_user(subject)
    end

    # the account-name length bounds (1..80) are inclusive
    # at both edges (with a valid slug supplied so only the name is under test).
    test "accepts a name of 1 and of 80 chars" do
      for length <- [1, 80] do
        user = user_fixture()
        slug = "name-edge-#{System.unique_integer([:positive])}"

        assert {:ok, %Account{}} =
                 Accounts.create_account_with_owner(
                   %{name: String.duplicate("a", length), slug: slug},
                   user
                 )
      end
    end

    # a name over 80 chars is rejected and the transaction
    # rolls back (no orphaned account or membership).
    test "rejects a name over 80 chars and rolls back" do
      user = user_fixture()
      slug = "name-too-long-#{System.unique_integer([:positive])}"

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.create_account_with_owner(
                 %{name: String.duplicate("a", 81), slug: slug},
                 user
               )

      assert changeset.errors[:name]
      subject = %Emisar.Auth.Subject{actor: user}
      assert {:ok, [], _} = Accounts.list_accounts_for_user(subject)
    end
  end

  describe "fetch_membership_for_session/2" do
    test "with no account_id, returns the most-recent non-disabled membership" do
      user = user_fixture()
      first_account = account_fixture()
      second_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)
      second_membership = membership_fixture(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{}, user: %User{}}} =
               Accounts.fetch_membership_for_session(user, nil)

      assert id == second_membership.id
    end

    test "with a matching account_id, returns that specific membership even if older" do
      user = user_fixture()
      first_account = account_fixture()
      second_account = account_fixture()
      first_membership = membership_fixture(account_id: first_account.id, user_id: user.id)
      _ = membership_fixture(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = account}} =
               Accounts.fetch_membership_for_session(user, first_account.id)

      assert id == first_membership.id
      assert account.id == first_account.id
    end

    test "with a stale or unknown account_id, falls back to the primary" do
      user = user_fixture()
      first_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, Ecto.UUID.generate())

      assert returned_account_id == first_account.id
    end

    test "with a suspended membership on the requested account, falls back" do
      user = user_fixture()
      first_account = account_fixture()
      _ = membership_fixture(account_id: first_account.id, user_id: user.id)

      {_owner_user, second_account, owner_subject} = owner_subject_fixture()

      second_membership =
        membership_fixture(account_id: second_account.id, user_id: user.id, role: "operator")

      assert {:ok, _} = Accounts.suspend_membership(second_membership, owner_subject)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, second_account.id)

      refute returned_account_id == second_account.id
    end

    test "returns :not_found for a user with no memberships" do
      assert {:error, :not_found} =
               Accounts.fetch_membership_for_session(user_fixture(), nil)
    end
  end

  describe "fetch_membership_by_account_id_or_slug/2" do
    test "resolves the user's membership by the account slug" do
      user = user_fixture()
      account = account_fixture()
      membership = membership_fixture(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = resolved, user: %User{}}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.slug)

      assert id == membership.id
      assert resolved.id == account.id
    end

    test "resolves by the account id too (the UUID form for API/SSO/redirects)" do
      user = user_fixture()
      account = account_fixture()
      membership = membership_fixture(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.id)

      assert id == membership.id
    end

    test "a non-member's slug is indistinguishable from an unknown one (404, never a leak)" do
      member = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: member.id)

      outsider = user_fixture()

      # The account exists, but the outsider isn't a member: SAME :not_found as
      # a slug no account has — so a URL never confirms a tenant exists (404, not 403).
      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(outsider, account.slug)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(outsider, "no-such-team")
    end

    test "a member of account A cannot resolve account B (cross-account, by slug or id)" do
      user = user_fixture()
      account_a = account_fixture()
      account_b = account_fixture()
      _ = membership_fixture(account_id: account_a.id, user_id: user.id)
      _ = membership_fixture(account_id: account_b.id, user_id: user_fixture().id)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account_b.slug)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account_b.id)
    end

    test "a suspended membership does not resolve" do
      user = user_fixture()
      {_owner_user, account, owner_subject} = owner_subject_fixture()
      membership = membership_fixture(account_id: account.id, user_id: user.id, role: "operator")
      assert {:ok, _} = Accounts.suspend_membership(membership, owner_subject)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.slug)
    end
  end

  describe "fetch_account_by_id_or_slug/1 (pre-auth, no Subject)" do
    test "resolves a live account by slug or id — knowing the ref is all it takes" do
      # the branded sign-in page and the SSO
      # team picker resolve the tenant from the URL BEFORE anyone is signed in, so
      # this read takes NO `%Subject{}`: it's deliberately unauthorized (the slug
      # only picks which sign-in page to show; it grants nothing). It resolves by
      # the slug AND the id (the UUID form for SSO/redirects).
      account = account_fixture()

      assert {:ok, %Account{id: id}} = Accounts.fetch_account_by_id_or_slug(account.slug)
      assert id == account.id
      assert {:ok, %Account{id: ^id}} = Accounts.fetch_account_by_id_or_slug(account.id)
    end

    test "an unknown ref and a soft-deleted account are the SAME :not_found (no leak)" do
      # the read starts at `not_deleted`, so a
      # tombstoned account is indistinguishable from one that never existed: both
      # `:not_found`. A pre-auth prober can't confirm a tenant exists from this read.
      account = account_fixture()
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug("no-such-team")
      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug(account.slug)
      # A well-formed-but-unused UUID is the same :not_found, never a crash.
      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug(Ecto.UUID.generate())
    end
  end

  describe "update_account/3 — require_sso (owner + admin security setting)" do
    test "an owner can enable require_sso" do
      {_owner, account, owner_subject} = owner_subject_fixture()

      assert {:ok, %Account{require_sso: true}} =
               Accounts.update_account(account, %{require_sso: true}, owner_subject)
    end

    test "an admin can enable require_sso (owners + admins manage security settings)" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      admin_subject = subject_for(admin, account, role: :admin)

      assert {:ok, %Account{require_sso: true}} =
               Accounts.update_account(account, %{require_sso: true}, admin_subject)
    end

    test "an operator cannot change a security setting (no manage_security_settings)" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(account, %{require_sso: true}, operator_subject)

      refute Repo.reload!(account).require_sso
    end

    test "an owner of another account can't toggle this account's require_sso (cross-account)" do
      {_owner_a, account_a, _subject_a} = owner_subject_fixture()
      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      # B's owner holds `manage_own_account` for their OWN account, so the
      # permission gate passes; `ensure_subject_owns_account` then refuses the
      # cross-account write.
      assert {:error, :unauthorized} =
               Accounts.update_account(account_a, %{require_sso: true}, subject_b)

      refute Repo.reload!(account_a).require_sso
    end

    test "an owner of another account can't toggle this account's require_mfa (cross-account)" do
      {_owner_a, account_a, _subject_a} = owner_subject_fixture()
      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} =
               Accounts.update_account(account_a, %{require_mfa: true}, subject_b)

      refute Repo.reload!(account_a).require_mfa
    end

    test "an admin can rename the account — only the security flags need manage_security_settings" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      admin_subject = subject_for(admin, account, role: :admin)

      # A plain rename touches no security field, so the top-level
      # `manage_own_account` gate (which admins hold) is all it needs — the
      # field-aware `manage_security_settings` check only fires for
      # require_mfa/require_sso (owners + admins hold it; operators/viewers don't).
      assert {:ok, %Account{name: "Renamed By Admin"}} =
               Accounts.update_account(account, %{name: "Renamed By Admin"}, admin_subject)
    end
  end

  describe "update_account/3 — max_grant_lifetime_seconds (security setting)" do
    test "an owner can set the grant-lifetime cap" do
      {_owner, account, owner_subject} = owner_subject_fixture()

      assert {:ok, %Account{max_grant_lifetime_seconds: 86_400}} =
               Accounts.update_account(
                 account,
                 %{max_grant_lifetime_seconds: 86_400},
                 owner_subject
               )
    end

    test "an admin can set the cap (security setting)" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      admin_subject = subject_for(admin, account, role: :admin)

      assert {:ok, %Account{max_grant_lifetime_seconds: 3_600}} =
               Accounts.update_account(
                 account,
                 %{max_grant_lifetime_seconds: 3_600},
                 admin_subject
               )
    end

    test "an operator cannot set the cap (no manage_security_settings)" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(
                 account,
                 %{max_grant_lifetime_seconds: 3_600},
                 operator_subject
               )

      refute Repo.reload!(account).max_grant_lifetime_seconds
    end

    test "the cap must be a positive number of seconds" do
      {_owner, account, owner_subject} = owner_subject_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_account(account, %{max_grant_lifetime_seconds: 0}, owner_subject)
    end

    test "an owner of another account can't set this account's cap (cross-account)" do
      {_owner_a, account_a, _subject_a} = owner_subject_fixture()
      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} =
               Accounts.update_account(account_a, %{max_grant_lifetime_seconds: 3_600}, subject_b)

      refute Repo.reload!(account_a).max_grant_lifetime_seconds
    end
  end

  describe "invite_user_to_account/3" do
    test "creates a placeholder user for an unknown email" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      assert {:ok,
              %{
                membership: %Membership{role: :admin},
                user: %User{} = invitee,
                invitation_token: token
              }} =
               Accounts.invite_user_to_account(email, "admin", subject)

      assert invitee.email == email
      refute invitee.confirmed_at
      assert is_binary(token)
    end

    test "reuses the existing user when one is already registered" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      assert {:ok, %{user: %User{id: id}}} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)

      assert id == existing.id
    end

    test "refuses duplicate memberships" do
      inviter = user_fixture()
      existing = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      _ = membership_fixture(account_id: account.id, user_id: existing.id)
      subject = subject_for(inviter, account, role: :owner)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)
    end

    test "an admin cannot invite an owner (can't grant a role it doesn't hold)" do
      admin = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      email = "owner-invite-#{System.unique_integer([:positive])}@example.test"

      assert {:error, :insufficient_privileges} =
               Accounts.invite_user_to_account(email, "owner", subject)
    end

    test "seats are uncapped — inviting well past any prior limit always succeeds" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      # Team seats are a deliberate growth lever, not a gate — there is no
      # Billing.check_limit on this path, so a large batch of invites all land.
      for n <- 1..12 do
        email = "seat-#{n}-#{System.unique_integer([:positive])}@example.test"

        assert {:ok, %{membership: %Membership{}}} =
                 Accounts.invite_user_to_account(email, "viewer", subject)
      end

      # All twelve invitees plus the owner are members — none was capped.
      assert Accounts.count_memberships(account.id) == 13
    end

    test "an invite always lands in the SUBJECT's account — B's owner can't seed account A" do
      {_owner_a, account_a, _subject_a} = owner_subject_fixture()
      {_owner_b, account_b, subject_b} = owner_subject_fixture()

      email = "cross-#{System.unique_integer([:positive])}@example.test"

      # The membership's account is read off `subject.account`, so B's owner can
      # only ever invite into B — there is no caller-supplied account id to
      # redirect the invite into A.
      assert {:ok, %{membership: %Membership{account_id: account_id}, user: invitee}} =
               Accounts.invite_user_to_account(email, "operator", subject_b)

      assert account_id == account_b.id
      # And nothing was written into A: the invitee has no membership there.
      assert is_nil(fetch_membership(account_a.id, invitee.id))
    end
  end

  describe "resend_account_invitation/2" do
    test "refreshes the pending invite token and validity window" do
      {_owner, _account, subject} = owner_subject_fixture()
      email = "resend-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user, invitation_token: old_token}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      expired_at = DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60, :second)

      membership =
        membership
        |> Ecto.Changeset.change(inserted_at: expired_at, updated_at: expired_at)
        |> Repo.update!()

      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(old_token)

      assert {:ok,
              %{
                membership: %Membership{} = updated,
                user: %User{id: user_id},
                invitation_token: new_token
              }} =
               Accounts.resend_account_invitation(membership, subject)

      assert user_id == user.id
      assert updated.id == membership.id
      refute new_token == old_token
      refute updated.invitation_token_digest == membership.invitation_token_digest
      assert DateTime.compare(updated.inserted_at, expired_at) == :gt
      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(new_token)
      assert id == membership.id
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(old_token)
    end

    test "a viewer cannot resend an invitation" do
      {_owner, account, owner_subject} = owner_subject_fixture()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "viewer-denied-#{System.unique_integer([:positive])}@example.test",
          "operator",
          owner_subject
        )

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Accounts.resend_account_invitation(membership, viewer_subject)

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end

    test "an owner of another account cannot resend this account's invitation" do
      {_owner_a, _account_a, subject_a} = owner_subject_fixture()
      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "cross-resend-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject_a
        )

      assert {:error, :unauthorized} =
               Accounts.resend_account_invitation(membership, subject_b)

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end

    test "an accepted invitation is no longer resendable" do
      {_owner, _account, subject} = owner_subject_fixture()

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(
          "accepted-resend-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      assert {:ok, _accepted} = Accounts.mark_invitation_accepted(membership, user)
      assert {:error, :not_found} = Accounts.resend_account_invitation(membership, subject)
    end

    test "an admin cannot resend an owner invitation" do
      {_owner, account, owner_subject} = owner_subject_fixture()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "owner-resend-#{System.unique_integer([:positive])}@example.test",
          "owner",
          owner_subject
        )

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      admin_subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.resend_account_invitation(membership, admin_subject)
    end
  end

  describe "mark_invitation_accepted/1" do
    test "stamps invitation_accepted_at + clears the token without touching the user" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "joiner-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, user: user}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      # No full_name set — the signed-in-as-self path skips the registration
      # changeset entirely.
      assert {:ok, accepted} = Accounts.mark_invitation_accepted(membership, user)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest

      # User row is untouched: same email, same full_name.
      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.email == user.email
      assert reloaded.full_name == user.full_name
    end

    test "a different signed-in user can't accept (burn) someone else's invite" do
      inviter = user_fixture()
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: inviter.id, role: "owner")
      subject = subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      attacker = user_fixture()

      assert {:error, :unauthorized} =
               Accounts.mark_invitation_accepted(membership, attacker)

      # The token survives, so the real invitee can still accept.
      assert {:ok, found} = Accounts.fetch_invitation_by_token(token)
      assert found.id == membership.id
    end
  end

  describe "suggest_unique_slug/1" do
    test "returns the slugified base when free" do
      assert Accounts.suggest_unique_slug("Acme Co!") =~ ~r/^acme-co/
    end

    test "appends -1, -2, ... on collision" do
      base = "team-#{System.unique_integer([:positive])}"
      _ = account_fixture(slug: base)
      _ = account_fixture(slug: base <> "-1")

      assert Accounts.suggest_unique_slug(base) == base <> "-2"
    end
  end

  describe "update_membership_role/3" do
    test "the last active owner can't demote themselves; with a second owner it works" do
      account = account_fixture()
      owner = user_fixture()
      owner_m = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      # Sole owner — the in-transaction guard (locked re-count of the
      # account's active owner rows) refuses the demotion.
      assert {:error, :last_owner} = Accounts.update_membership_role(owner_m, "admin", subject)

      # A second active owner frees the demotion.
      second = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: second.id, role: "owner")

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(owner_m, "admin", subject)
    end

    test "promotes operator to admin" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()
      m = membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(m, "admin", subject)
    end

    test "rejects an unknown role" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()
      m = membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:error, cs} = Accounts.update_membership_role(m, "supreme-leader", subject)
      assert "is invalid" in errors_on(cs).role
    end

    test "an admin cannot grant the owner role (no escalation by proxy)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      m = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "operator")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(m, "owner", subject)
    end

    test "an admin cannot demote an owner (can't outrank a superior)" do
      account = account_fixture()

      owner_m =
        membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(owner_m, "operator", subject)
    end

    test "you cannot promote yourself" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      admin = user_fixture()
      admin_m = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :cannot_self_promote} =
               Accounts.update_membership_role(admin_m, "owner", subject)
    end

    test "an owner can grant the owner role" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      m = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "operator")
      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :owner}} =
               Accounts.update_membership_role(m, "owner", subject)
    end

    test "an owner of another account can't change this member's role (cross-account)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      # `ensure_subject_in_account` (passed :unauthorized) fires before the
      # `for_subject`-scoped row read, so the cross-account mutation is refused
      # without touching A's row.
      assert {:error, :unauthorized} =
               Accounts.update_membership_role(target, "admin", subject_b)

      # A's membership is untouched — still operator.
      assert %Membership{role: :operator} = fetch_membership(account.id, target_user.id)
    end
  end

  describe "delete_membership/3" do
    test "owner can remove a non-owner member" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{} = removed} = Accounts.delete_membership(target, subject)

      # Removal is a soft delete: the tombstone keeps history while every
      # not_deleted() read treats the member as gone.
      assert removed.deleted_at
      assert {:error, :not_found} = Accounts.fetch_membership_for_session(target_user, account.id)
    end

    test "removing a member revokes the API keys they minted" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      member = user_fixture()

      member_membership =
        membership_fixture(account_id: account.id, user_id: member.id, role: "admin")

      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: member.id)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # Sessions self-heal at membership resolution; the minted keys don't,
      # so removal revokes them (after_commit) to cut off MCP / OAuth.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "a removed member can be re-invited (tombstone doesn't hold the seat)" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert {:ok, %{membership: fresh}} =
               Accounts.invite_user_to_account(target_user.email, "viewer", subject)

      assert fresh.user_id == target_user.id
      assert fresh.id != target.id
    end

    test "an operator (no manage_team permission) cannot remove a member → :unauthorized" do
      account = account_fixture()
      target_user = user_fixture()
      target = membership_fixture(account_id: account.id, user_id: target_user.id, role: "viewer")

      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.delete_membership(target, operator_subject)
      # The target membership is still present.
      assert %Membership{} = fetch_membership(account.id, target_user.id)
    end

    test "an admin cannot remove an owner" do
      account = account_fixture()

      owner_m =
        membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} = Accounts.delete_membership(owner_m, subject)
    end

    test "an owner of another account can't remove this member (cross-account)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.delete_membership(target, subject_b)
      # A's membership survives.
      assert %Membership{} = fetch_membership(account.id, target_user.id)
    end

    test "a removed member's API key can no longer resolve for dispatch" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      subject = subject_for(owner, account, role: :owner)

      member = user_fixture()

      member_membership =
        membership_fixture(account_id: account.id, user_id: member.id, role: "admin")

      {raw, _key} = api_key_fixture(account_id: account.id, created_by_id: member.id)
      # The key resolves while the member is active — the MCP/OAuth auth boundary.
      assert %Emisar.ApiKeys.ApiKey{} = Emisar.ApiKeys.peek_api_key_by_secret(raw)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # After removal the key is revoked (after_commit), so the credential
      # resolution that precedes building a Subject returns nil — no dispatch.
      assert is_nil(Emisar.ApiKeys.peek_api_key_by_secret(raw))
    end
  end

  describe "suspend_membership/2 + reinstate_membership/2" do
    setup do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      owner_subject = subject_for(owner, account, role: :owner)
      {:ok, account: account, owner: owner, target: target, owner_subject: owner_subject}
    end

    test "owner can suspend an operator and reinstate", %{
      target: target,
      owner_subject: owner_subject
    } do
      assert {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      assert Membership.disabled?(suspended)

      assert {:ok, reinstated} = Accounts.reinstate_membership(suspended, owner_subject)
      refute Membership.disabled?(reinstated)
    end

    test "suspending a member revokes the API keys they minted", %{
      account: account,
      owner_subject: owner_subject
    } do
      admin = user_fixture()

      admin_membership =
        membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")

      {_raw, key} = api_key_fixture(account_id: account.id, created_by_id: admin.id)
      assert is_nil(Emisar.Repo.reload!(key).revoked_at)

      assert {:ok, _} = Accounts.suspend_membership(admin_membership, owner_subject)

      # after_commit revokes the keys the suspended member minted so they
      # can't keep dispatching via MCP / OAuth after losing access.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "operator cannot suspend anyone", %{account: account, target: target} do
      operator = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: operator.id, role: "operator")
      operator_subject = subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.suspend_membership(target, operator_subject)
    end

    test "suspending a member keeps the seat — count_memberships still includes them", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      # Owner + target = 2 seats before; suspension preserves the role + history
      # for reinstate, so it must NOT free the seat (only a soft-delete removal
      # does — see delete_membership).
      assert Accounts.count_memberships(account.id) == 2

      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)

      assert Accounts.count_memberships(account.id) == 2
      assert Membership.disabled?(Repo.reload!(target))
    end

    test "can't suspend yourself", %{owner: owner, account: account, owner_subject: owner_subject} do
      owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert {:error, :cannot_modify_self} =
               Accounts.suspend_membership(owner_membership, owner_subject)
    end

    test "can't suspend the last owner", %{
      owner: owner,
      account: account,
      owner_subject: owner_subject
    } do
      owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      # Promote another owner so the actor isn't the only one — then
      # the second owner suspends the first.
      second_owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: second_owner.id, role: "owner")
      second_owner_subject = subject_for(second_owner, account, role: :owner)
      assert {:ok, _} = Accounts.suspend_membership(owner_membership, second_owner_subject)

      # Now `second_owner` is the last ACTIVE owner — can't be suspended.
      # (The first owner's Subject still carries owner permissions at the
      # context layer — suspension is enforced by killing their session at
      # the web layer — so it can drive this attempt.)
      second_owner_membership =
        Emisar.Accounts.Membership.Query.all()
        |> Emisar.Accounts.Membership.Query.by_account_and_user(account.id, second_owner.id)
        |> Emisar.Repo.fetch!(Emisar.Accounts.Membership.Query)

      assert {:error, :last_owner} =
               Accounts.suspend_membership(second_owner_membership, owner_subject)

      # Reinstating the first owner makes the second suspendable again —
      # and pins that reinstate REALLY clears the row (a stale-struct
      # reinstate used to silently no-op).
      {:ok, _} = Accounts.reinstate_membership(owner_membership, second_owner_subject)

      assert {:ok, _} =
               Accounts.suspend_membership(second_owner_membership, owner_subject)

      _ = owner
    end

    test "suspended membership is excluded from fetch_membership_for_session/2", %{
      target: target,
      owner_subject: owner_subject
    } do
      target_user = Emisar.Repo.preload(target, :user).user
      assert {:ok, %Membership{}} = Accounts.fetch_membership_for_session(target_user, nil)

      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)
      assert {:error, :not_found} = Accounts.fetch_membership_for_session(target_user, nil)
      assert Accounts.all_memberships_suspended?(target_user)
    end

    test "an owner of another account can't suspend this member (cross-account)", %{
      account: account,
      target: target
    } do
      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.suspend_membership(target, subject_b)
      refute Membership.disabled?(fetch_membership(account.id, target.user_id))
    end
  end

  describe "reset_member_mfa/2" do
    test "an owner clears a member's MFA + writes the user.mfa_reset_by_admin audit row" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = enroll_member_mfa(user_fixture())

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      owner_subject = subject_for(owner, account, role: :owner)

      assert {:ok, %User{} = updated} = Accounts.reset_member_mfa(target, owner_subject)

      # Every MFA field is wiped — the member can no longer present a factor.
      assert is_nil(updated.mfa_enabled_at)
      assert is_nil(updated.mfa_secret)
      assert updated.mfa_recovery_codes == []

      # And it's persisted, not just on the returned struct.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      assert is_nil(reloaded.mfa_enabled_at)
      refute Emisar.Auth.mfa_required?(reloaded)

      events = Emisar.Audit.list_events(owner_subject, page: [limit: 10]) |> elem(1)
      assert Enum.any?(events, &(&1.event_type == "user.mfa_reset_by_admin"))
    end

    test "a viewer (no manage_team) is refused" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target_user = enroll_member_mfa(user_fixture())

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Accounts.reset_member_mfa(target, subject)

      # The member's factor is untouched.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an admin can't reset an owner's MFA (hierarchy)" do
      account = account_fixture()
      owner = enroll_member_mfa(user_fixture())
      owner_m = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")

      admin = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: admin.id, role: "admin")
      subject = subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} = Accounts.reset_member_mfa(owner_m, subject)

      {:ok, reloaded} = Users.fetch_user_by_id(owner.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an owner of another account can't reset this member's MFA (cross-account)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target_user = enroll_member_mfa(user_fixture())

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.reset_member_mfa(target, subject_b)

      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end
  end

  describe "soft-deleted associations are excluded from preloads" do
    test "account preload skips a soft-deleted membership (preloader honors :where)" do
      account = account_fixture()
      live_user = user_fixture()
      doomed_user = user_fixture()
      _live = membership_fixture(account_id: account.id, user_id: live_user.id)
      doomed = membership_fixture(account_id: account.id, user_id: doomed_user.id)

      {:ok, _} = doomed |> Membership.Changeset.delete() |> Emisar.Repo.update()

      {:ok, loaded} =
        Account.Query.not_deleted()
        |> Account.Query.by_id(account.id)
        |> Emisar.Repo.fetch(Account.Query, preload: [:memberships])

      assert [%Membership{} = only] = loaded.memberships
      assert only.user_id == live_user.id
    end
  end

  describe "list_memberships_for_account/3" do
    test "lists the account's members for a member subject" do
      {_owner, account, subject} = owner_subject_fixture()
      _second = membership_fixture(account_id: account.id)

      assert {:ok, memberships, _} = Accounts.list_memberships_for_account(account, subject)
      assert length(memberships) == 2
    end

    test "list_account_memberships/2 (system fan-out read) is scoped to the given account" do
      {_owner_a, account_a, _} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()
      _other = membership_fixture(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "a subject cannot list another account's memberships" do
      {_owner_a, _account_a, subject_a} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()

      assert {:error, :unauthorized} =
               Accounts.list_memberships_for_account(account_b, subject_a)
    end
  end

  describe "suppressed_member_emails/2" do
    test "returns the account's member emails that are on the suppression list" do
      {_owner, account, subject} = owner_subject_fixture()
      bouncing = user_fixture(email: "bouncing@example.com")
      _ = membership_fixture(account_id: account.id, user_id: bouncing.id)
      _fine = membership_fixture(account_id: account.id)

      {:ok, _} = Mail.suppress("bouncing@example.com", :hard_bounce, "bounce")

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert suppressed == MapSet.new(["bouncing@example.com"])
    end

    test "is empty when no member email is suppressed" do
      {_owner, account, subject} = owner_subject_fixture()
      _ = membership_fixture(account_id: account.id)

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert MapSet.size(suppressed) == 0
    end

    test "never surfaces a suppression that belongs only to another account" do
      {_owner_a, account_a, subject_a} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()

      # An address suppressed globally, but a member only of account B.
      b_member = user_fixture(email: "b-only@example.com")
      _ = membership_fixture(account_id: account_b.id, user_id: b_member.id)
      {:ok, _} = Mail.suppress("b-only@example.com", :hard_bounce, "bounce")

      # Account A asks for ITS suppressed emails — B's bouncing address must not leak.
      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account_a, subject_a)
      refute MapSet.member?(suppressed, "b-only@example.com")
      assert MapSet.size(suppressed) == 0
    end

    test "a subject cannot read another account's suppressed emails" do
      {_owner_a, _account_a, subject_a} = owner_subject_fixture()
      {_owner_b, account_b, _} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.suppressed_member_emails(account_b, subject_a)
    end
  end

  describe "record_account_switched/1" do
    test "writes the session.account_switched audit row for the switched-to account" do
      {owner, account, subject} = owner_subject_fixture()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, account.id)

      assert {:ok, _event} = Accounts.record_account_switched(membership)

      {:ok, events, _} = Emisar.Audit.list_events(subject, page: [limit: 10])
      switched = Enum.find(events, &(&1.event_type == "session.account_switched"))

      assert switched
      assert switched.actor_id == owner.id
      assert switched.subject_label == owner.email
    end

    test "writes ONLY the audit row — the membership and account rows are untouched" do
      # switching the active tenant is session state plus an
      # audit trail; it must mutate no user-facing data. `record_account_switched/1`
      # inserts the audit event and nothing else, so the membership and account rows
      # are unchanged (the web layer's switch only re-validates + pins the session,
      # and re-validates membership server-side on every switch).
      {owner, account, _subject} = owner_subject_fixture()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, account.id)

      membership_before = Repo.reload!(membership)
      account_before = Repo.reload!(account)

      assert {:ok, _event} = Accounts.record_account_switched(membership)

      assert Repo.reload!(membership) == membership_before
      assert Repo.reload!(account) == account_before
    end
  end

  describe "update_user_as_admin/3" do
    test "an owner renames a member's profile" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      assert {:ok, %User{full_name: "Renamed By Admin"}} =
               Accounts.update_user_as_admin(
                 membership,
                 %{"full_name" => "Renamed By Admin"},
                 subject
               )
    end

    test "a viewer (no manage_team) is refused" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject)
    end

    test "an owner of another account can't edit this member (cross-account)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      # This path passes :unauthorized to ensure_subject_in_account (the team
      # UI already scoped the membership), so cross-account is :unauthorized.
      assert {:error, :unauthorized} =
               Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject_b)
    end
  end

  describe "end_all_sessions_for/2" do
    test "an owner force-signs-out a member everywhere" do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      subject = subject_for(owner, account, role: :owner)

      token = Emisar.Auth.create_session_token!(target, :magic_link, false)
      assert {:ok, %User{}, _auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)

      assert :ok = Accounts.end_all_sessions_for(membership, subject)
      assert {:error, :not_found} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a viewer (no manage_team) is refused" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Accounts.end_all_sessions_for(membership, subject)
    end

    test "an owner of another account can't end this member's sessions (cross-account)" do
      account = account_fixture()
      _ = membership_fixture(account_id: account.id, user_id: user_fixture().id, role: "owner")
      target = user_fixture()

      membership =
        membership_fixture(account_id: account.id, user_id: target.id, role: "operator")

      {_owner_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.end_all_sessions_for(membership, subject_b)
    end
  end

  describe "team_mfa_stats/2" do
    test "counts members and MFA enrollment account-wide (not per page)" do
      {owner, account, subject} = owner_subject_fixture()
      enroll_mfa(owner)

      enrolled_member = user_fixture()
      enroll_mfa(enrolled_member)
      membership_fixture(account_id: account.id, user_id: enrolled_member.id, role: "admin")

      unenrolled_member = user_fixture()
      membership_fixture(account_id: account.id, user_id: unenrolled_member.id, role: "viewer")

      assert {:ok, %{total: 3, enrolled: 2}} = Accounts.team_mfa_stats(account, subject)
    end

    test "counts only the subject's own account" do
      {owner, account, subject} = owner_subject_fixture()
      enroll_mfa(owner)

      # A separate account with its own enrolled member must not leak in.
      other_member = user_fixture()
      enroll_mfa(other_member)
      other_account = account_fixture()
      membership_fixture(account_id: other_account.id, user_id: other_member.id)

      assert {:ok, %{total: 1, enrolled: 1}} = Accounts.team_mfa_stats(account, subject)
    end

    test "refuses a subject from another account" do
      {_owner, account, _subject} = owner_subject_fixture()
      {_other_owner, _other_account, other_subject} = owner_subject_fixture()

      assert {:error, :unauthorized} = Accounts.team_mfa_stats(account, other_subject)
    end
  end

  describe "team-list broadcasts" do
    setup do
      account = account_fixture()
      owner = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
      target_user = user_fixture()

      target =
        membership_fixture(account_id: account.id, user_id: target_user.id, role: "operator")

      %{account: account, target: target, subject: subject_for(owner, account, role: :owner)}
    end

    test "suspending a member broadcasts {:list_changed, :team, …} on the account topic", %{
      account: account,
      target: target,
      subject: subject
    } do
      # A second admin's open team page subscribes to this topic and reloads
      # its roster when the broadcast lands — drive it from the context to prove
      # the after_commit publish fires (the LV's handle_info reload is covered
      # separately).
      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, _} = Accounts.suspend_membership(target, subject)

      assert_receive {:list_changed, :team, "membership.suspended", user_id}
      assert user_id == target.user_id
    end

    test "removing a member broadcasts {:list_changed, :team, …} on the account topic", %{
      account: account,
      target: target,
      subject: subject
    } do
      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert_receive {:list_changed, :team, "membership.removed", user_id}
      assert user_id == target.user_id
    end
  end

  defp enroll_mfa(user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(mfa_enabled_at: DateTime.utc_now())
      |> Repo.update()

    user
  end

  # Fully enroll a member's MFA — secret + recovery codes too, not just
  # the timestamp — so reset_member_mfa's "every field is wiped" assertion
  # is meaningful (clearing only the timestamp wouldn't prove the secret
  # and codes were dropped).
  defp enroll_member_mfa(user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: ["digest-a", "digest-b"]
      )
      |> Repo.update()

    user
  end
end
