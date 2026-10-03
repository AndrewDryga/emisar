defmodule Emisar.Seeds.SmokeTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Accounts, Approvals, Auth, Fixtures, Repo, Runners, Runs}

  test "the fixed development enrollment secret belongs to the exact seed owner" do
    variable = "EMISAR_DEV_FIXED_ENROLLMENT_KEY"
    original = System.get_env(variable)
    raw = "emkey-enroll-test-fixed-bootstrap-DO-NOT-USE-IN-PROD"
    System.put_env(variable, raw)

    on_exit(fn ->
      if original, do: System.put_env(variable, original), else: System.delete_env(variable)
    end)

    for _ <- 1..2 do
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)

      key = Runners.peek_enrollment_key_by_secret(raw)
      assert key.reusable
      creator = Accounts.peek_active_membership(key.account_id, key.created_by_membership_id)
      assert creator.role == :owner
      assert creator.email == "demo@emisar.dev"
      policy = Emisar.Policies.peek_policy_for_account(key.account_id)
      assert policy.updated_by_membership_id == creator.id
    end
  end

  test "reseed restores screenshot-account sign-in policy without changing unrelated accounts" do
    seed = fn ->
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)
    end

    seed.()

    demo =
      Accounts.Account.Query.not_deleted()
      |> Accounts.Account.Query.by_slug("demo")
      |> Repo.one!()

    user = Accounts.peek_sync_membership_by_email(demo.id, "demo@emisar.dev")

    Fixtures.Memberships.set_mfa_state(user,
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

    unrelated = Fixtures.Accounts.create_account()
    Fixtures.Accounts.set_account_settings(unrelated, %{require_mfa: true})

    seed.()

    for account <- screenshot_accounts do
      settings = Repo.reload!(account).settings
      refute settings.require_mfa
      refute settings.require_sso
      assert settings.monthly_report_opt_out
    end

    assert Repo.reload!(unrelated).settings.require_mfa
    refute Repo.reload!(user).mfa_enabled_at
    refute Repo.exists?(Auth.UserToken.Query.by_context("session"))
  end

  test "the development seed builds usable demo, partial and empty accounts" do
    # Seeds select synchronous notifications; test.exs already uses that value,
    # so evaluating the real entry point leaves global configuration unchanged.
    assert Application.fetch_env!(:emisar, :notify_approvers_async?) == false

    unrelated = Fixtures.Memberships.create_membership()
    raw = Fixtures.Auth.create_session_token!(unrelated, :magic_link, nil)
    {:ok, retained} = Auth.fetch_session_by_token(raw, unrelated.account_id)

    for _ <- 1..2 do
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)

      assert Repo.all(Auth.UserToken.Query.by_context("session")) |> Enum.map(& &1.id) == [
               retained.id
             ]

      grants = Repo.all(Approvals.Grant)
      assert length(grants) == 2

      for grant <- grants do
        issuer = Accounts.peek_active_membership(grant.account_id, grant.granted_by_membership_id)
        assert issuer.role == :owner
      end

      keys = Repo.all(Runners.EnrollmentKey)
      assert keys != []

      for key <- keys do
        creator = Accounts.peek_active_membership(key.account_id, key.created_by_membership_id)
        assert creator.role == :owner
      end

      # Every seeded run was started by a person or that person's agent key, so
      # each names the seat that started it; the runs pages, approvals and docs
      # captures all read the requester from there.
      for run <- Repo.all(Runs.ActionRun) do
        assert run.initiating_membership_id,
               "seeded #{run.action_id} (#{run.source}) names no initiating Member"
      end

      for {email, name} <- [
            {"jordan@emisar.dev", "Jordan Lee"},
            {"priya@emisar.dev", "Priya Shah"},
            {"sam@emisar.dev", "Sam Okafor"},
            {"wren@emisar.dev", "Wren Alvarez"}
          ] do
        account =
          Accounts.Account.Query.not_deleted()
          |> Accounts.Account.Query.by_slug("demo")
          |> Repo.one!()

        membership = Accounts.peek_sync_membership_by_email(account.id, email)
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
      {:ok, account} = Accounts.fetch_account_by_id_or_slug(slug)
      member = Accounts.peek_sync_membership_by_email(account.id, email)
      assert member.email_verified_at
      raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      assert {:ok, session} = Auth.fetch_session_by_token(raw, account.id)
      assert session.membership.account.slug == slug
    end
  end
end
