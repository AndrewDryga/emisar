defmodule Emisar.Seeds.SmokeTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Accounts, Approvals, Auth, Fixtures, Repo, Runbooks, Users}

  test "reseed attributes a changed release to the seed owner without replacing its author" do
    user = Fixtures.Users.create_user(email: "demo@emisar.dev")
    account = Fixtures.Accounts.create_account(slug: "demo")

    owner =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    author = Fixtures.Memberships.create_membership(account_id: account.id)

    runbook =
      Fixtures.Runbooks.create_runbook(
        account_id: account.id,
        created_by_membership_id: author.id,
        slug: "morning-edge-readiness"
      )
      |> Fixtures.Runbooks.publish_runbook()

    ExUnit.CaptureIO.capture_io(fn ->
      Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
    end)

    assert Repo.reload!(runbook).created_by_membership_id == author.id

    releases =
      Repo.all(Runbooks.Release)
      |> Enum.filter(&(&1.runbook_id == runbook.id))
      |> Enum.sort_by(& &1.version)

    assert Enum.map(releases, & &1.published_by_membership_id) == [author.id, owner.id]
  end

  test "reseed restores screenshot-account sign-in policy without changing staff or unrelated accounts" do
    seed = fn ->
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)
    end

    seed.()
    {:ok, user} = Users.fetch_user_by_email("demo@emisar.dev")

    Fixtures.Users.set_mfa_state(user,
      mfa_secret: Auth.generate_mfa_secret(),
      mfa_enabled_at: DateTime.utc_now()
    )

    screenshot_accounts =
      for slug <- ["demo", "acme", "globex", "blank", "both-connected"] do
        account =
          Accounts.Account.Query.not_deleted()
          |> Accounts.Account.Query.by_slug(slug)
          |> Repo.one!()

        # MFA can be required in each of these plans. The enterprise demo can
        # additionally enforce its configured SSO connection.
        settings = %{require_mfa: true, require_sso: slug == "demo", monthly_report_opt_out: true}
        Fixtures.Accounts.set_account_settings(account, settings)
      end

    staff =
      Accounts.Account.Query.not_deleted()
      |> Accounts.Account.Query.by_slug("emisar-staff")
      |> Repo.one!()

    Fixtures.Accounts.set_account_settings(staff, %{require_mfa: true})
    unrelated = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(unrelated, %{require_mfa: true})

    seed.()

    for account <- screenshot_accounts do
      settings = Repo.reload!(account).settings
      refute settings.require_mfa
      refute settings.require_sso
      assert settings.monthly_report_opt_out
    end

    assert Repo.reload!(staff).settings.require_mfa
    assert Repo.reload!(unrelated).settings.require_mfa
    refute Repo.reload!(user).mfa_enabled_at
    refute Repo.exists?(Auth.UserToken.Query.by_context("session"))
    refute Repo.exists?(Auth.MemberGrant)
    refute Repo.exists?(Auth.MemberGrantRoute)
  end

  test "the development seed builds usable demo, partial and empty accounts" do
    # Seeds select synchronous notifications; test.exs already uses that value,
    # so evaluating the real entry point leaves global configuration unchanged.
    assert Application.fetch_env!(:emisar, :notify_approvers_async?) == false

    unrelated = Fixtures.Users.create_user()
    raw = Fixtures.Auth.create_session_token!(unrelated, :magic_link, nil)
    {:ok, _user, retained} = Auth.fetch_user_and_token_by_session_token(raw)

    for _ <- 1..2 do
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)

      assert Repo.all(Auth.UserToken.Query.by_context("session")) |> Enum.map(& &1.id) == [
               retained.id
             ]

      refute Repo.exists?(Auth.MemberGrant)
      refute Repo.exists?(Auth.MemberGrantRoute)

      grants = Repo.all(Approvals.Grant)
      assert length(grants) == 2

      for grant <- grants do
        issuer = Accounts.peek_active_membership(grant.account_id, grant.granted_by_membership_id)
        assert issuer.role == :owner
        assert grant.granted_by_id == nil
      end

      for {email, name} <- [
            {"jordan@emisar.dev", "Jordan Lee"},
            {"priya@emisar.dev", "Priya Shah"},
            {"sam@emisar.dev", "Sam Okafor"},
            {"wren@emisar.dev", "Wren Alvarez"}
          ] do
        {:ok, person} = Users.fetch_user_by_email(email)

        account =
          Accounts.Account.Query.not_deleted()
          |> Accounts.Account.Query.by_slug("demo")
          |> Repo.one!()

        membership = Accounts.peek_sync_membership(account.id, person.id)
        assert Accounts.member_display_name(membership) == name
      end
    end

    for {email, slug} <- [
          {"demo@emisar.dev", "demo"},
          {"demo@emisar.dev", "both-connected"},
          {"owner@acme.test", "acme"},
          {"owner@globex.test", "globex"},
          {"owner@blank.test", "blank"}
        ] do
      assert {:ok, user} = Users.fetch_user_by_email(email)
      raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

      assert {:ok, membership} =
               Accounts.fetch_membership_by_account_id_or_slug(user, slug, session)

      assert membership.account.slug == slug
    end
  end
end
