defmodule Emisar.AccountsTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Fixtures
  alias Emisar.Mail
  alias Emisar.SSO.IdentityProvider
  alias Emisar.Users
  alias Emisar.Users.User

  describe "fetch_account_by_id/1" do
    test "resolves a live account by its id (pre-auth, no Subject)" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{id: id}} = Accounts.fetch_account_by_id(account.id)
      assert id == account.id
    end

    test "a soft-deleted account and an unused UUID are the SAME :not_found" do
      # The read starts at `not_deleted`, so a tombstoned account is
      # indistinguishable from one that never existed — both :not_found.
      account = Fixtures.Accounts.create_account()
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_account_by_id(account.id)
      assert {:error, :not_found} = Accounts.fetch_account_by_id(Ecto.UUID.generate())
    end

    test "a non-UUID id is :not_found, never a crash" do
      assert {:error, :not_found} = Accounts.fetch_account_by_id("not-a-uuid")
    end
  end

  describe "fetch_and_lock_account/2" do
    test "returns the account when called standalone (repo defaults to Repo)" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{id: id}} = Accounts.fetch_and_lock_account(account.id)
      assert id == account.id
    end

    test "a soft-deleted account is :not_found (the lock read starts at not_deleted)" do
      account = Fixtures.Accounts.create_account()
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_and_lock_account(account.id)
    end

    test "an unknown or malformed uuid is :not_found" do
      assert {:error, :not_found} = Accounts.fetch_and_lock_account(Ecto.UUID.generate())
      assert {:error, :not_found} = Accounts.fetch_and_lock_account("not-a-uuid")
    end

    test "the passed repo joins the caller's transaction" do
      # Approvals/Runners compose this as the first step of their Multi by
      # passing `repo: repo`; prove the explicit repo is honored inside one.
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{locked: %Account{id: id}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:locked, fn repo, _changes ->
                 Accounts.fetch_and_lock_account(account.id, repo: repo)
               end)
               |> Repo.transaction()

      assert id == account.id
    end
  end

  describe "fetch_account_settings/1" do
    test "returns the account's embedded settings value" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.set_account_settings(account, %{max_grant_lifetime_seconds: 3_600})

      assert {:ok, %Account.Settings{max_grant_lifetime_seconds: 3_600}} =
               Accounts.fetch_account_settings(account.id)
    end

    test "a soft-deleted account is :not_found (Approvals reads only live accounts)" do
      account = Fixtures.Accounts.create_account()
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_account_settings(account.id)
    end

    test "an unknown or malformed id is :not_found" do
      assert {:error, :not_found} = Accounts.fetch_account_settings(Ecto.UUID.generate())
      assert {:error, :not_found} = Accounts.fetch_account_settings("not-a-uuid")
    end
  end

  describe "fetch_account_by_id_or_slug/1 (pre-auth, no Subject)" do
    test "resolves a live account by slug or id — knowing the ref is all it takes" do
      # the branded sign-in page and the SSO
      # team picker resolve the tenant from the URL BEFORE anyone is signed in, so
      # this read takes NO `%Subject{}`: it's deliberately unauthorized (the slug
      # only picks which sign-in page to show; it grants nothing). It resolves by
      # the slug AND the id (the UUID form for SSO/redirects).
      account = Fixtures.Accounts.create_account()

      assert {:ok, %Account{id: id}} = Accounts.fetch_account_by_id_or_slug(account.slug)
      assert id == account.id
      assert {:ok, %Account{id: ^id}} = Accounts.fetch_account_by_id_or_slug(account.id)
    end

    test "an unknown ref and a soft-deleted account are the SAME :not_found (no leak)" do
      # the read starts at `not_deleted`, so a
      # tombstoned account is indistinguishable from one that never existed: both
      # `:not_found`. A pre-auth prober can't confirm a tenant exists from this read.
      account = Fixtures.Accounts.create_account()
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug("no-such-team")
      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug(account.slug)
      # A well-formed-but-unused UUID is the same :not_found, never a crash.
      assert {:error, :not_found} = Accounts.fetch_account_by_id_or_slug(Ecto.UUID.generate())
    end
  end

  describe "list_accounts_for_user/2" do
    test "lists every account the user is a non-suspended member of, name-ordered" do
      user = Fixtures.Users.create_user()
      zebra = Fixtures.Accounts.create_account(name: "Zebra Co")
      apple = Fixtures.Accounts.create_account(name: "Apple Co")
      _ = Fixtures.Memberships.create_membership(account_id: zebra.id, user_id: user.id)
      _ = Fixtures.Memberships.create_membership(account_id: apple.id, user_id: user.id)

      subject = Fixtures.Subjects.subject_for(user, apple)

      assert {:ok, accounts, _meta} = Accounts.list_accounts_for_user(subject)
      # Name-ordered (Apple before Zebra) — the account picker's order.
      assert Enum.map(accounts, & &1.name) == ["Apple Co", "Zebra Co"]
    end

    test "is deliberately cross-account: it scopes by the user, not a single account" do
      # The account picker must surface EVERY tenant the user belongs to, so it
      # scopes by the subject's actor id — a subject pinned to account A still
      # lists B. (The rare, documented IL-4 exception.)
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      subject = Fixtures.Subjects.subject_for(user, account_a)

      assert {:ok, accounts, _} = Accounts.list_accounts_for_user(subject)
      ids = accounts |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([account_a.id, account_b.id])
    end

    test "excludes a suspended membership's account" do
      user = Fixtures.Users.create_user()
      live = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: live.id, user_id: user.id)

      {_owner, suspended_account, owner_subject} = Fixtures.Subjects.owner_subject()

      suspended =
        Fixtures.Memberships.create_membership(
          account_id: suspended_account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(suspended, owner_subject)

      subject = Fixtures.Subjects.subject_for(user, live)

      assert {:ok, accounts, _} = Accounts.list_accounts_for_user(subject)
      ids = Enum.map(accounts, & &1.id)
      assert live.id in ids
      refute suspended_account.id in ids
    end

    test "returns an empty list for a user with no memberships" do
      user = Fixtures.Users.create_user()
      subject = %Emisar.Auth.Subject{actor: user}

      assert {:ok, [], _} = Accounts.list_accounts_for_user(subject)
    end
  end

  describe "create_account_with_owner/2" do
    test "persists account + owner membership in a single transaction" do
      user = Fixtures.Users.create_user()

      assert {:ok, %Account{} = account} =
               Accounts.create_account_with_owner(
                 %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
                 user
               )

      assert %Membership{role: :owner} =
               Fixtures.Memberships.fetch_membership(account.id, user.id)
    end

    test "rolls back when the account changeset is invalid" do
      user = Fixtures.Users.create_user()

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
        user = Fixtures.Users.create_user()
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
      user = Fixtures.Users.create_user()
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

  describe "update_account/3 — require_sso (owner + admin security setting)" do
    test "an owner can enable require_sso" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %Account{settings: %{require_sso: true}}} =
               Accounts.update_account(account, %{settings: %{require_sso: true}}, owner_subject)
    end

    test "an admin can enable require_sso (owners + admins manage security settings)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:ok, %Account{settings: %{require_sso: true}}} =
               Accounts.update_account(account, %{settings: %{require_sso: true}}, admin_subject)
    end

    test "an operator cannot change a security setting (no manage_security_settings)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(
                 account,
                 %{settings: %{require_sso: true}},
                 operator_subject
               )

      refute Repo.reload!(account).settings.require_sso
    end

    test "an owner of another account can't toggle this account's require_sso (cross-account)" do
      {_owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # B's owner holds `manage_own_account` for their OWN account, so the
      # permission gate passes; `ensure_subject_owns_account` then refuses the
      # cross-account write.
      assert {:error, :unauthorized} =
               Accounts.update_account(account_a, %{settings: %{require_sso: true}}, subject_b)

      refute Repo.reload!(account_a).settings.require_sso
    end

    test "an owner of another account can't toggle this account's require_mfa (cross-account)" do
      {_owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} =
               Accounts.update_account(account_a, %{settings: %{require_mfa: true}}, subject_b)

      refute Repo.reload!(account_a).settings.require_mfa
    end

    test "an admin can rename the account — only the security flags need manage_security_settings" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

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
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %Account{settings: %{max_grant_lifetime_seconds: 86_400}}} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 86_400}},
                 owner_subject
               )
    end

    test "an admin can set the cap (security setting)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:ok, %Account{settings: %{max_grant_lifetime_seconds: 3_600}}} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 3_600}},
                 admin_subject
               )
    end

    test "an operator cannot set the cap (no manage_security_settings)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 3_600}},
                 operator_subject
               )

      refute Repo.reload!(account).settings.max_grant_lifetime_seconds
    end

    test "the cap must be a positive number of seconds" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_account(
                 account,
                 %{settings: %{max_grant_lifetime_seconds: 0}},
                 owner_subject
               )
    end

    test "an owner of another account can't set this account's cap (cross-account)" do
      {_owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} =
               Accounts.update_account(
                 account_a,
                 %{settings: %{max_grant_lifetime_seconds: 3_600}},
                 subject_b
               )

      refute Repo.reload!(account_a).settings.max_grant_lifetime_seconds
    end
  end

  describe "change_account/2" do
    test "builds an update changeset for the form (no DB write)" do
      account = Fixtures.Accounts.create_account()

      changeset = Accounts.change_account(account, %{name: "Renamed"})

      assert %Ecto.Changeset{valid?: true} = changeset
      assert Ecto.Changeset.get_change(changeset, :name) == "Renamed"
      # It's a pure builder — the row on disk is untouched.
      assert Repo.reload!(account).name == account.name
    end

    test "with no attrs, yields a valid, change-free changeset" do
      account = Fixtures.Accounts.create_account()

      changeset = Accounts.change_account(account)

      assert %Ecto.Changeset{valid?: true, changes: changes} = changeset
      assert changes == %{}
    end

    test "surfaces validation errors for the inline form" do
      account = Fixtures.Accounts.create_account()

      changeset = Accounts.change_account(account, %{name: ""})

      refute changeset.valid?
      assert changeset.errors[:name]
    end
  end

  describe "suggest_unique_slug/1" do
    test "returns the slugified base when free" do
      assert Accounts.suggest_unique_slug("Acme Co!") =~ ~r/^acme-co/
    end

    test "appends -1, -2, ... on collision" do
      base = "team-#{System.unique_integer([:positive])}"
      _ = Fixtures.Accounts.create_account(slug: base)
      _ = Fixtures.Accounts.create_account(slug: base <> "-1")

      assert Accounts.suggest_unique_slug(base) == base <> "-2"
    end
  end

  describe "list_memberships_for_account/3" do
    test "lists the account's members for a member subject" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      _second = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships, _} = Accounts.list_memberships_for_account(account, subject)
      assert length(memberships) == 2
    end

    test "list_account_memberships/2 (system fan-out read) is scoped to the given account" do
      {_owner_a, account_a, _} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, _} = Fixtures.Subjects.owner_subject()
      _other = Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "a subject cannot list another account's memberships" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, _} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} =
               Accounts.list_memberships_for_account(account_b, subject_a)
    end
  end

  describe "list_memberships_for_users/3" do
    test "returns the given users' memberships, user preloaded" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      second = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships} =
               Accounts.list_memberships_for_users(account, [owner.id, second.user_id], subject)

      assert memberships |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([owner.id, second.user_id])

      assert Enum.all?(memberships, &match?(%Emisar.Users.User{}, &1.user))
    end

    test "ignores user_ids that aren't members of the account" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      stranger = Fixtures.Users.create_user()

      assert {:ok, [membership]} =
               Accounts.list_memberships_for_users(account, [owner.id, stranger.id], subject)

      assert membership.user_id == owner.id
    end

    test "a subject cannot read another account's memberships" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} =
               Accounts.list_memberships_for_users(account_b, [owner_b.id], subject_a)
    end
  end

  describe "team_mfa_stats/2" do
    test "counts members and MFA enrollment account-wide (not per page)" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      enroll_mfa(owner)

      enrolled_member = Fixtures.Users.create_user()
      enroll_mfa(enrolled_member)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: enrolled_member.id,
        role: "admin"
      )

      unenrolled_member = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: unenrolled_member.id,
        role: "viewer"
      )

      assert {:ok, %{total: 3, enrolled: 2}} = Accounts.team_mfa_stats(account, subject)
    end

    test "counts only the subject's own account" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      enroll_mfa(owner)

      # A separate account with its own enrolled member must not leak in.
      other_member = Fixtures.Users.create_user()
      enroll_mfa(other_member)
      other_account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: other_member.id
      )

      assert {:ok, %{total: 1, enrolled: 1}} = Accounts.team_mfa_stats(account, subject)
    end

    test "refuses a subject from another account" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      {_other_owner, _other_account, other_subject} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.team_mfa_stats(account, other_subject)
    end
  end

  describe "suppressed_member_emails/2" do
    test "returns the account's member emails that are on the suppression list" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      bouncing = Fixtures.Users.create_user(email: "bouncing@example.com")
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: bouncing.id)
      _fine = Fixtures.Memberships.create_membership(account_id: account.id)

      {:ok, _} = Mail.suppress("bouncing@example.com", :hard_bounce, "bounce")

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert suppressed == MapSet.new(["bouncing@example.com"])
    end

    test "is empty when no member email is suppressed" do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      _ = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account, subject)
      assert MapSet.size(suppressed) == 0
    end

    test "never surfaces a suppression that belongs only to another account" do
      {_owner_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, _} = Fixtures.Subjects.owner_subject()

      # An address suppressed globally, but a member only of account B.
      b_member = Fixtures.Users.create_user(email: "b-only@example.com")
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: b_member.id)
      {:ok, _} = Mail.suppress("b-only@example.com", :hard_bounce, "bounce")

      # Account A asks for ITS suppressed emails — B's bouncing address must not leak.
      assert {:ok, suppressed} = Accounts.suppressed_member_emails(account_a, subject_a)
      refute MapSet.member?(suppressed, "b-only@example.com")
      assert MapSet.size(suppressed) == 0
    end

    test "a subject cannot read another account's suppressed emails" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, _} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.suppressed_member_emails(account_b, subject_a)
    end
  end

  describe "list_account_memberships/2" do
    test "lists every membership in the account with :user preloaded (the notifier's contract)" do
      account = Fixtures.Accounts.create_account()
      one = Fixtures.Memberships.create_membership(account_id: account.id)
      two = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, memberships, _meta} = Accounts.list_account_memberships(account.id)

      ids = memberships |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([one.id, two.id])
      # `user` is this helper's contract — the approval notifier addresses the
      # email off it, so it must be preloaded, not an unloaded assoc.
      assert Enum.all?(memberships, &match?(%User{}, &1.user))
    end

    test "is scoped to the given account (no cross-account fan-out leak)" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert {:ok, memberships, _} = Accounts.list_account_memberships(account_a.id)
      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end
  end

  describe "list_active_memberships_for_user/1" do
    test "returns one membership per account the user actively belongs to" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      account_ids =
        user
        |> Accounts.list_active_memberships_for_user()
        |> Enum.map(& &1.account_id)
        |> Enum.sort()

      assert account_ids == Enum.sort([account_a.id, account_b.id])
    end

    test "returns [] for a user with no memberships" do
      user = Fixtures.Users.create_user()

      assert Accounts.list_active_memberships_for_user(user) == []
    end
  end

  describe "provision_sso_membership/3" do
    test "creates a membership at the given role for a JIT-provisioned user" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert {:ok, %Membership{role: :operator} = membership} =
               Accounts.provision_sso_membership(account.id, user.id, :operator)

      assert membership.account_id == account.id
      assert membership.user_id == user.id
    end

    test "refuses :owner — owner is never assignable via sync (defense in depth)" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert {:error, :owner_not_assignable} =
               Accounts.provision_sso_membership(account.id, user.id, :owner)

      # Nothing was written — the user has no membership in the account.
      assert is_nil(Fixtures.Memberships.fetch_membership(account.id, user.id))
    end
  end

  describe "peek_active_membership/2" do
    test "returns the membership when it is active (not deleted, not disabled)" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      assert %Membership{id: id} = Accounts.peek_active_membership(account.id, member.id)
      assert id == member.id
    end

    test "returns nil when the membership is suspended (the engine halts mid-run)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(member, owner_subject)

      assert is_nil(Accounts.peek_active_membership(account.id, member.id))
    end

    test "returns nil when the membership is soft-deleted" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)
      {:ok, _} = member |> Membership.Changeset.delete() |> Repo.update()

      assert is_nil(Accounts.peek_active_membership(account.id, member.id))
    end

    test "returns nil when the membership belongs to a different account (account-scoped)" do
      member = Fixtures.Memberships.create_membership()
      other_account = Fixtures.Accounts.create_account()

      assert is_nil(Accounts.peek_active_membership(other_account.id, member.id))
    end

    test "returns nil for non-binary args (the guard's fallback clause)" do
      assert is_nil(Accounts.peek_active_membership(nil, nil))
    end
  end

  describe "peek_sync_membership/2" do
    test "returns the membership joining the account + user" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      member = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert %Membership{id: id} = Accounts.peek_sync_membership(account.id, user.id)
      assert id == member.id
    end

    test "returns a deprovisioned (disabled) row too — a SCIM reconcile reads it back" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(member, owner_subject)

      # peek_sync_membership ignores disabled_at — a deprovisioned member still
      # has a row the reconcile must resolve.
      assert %Membership{disabled_at: %DateTime{}} =
               Accounts.peek_sync_membership(account.id, user.id)
    end

    test "returns nil when there is no membership for the pair" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert is_nil(Accounts.peek_sync_membership(account.id, user.id))
    end
  end

  describe "list_sync_memberships/2" do
    test "returns the memberships for the requested set of users in one query" do
      account = Fixtures.Accounts.create_account()
      user_one = Fixtures.Users.create_user()
      user_two = Fixtures.Users.create_user()
      user_three = Fixtures.Users.create_user()

      m_one = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_one.id)
      m_two = Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_two.id)

      _three =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user_three.id)

      memberships = Accounts.list_sync_memberships(account.id, [user_one.id, user_two.id])

      ids = memberships |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([m_one.id, m_two.id])
    end

    test "is scoped to the account — a same-user membership in another account is excluded" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      _a = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)
      _b = Fixtures.Memberships.create_membership(account_id: account_b.id, user_id: user.id)

      memberships = Accounts.list_sync_memberships(account_a.id, [user.id])

      assert memberships |> Enum.map(& &1.account_id) |> Enum.uniq() == [account_a.id]
    end

    test "returns an empty list when no user matches" do
      account = Fixtures.Accounts.create_account()

      assert Accounts.list_sync_memberships(account.id, [Ecto.UUID.generate()]) == []
    end
  end

  describe "fetch_membership_for_session/2" do
    setup do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      %{
        user: user,
        account: account
      }
    end

    test "with no account_id, returns the most-recent non-disabled membership", %{
      user: user,
      account: first_account
    } do
      second_account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      second_membership =
        Fixtures.Memberships.create_membership(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} = Accounts.fetch_membership_for_session(user, nil)
      assert id == second_membership.id
    end

    test "with a matching account_id, returns that specific membership even if older" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      second_account = Fixtures.Accounts.create_account()

      first_membership =
        Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      _ = Fixtures.Memberships.create_membership(account_id: second_account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = account}} =
               Accounts.fetch_membership_for_session(user, first_account.id)

      assert id == first_membership.id
      assert account.id == first_account.id
    end

    test "with a stale or unknown account_id, falls back to the primary" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, Ecto.UUID.generate())

      assert returned_account_id == first_account.id
    end

    test "with a suspended membership on the requested account, falls back" do
      user = Fixtures.Users.create_user()
      first_account = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: first_account.id, user_id: user.id)

      {_owner_user, second_account, owner_subject} = Fixtures.Subjects.owner_subject()

      second_membership =
        Fixtures.Memberships.create_membership(
          account_id: second_account.id,
          user_id: user.id,
          role: "operator"
        )

      assert {:ok, _} = Accounts.suspend_membership(second_membership, owner_subject)

      assert {:ok, %Membership{account_id: returned_account_id}} =
               Accounts.fetch_membership_for_session(user, second_account.id)

      refute returned_account_id == second_account.id
    end

    test "returns :not_found for a user with no memberships" do
      assert {:error, :not_found} =
               Accounts.fetch_membership_for_session(Fixtures.Users.create_user(), nil)
    end
  end

  describe "fetch_membership_by_account_id_or_slug/2" do
    test "resolves the user's membership by the account slug" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id, account: %Account{} = resolved, user: %User{}}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.slug)

      assert id == membership.id
      assert resolved.id == account.id
    end

    test "resolves by the account id too (the UUID form for API/SSO/redirects)" do
      user = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      assert {:ok, %Membership{id: id}} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.id)

      assert id == membership.id
    end

    test "a non-member's slug is indistinguishable from an unknown one (404, never a leak)" do
      member = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      outsider = Fixtures.Users.create_user()

      # The account exists, but the outsider isn't a member: SAME :not_found as
      # a slug no account has — so a URL never confirms a tenant exists (404, not 403).
      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(outsider, account.slug)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(outsider, "no-such-team")
    end

    test "a member of account A cannot resolve account B (cross-account, by slug or id)" do
      user = Fixtures.Users.create_user()
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id, user_id: user.id)

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account_b.id,
          user_id: Fixtures.Users.create_user().id
        )

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account_b.slug)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account_b.id)
    end

    test "a suspended membership does not resolve" do
      user = Fixtures.Users.create_user()
      {_owner_user, account, owner_subject} = Fixtures.Subjects.owner_subject()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      assert {:ok, _} = Accounts.suspend_membership(membership, owner_subject)

      assert {:error, :not_found} =
               Accounts.fetch_membership_by_account_id_or_slug(user, account.slug)
    end
  end

  describe "record_account_switched/1" do
    test "writes the session.account_switched audit row for the switched-to account" do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
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
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      {:ok, membership} = Accounts.fetch_membership_for_session(owner, account.id)

      membership_before = Repo.reload!(membership)
      account_before = Repo.reload!(account)

      assert {:ok, _event} = Accounts.record_account_switched(membership)

      assert Repo.reload!(membership) == membership_before
      assert Repo.reload!(account) == account_before
    end
  end

  describe "all_memberships_suspended?/1" do
    test "is true when every membership the user holds is suspended" do
      user = Fixtures.Users.create_user()
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(membership, owner_subject)

      assert Accounts.all_memberships_suspended?(user)
    end

    test "is false when at least one membership is still active" do
      user = Fixtures.Users.create_user()
      live_account = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: live_account.id, user_id: user.id)

      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      suspended =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      {:ok, _} = Accounts.suspend_membership(suspended, owner_subject)

      # One active membership remains → not "all suspended".
      refute Accounts.all_memberships_suspended?(user)
    end

    test "is false when the user has NO memberships (distinct from 'all suspended')" do
      # The UI distinguishes "your access was suspended" from "go to onboarding";
      # a user with zero memberships is the latter, so this must be false.
      user = Fixtures.Users.create_user()

      refute Accounts.all_memberships_suspended?(user)
    end
  end

  describe "update_membership_role/3" do
    test "the last active owner can't demote themselves; with a second owner it works" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      owner_m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      # Sole owner — the in-transaction guard (locked re-count of the
      # account's active owner rows) refuses the demotion.
      assert {:error, :last_owner} = Accounts.update_membership_role(owner_m, "admin", subject)

      # A second active owner frees the demotion.
      second = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: second.id,
          role: "owner"
        )

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(owner_m, "admin", subject)
    end

    test "promotes operator to admin" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :admin}} =
               Accounts.update_membership_role(m, "admin", subject)
    end

    test "rejects an unknown role" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:error, cs} = Accounts.update_membership_role(m, "supreme-leader", subject)
      assert "is invalid" in errors_on(cs).role
    end

    test "an admin cannot grant the owner role (no escalation by proxy)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(m, "owner", subject)
    end

    test "an admin cannot demote an owner (can't outrank a superior)" do
      account = Fixtures.Accounts.create_account()

      owner_m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.update_membership_role(owner_m, "operator", subject)
    end

    test "you cannot promote yourself" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      admin_m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :cannot_self_promote} =
               Accounts.update_membership_role(admin_m, "owner", subject)
    end

    test "an owner can grant the owner role" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{role: :owner}} =
               Accounts.update_membership_role(m, "owner", subject)
    end

    test "an owner of another account can't change this member's role (cross-account)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # `ensure_subject_in_account` (passed :unauthorized) fires before the
      # `for_subject`-scoped row read, so the cross-account mutation is refused
      # without touching A's row.
      assert {:error, :unauthorized} =
               Accounts.update_membership_role(target, "admin", subject_b)

      # A's membership is untouched — still operator.
      assert %Membership{role: :operator} =
               Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end
  end

  describe "subscribe_account_team/1" do
    test "the subscriber receives the account's team-list broadcasts" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert :ok = Accounts.subscribe_account_team(account.id)

      # A team mutation publishes on the topic the subscriber just joined.
      assert {:ok, _} = Accounts.suspend_membership(target, owner_subject)
      assert_receive {:list_changed, :team, "membership.suspended", user_id}
      assert user_id == target.user_id
    end

    test "a subscriber to account A does not receive account B's broadcasts" do
      {_owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, owner_subject_b} = Fixtures.Subjects.owner_subject()

      target_b =
        Fixtures.Memberships.create_membership(account_id: account_b.id, role: "operator")

      assert :ok = Accounts.subscribe_account_team(account_a.id)

      # The mutation happens on B's topic — A's subscriber must hear nothing.
      assert {:ok, _} = Accounts.suspend_membership(target_b, owner_subject_b)
      refute_receive {:list_changed, :team, _event, _user_id}
    end
  end

  describe "suspend_membership/2 + reinstate_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
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
      admin = Fixtures.Users.create_user()

      admin_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: admin.id)

      assert is_nil(Emisar.Repo.reload!(key).revoked_at)

      assert {:ok, _} = Accounts.suspend_membership(admin_membership, owner_subject)

      # after_commit revokes the keys the suspended member minted so they
      # can't keep dispatching via MCP / OAuth after losing access.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "operator cannot suspend anyone", %{account: account, target: target} do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

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
      second_owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: second_owner.id,
          role: "owner"
        )

      second_owner_subject = Fixtures.Subjects.subject_for(second_owner, account, role: :owner)
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
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.suspend_membership(target, subject_b)

      refute Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )
    end

    test "operator cannot reinstate anyone", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      # Suspend as owner first so there's a disabled row to reinstate; reinstate
      # shares suspend's manage_team gate, so a non-manager is refused — and the
      # row stays disabled.
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.reinstate_membership(suspended, operator_subject)

      assert Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )
    end

    test "an owner of another account can't reinstate this member (cross-account)", %{
      account: account,
      target: target,
      owner_subject: owner_subject
    } do
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # :unauthorized (not :not_found) — accounts gates struct-taking writes with
      # ensure_subject_in_account(:unauthorized) before the for_subject fetch, so
      # account B is refused and the member stays suspended in account A.
      assert {:error, :unauthorized} = Accounts.reinstate_membership(suspended, subject_b)

      assert Membership.disabled?(
               Fixtures.Memberships.fetch_membership(account.id, target.user_id)
             )
    end
  end

  describe "reinstate_membership/2" do
    test "reinstating clears disabled_at and broadcasts the reinstate" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject)
      assert Membership.disabled?(suspended)

      :ok = Accounts.subscribe_account_team(account.id)

      assert {:ok, reinstated} = Accounts.reinstate_membership(suspended, owner_subject)
      refute Membership.disabled?(reinstated)
      assert is_nil(Repo.reload!(target).disabled_at)

      assert_receive {:list_changed, :team, "membership.reinstated", user_id}
      assert user_id == target.user_id
    end

    test "an owner of another account can't reinstate this member (cross-account)" do
      {_owner_a, account_a, owner_subject_a} = Fixtures.Subjects.owner_subject()
      target = Fixtures.Memberships.create_membership(account_id: account_a.id, role: "operator")
      {:ok, suspended} = Accounts.suspend_membership(target, owner_subject_a)

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.reinstate_membership(suspended, subject_b)
      assert Membership.disabled?(Repo.reload!(target))
    end
  end

  describe "sync_suspend_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "suspends a member the IdP deprovisioned (disabled_at set, attributed to the provider)",
         %{account: account, provider: provider} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{} = suspended} =
               Accounts.sync_suspend_membership(member, provider)

      assert Membership.disabled?(suspended)
      assert Membership.disabled?(Repo.reload!(member))
    end

    test "revokes the API keys the deprovisioned member minted", %{
      account: account,
      provider: provider
    } do
      member_user = Fixtures.Users.create_user()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member_user.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member_user.id)

      assert is_nil(Repo.reload!(key).revoked_at)

      assert {:ok, _} = Accounts.sync_suspend_membership(member, provider)

      # Mirrors suspend_membership/2: after_commit kills the keys so a
      # deprovisioned member can't keep dispatching.
      refute is_nil(Repo.reload!(key).revoked_at)
    end

    test "the last-active-owner guard still fires — a deprovision can't lock out the account",
         %{account: account, provider: provider} do
      sole_owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      assert {:error, :last_owner} = Accounts.sync_suspend_membership(sole_owner, provider)
      refute Membership.disabled?(Repo.reload!(sole_owner))
    end

    test "rejects a membership outside the provider's account (the write-path backstop)", %{
      provider: provider
    } do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert {:error, :not_found} = Accounts.sync_suspend_membership(other, provider)
      assert is_nil(Repo.reload!(other).disabled_at)
    end
  end

  describe "sync_reinstate_membership/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "reinstates a member the IdP re-provisioned (clears disabled_at)", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {:ok, suspended} = Accounts.sync_suspend_membership(member, provider)
      assert Membership.disabled?(suspended)

      assert {:ok, %Membership{} = reinstated} =
               Accounts.sync_reinstate_membership(suspended, provider)

      refute Membership.disabled?(reinstated)
      assert is_nil(Repo.reload!(member).disabled_at)
    end

    test "rejects a membership outside the provider's account", %{provider: provider} do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert {:error, :not_found} = Accounts.sync_reinstate_membership(other, provider)
    end
  end

  describe "sync_set_membership_role/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      provider = provider_fixture(account)
      %{account: account, provider: provider}
    end

    test "sets the member's role from their mapped IdP groups", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:ok, %Membership{role: :operator}} =
               Accounts.sync_set_membership_role(member, :operator, provider)

      assert Repo.reload!(member).role == :operator
    end

    test "is idempotent — an already-matching role returns {:ok, membership} with no write", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, %Membership{role: :operator} = returned} =
               Accounts.sync_set_membership_role(member, :operator, provider)

      # The matching-role clause returns the caller's struct without touching the row.
      assert returned.id == member.id
    end

    test "refuses :owner — owner stays a deliberate human grant (defense in depth)", %{
      account: account,
      provider: provider
    } do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:error, :owner_not_assignable} =
               Accounts.sync_set_membership_role(member, :owner, provider)

      assert Repo.reload!(member).role == :viewer
    end

    test "never demotes the account's last active owner", %{account: account, provider: provider} do
      sole_owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      assert {:error, :last_owner} =
               Accounts.sync_set_membership_role(sole_owner, :admin, provider)

      assert Repo.reload!(sole_owner).role == :owner
    end

    test "rejects a membership outside the provider's account", %{provider: provider} do
      other = Fixtures.Memberships.create_membership(role: "operator")

      assert {:error, :not_found} = Accounts.sync_set_membership_role(other, :admin, provider)
      assert Repo.reload!(other).role == :operator
    end
  end

  describe "clear_directory_managed_for_users/2" do
    test "clears the flag only for the named members, leaving other synced members" do
      account = Fixtures.Accounts.create_account()
      freed = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      Fixtures.Memberships.mark_directory_managed(freed)
      kept = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      Fixtures.Memberships.mark_directory_managed(kept)

      Accounts.clear_directory_managed_for_users(account.id, [freed.user_id])

      refute Repo.reload!(freed).directory_managed
      assert Repo.reload!(kept).directory_managed
    end
  end

  describe "reset_member_mfa/2" do
    test "an owner clears a member's MFA + writes the user.mfa_reset_by_admin audit row" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %User{} = updated} = Accounts.reset_member_mfa(target, owner_subject)

      # Every MFA field is wiped — the member can no longer present a factor.
      assert is_nil(updated.mfa_enabled_at)
      assert is_nil(updated.mfa_secret)
      assert updated.mfa_recovery_codes == []

      # And it's persisted, not just on the returned struct.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      assert is_nil(reloaded.mfa_enabled_at)

      events = Emisar.Audit.list_events(owner_subject, page: [limit: 10]) |> elem(1)
      assert Enum.any?(events, &(&1.event_type == "user.mfa_reset_by_admin"))
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Accounts.reset_member_mfa(target, subject)

      # The member's factor is untouched.
      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an admin can't reset an owner's MFA (hierarchy)" do
      account = Fixtures.Accounts.create_account()
      owner = enroll_member_mfa(Fixtures.Users.create_user())

      owner_m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} = Accounts.reset_member_mfa(owner_m, subject)

      {:ok, reloaded} = Users.fetch_user_by_id(owner.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end

    test "an owner of another account can't reset this member's MFA (cross-account)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target_user = enroll_member_mfa(Fixtures.Users.create_user())

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.reset_member_mfa(target, subject_b)

      {:ok, reloaded} = Users.fetch_user_by_id(target_user.id)
      refute is_nil(reloaded.mfa_enabled_at)
    end
  end

  describe "update_user_as_admin/3" do
    test "an owner renames a member's profile" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %User{full_name: "Renamed By Admin"}} =
               Accounts.update_user_as_admin(
                 membership,
                 %{"full_name" => "Renamed By Admin"},
                 subject
               )
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject)
    end

    test "an owner of another account can't edit this member (cross-account)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # This path passes :unauthorized to ensure_subject_in_account (the team
      # UI already scoped the membership), so cross-account is :unauthorized.
      assert {:error, :unauthorized} =
               Accounts.update_user_as_admin(membership, %{"full_name" => "x"}, subject_b)
    end
  end

  describe "end_all_sessions_for/2" do
    test "an owner force-signs-out a member everywhere" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      token = Emisar.Auth.create_session_token!(target, :magic_link, false)
      assert {:ok, %User{}, _auth} = Emisar.Auth.fetch_user_and_token_by_session_token(token)

      assert :ok = Accounts.end_all_sessions_for(membership, subject)
      assert {:error, :not_found} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
    end

    test "a viewer (no manage_team) is refused" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Accounts.end_all_sessions_for(membership, subject)
    end

    test "an owner of another account can't end this member's sessions (cross-account)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.end_all_sessions_for(membership, subject_b)
    end
  end

  describe "delete_membership/3" do
    test "owner can remove a non-owner member" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Membership{} = removed} = Accounts.delete_membership(target, subject)

      # Removal is a soft delete: the tombstone keeps history while every
      # not_deleted() read treats the member as gone.
      assert removed.deleted_at
      assert {:error, :not_found} = Accounts.fetch_membership_for_session(target_user, account.id)
    end

    test "removing a member revokes the API keys they minted" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      member = Fixtures.Users.create_user()

      member_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {_raw, key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member.id)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # Sessions self-heal at membership resolution; the minted keys don't,
      # so removal revokes them (after_commit) to cut off MCP / OAuth.
      refute is_nil(Emisar.Repo.reload!(key).revoked_at)
    end

    test "a removed member can be re-invited (tombstone doesn't hold the seat)" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, _} = Accounts.delete_membership(target, subject)

      assert {:ok, %{membership: fresh}} =
               Accounts.invite_user_to_account(target_user.email, "viewer", subject)

      assert fresh.user_id == target_user.id
      assert fresh.id != target.id
    end

    test "an operator (no manage_team permission) cannot remove a member → :unauthorized" do
      account = Fixtures.Accounts.create_account()
      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "viewer"
        )

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)

      assert {:error, :unauthorized} = Accounts.delete_membership(target, operator_subject)
      # The target membership is still present.
      assert %Membership{} = Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end

    test "an admin cannot remove an owner" do
      account = Fixtures.Accounts.create_account()

      owner_m =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} = Accounts.delete_membership(owner_m, subject)
    end

    test "an owner of another account can't remove this member (cross-account)" do
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: Fixtures.Users.create_user().id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :unauthorized} = Accounts.delete_membership(target, subject_b)
      # A's membership survives.
      assert %Membership{} = Fixtures.Memberships.fetch_membership(account.id, target_user.id)
    end

    test "a removed member's API key can no longer resolve for dispatch" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      member = Fixtures.Users.create_user()

      member_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "admin"
        )

      {raw, _key} =
        Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: member.id)

      # The key resolves while the member is active — the MCP/OAuth auth boundary.
      assert %Emisar.ApiKeys.ApiKey{} = Emisar.ApiKeys.peek_api_key_by_secret(raw)

      assert {:ok, _} = Accounts.delete_membership(member_membership, subject)

      # After removal the key is revoked (after_commit), so the credential
      # resolution that precedes building a Subject returns nil — no dispatch.
      assert is_nil(Emisar.ApiKeys.peek_api_key_by_secret(raw))
    end
  end

  describe "invite_user_to_account/3" do
    test "creates a placeholder user for an unknown email" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

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
      inviter = Fixtures.Users.create_user()
      existing = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      assert {:ok, %{user: %User{id: id}}} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)

      assert id == existing.id
    end

    test "refuses duplicate memberships" do
      inviter = Fixtures.Users.create_user()
      existing = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      _ = Fixtures.Memberships.create_membership(account_id: account.id, user_id: existing.id)
      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      assert {:error, :already_member} =
               Accounts.invite_user_to_account(existing.email, "operator", subject)
    end

    test "an admin cannot invite an owner (can't grant a role it doesn't hold)" do
      admin = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      email = "owner-invite-#{System.unique_integer([:positive])}@example.test"

      assert {:error, :insufficient_privileges} =
               Accounts.invite_user_to_account(email, "owner", subject)
    end

    test "seats are uncapped — inviting well past any prior limit always succeeds" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

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
      {_owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()

      email = "cross-#{System.unique_integer([:positive])}@example.test"

      # The membership's account is read off `subject.account`, so B's owner can
      # only ever invite into B — there is no caller-supplied account id to
      # redirect the invite into A.
      assert {:ok, %{membership: %Membership{account_id: account_id}, user: invitee}} =
               Accounts.invite_user_to_account(email, "operator", subject_b)

      assert account_id == account_b.id
      # And nothing was written into A: the invitee has no membership there.
      assert is_nil(Fixtures.Memberships.fetch_membership(account_a.id, invitee.id))
    end
  end

  describe "resend_account_invitation/2" do
    test "refreshes the pending invite token and validity window" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()
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
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "viewer-denied-#{System.unique_integer([:positive])}@example.test",
          "operator",
          owner_subject
        )

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Accounts.resend_account_invitation(membership, viewer_subject)

      assert Repo.reload!(membership).invitation_token_digest ==
               membership.invitation_token_digest
    end

    test "an owner of another account cannot resend this account's invitation" do
      {_owner_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_owner_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

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
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

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
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "owner-resend-#{System.unique_integer([:positive])}@example.test",
          "owner",
          owner_subject
        )

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert {:error, :insufficient_privileges} =
               Accounts.resend_account_invitation(membership, admin_subject)
    end
  end

  describe "fetch_invitation_by_token/2" do
    test "resolves a pending invitation by its raw token" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(
          "tok-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      assert {:ok, %Membership{id: id}} = Accounts.fetch_invitation_by_token(token)
      assert id == membership.id
    end

    test "honors the :preload option for the accept page's render" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: token}} =
        Accounts.invite_user_to_account(
          "tok-preload-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      assert {:ok, %Membership{account: %Account{}, user: %User{}}} =
               Accounts.fetch_invitation_by_token(token, preload: [:account, :user])
    end

    test "an empty/blank/nil token is :not_found (the guard clauses)" do
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("")
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(nil)
      assert {:error, :not_found} = Accounts.fetch_invitation_by_token("not-a-real-token")
    end

    test "an accepted invitation no longer resolves (pending-only)" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: user, invitation_token: token}} =
        Accounts.invite_user_to_account(
          "tok-accepted-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      {:ok, _} = Accounts.mark_invitation_accepted(membership, user)

      assert {:error, :not_found} = Accounts.fetch_invitation_by_token(token)
    end
  end

  describe "mark_invitation_accepted/1" do
    test "stamps invitation_accepted_at + clears the token without touching the user" do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

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
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: inviter.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(inviter, account, role: :owner)

      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{membership: membership, invitation_token: token}} =
        Accounts.invite_user_to_account(email, "operator", subject)

      attacker = Fixtures.Users.create_user()

      assert {:error, :unauthorized} =
               Accounts.mark_invitation_accepted(membership, attacker)

      # The token survives, so the real invitee can still accept.
      assert {:ok, found} = Accounts.fetch_invitation_by_token(token)
      assert found.id == membership.id
    end
  end

  describe "accept_invitation/2" do
    test "sets the invitee's name + password, confirms them, and clears the token" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership, user: invitee}} =
        Accounts.invite_user_to_account(
          "accept-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      # The placeholder user is unconfirmed with no password until acceptance.
      refute invitee.confirmed_at

      assert {:ok, %{user: %User{} = user, membership: %Membership{} = accepted}} =
               Accounts.accept_invitation(membership, %{
                 "full_name" => "Accepted Member",
                 "password" => "a-very-strong-password"
               })

      assert user.full_name == "Accepted Member"
      # Acceptance proves email ownership, so the user is confirmed and the
      # invitation token is cleared.
      refute is_nil(user.confirmed_at)
      assert accepted.invitation_accepted_at != nil
      refute accepted.invitation_token_digest
    end

    test "the first acceptor wins — a second accept on the burnt token is :not_found" do
      {_owner, _account, subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: membership}} =
        Accounts.invite_user_to_account(
          "race-#{System.unique_integer([:positive])}@example.test",
          "operator",
          subject
        )

      assert {:ok, _} =
               Accounts.accept_invitation(membership, %{
                 "full_name" => "First",
                 "password" => "a-very-strong-password"
               })

      # The locked re-judge of the (now non-pending) invitation refuses the
      # second submit before it could overwrite the winner's password.
      assert {:error, :not_found} =
               Accounts.accept_invitation(membership, %{
                 "full_name" => "Second",
                 "password" => "another-strong-password"
               })
    end
  end

  describe "count_memberships/1" do
    test "counts the account's membership rows (the Billing seat count)" do
      account = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account.id)
      _ = Fixtures.Memberships.create_membership(account_id: account.id)

      assert Accounts.count_memberships(account.id) == 2
    end

    test "counts suspended members (suspension preserves the seat)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Accounts.count_memberships(account.id) == 2
      {:ok, _} = Accounts.suspend_membership(member, owner_subject)
      # Suspension keeps the seat — still 2.
      assert Accounts.count_memberships(account.id) == 2
    end

    test "does NOT count soft-deleted (removed) members — they free the seat" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Accounts.count_memberships(account.id) == 2
      {:ok, _} = Accounts.delete_membership(member, owner_subject)
      # Removal frees the seat — back to 1 (the owner).
      assert Accounts.count_memberships(account.id) == 1
    end

    test "is scoped to the account" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Memberships.create_membership(account_id: account_a.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id)
      _ = Fixtures.Memberships.create_membership(account_id: account_b.id)

      assert Accounts.count_memberships(account_a.id) == 1
    end
  end

  describe "peek_account_by_paddle_customer_id/1" do
    test "resolves the account a Paddle customer id belongs to" do
      account = Fixtures.Accounts.create_account()
      {:ok, linked} = Accounts.put_account_paddle_customer_id(account, "ctm_123")

      assert %Account{id: id} = Accounts.peek_account_by_paddle_customer_id("ctm_123")
      assert id == linked.id
    end

    test "resolves a soft-deleted account too (final-invoice webhooks must still land)" do
      # Deliberately all(), not not_deleted(): a tombstoned account's
      # cancellation/final-invoice webhooks must still resolve so Billing can
      # close the books.
      account = Fixtures.Accounts.create_account()
      {:ok, _} = Accounts.put_account_paddle_customer_id(account, "ctm_deleted")
      {:ok, _} = account |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert %Account{id: id} = Accounts.peek_account_by_paddle_customer_id("ctm_deleted")
      assert id == account.id
    end

    test "returns nil for an unknown customer id (the webhook no-ops on it)" do
      assert is_nil(Accounts.peek_account_by_paddle_customer_id("ctm_unknown"))
    end
  end

  describe "put_account_paddle_customer_id/2" do
    test "stamps the Paddle customer id on first checkout" do
      account = Fixtures.Accounts.create_account()
      assert is_nil(account.paddle_customer_id)

      assert {:ok, %Account{paddle_customer_id: "ctm_first"}} =
               Accounts.put_account_paddle_customer_id(account, "ctm_first")

      assert Repo.reload!(account).paddle_customer_id == "ctm_first"
    end

    test "first-wins: a second checkout keeps the already-linked id" do
      account = Fixtures.Accounts.create_account()
      {:ok, _} = Accounts.put_account_paddle_customer_id(account, "ctm_winner")

      # The loser's write is a no-op — the caller gets the winning account back,
      # still carrying the first id (callers read the id off the RETURNED account).
      assert {:ok, %Account{paddle_customer_id: "ctm_winner"}} =
               Accounts.put_account_paddle_customer_id(account, "ctm_loser")

      assert Repo.reload!(account).paddle_customer_id == "ctm_winner"
    end
  end

  describe "soft-deleted associations are excluded from preloads" do
    test "account preload skips a soft-deleted membership (preloader honors :where)" do
      account = Fixtures.Accounts.create_account()
      live_user = Fixtures.Users.create_user()
      doomed_user = Fixtures.Users.create_user()

      _live =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: live_user.id)

      doomed =
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: doomed_user.id)

      {:ok, _} = doomed |> Membership.Changeset.delete() |> Emisar.Repo.update()

      {:ok, loaded} =
        Account.Query.not_deleted()
        |> Account.Query.by_id(account.id)
        |> Emisar.Repo.fetch(Account.Query, preload: [:memberships])

      assert [%Membership{} = only] = loaded.memberships
      assert only.user_id == live_user.id
    end
  end

  describe "subject_can_manage_team?/1" do
    test "is true for an owner and an admin (they hold manage_team)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.subject_can_manage_team?(owner_subject)
      assert Accounts.subject_can_manage_team?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Accounts.subject_can_manage_team?(operator_subject)
      refute Accounts.subject_can_manage_team?(viewer_subject)
    end
  end

  describe "subject_can_manage_account_security?/1" do
    test "is true for an owner and an admin (they hold manage_security_settings)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.subject_can_manage_account_security?(owner_subject)
      assert Accounts.subject_can_manage_account_security?(admin_subject)
    end

    test "is false for an operator and a viewer" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      operator = Fixtures.Users.create_user()
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      refute Accounts.subject_can_manage_account_security?(operator_subject)
      refute Accounts.subject_can_manage_account_security?(viewer_subject)
    end
  end

  describe "team-list broadcasts" do
    setup do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      target_user = Fixtures.Users.create_user()

      target =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: target_user.id,
          role: "operator"
        )

      %{
        account: account,
        target: target,
        subject: Fixtures.Subjects.subject_for(owner, account, role: :owner)
      }
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

  # Build an IdP provider for the directory-sync tests. The provider's account
  # IS the authorization on the no-Subject sync path, so the sync_* functions
  # need only a persisted provider scoped to the right account — not a full
  # SCIM-enabled one. Owner is rejected as a default_role, so use :viewer.
  defp provider_fixture(account) do
    attrs = %{
      kind: :okta,
      name: "Okta",
      issuer: "https://idp.test",
      client_id: "cid",
      client_secret: "secret",
      enabled: true,
      default_role: :viewer
    }

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
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
