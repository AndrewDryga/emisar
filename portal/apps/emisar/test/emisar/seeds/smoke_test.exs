defmodule Emisar.Seeds.SmokeTest do
  use Emisar.DataCase, async: false
  alias Emisar.{Accounts, Approvals, Audit, Auth, Fixtures, Repo, Runners, Runs}

  defp enrollment_key_receipts(key) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(key.account_id)
    |> Audit.Event.Query.by_event_type("enrollment_key.created")
    |> Repo.all()
  end

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

      assert [receipt] = enrollment_key_receipts(key)
      assert receipt.target_id == key.id
      assert receipt.actor_id == creator.id
    end
  end

  test "the random development enrollment key prints this portal's install command" do
    variable = "EMISAR_DEV_FIXED_ENROLLMENT_KEY"
    original = System.get_env(variable)
    System.delete_env(variable)

    on_exit(fn ->
      if original, do: System.put_env(variable, original)
    end)

    public_url = [scheme: "http", host: "127.0.0.1", port: 4010]
    Emisar.Config.put_override(:emisar, :public_url, public_url)

    seed = fn ->
      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_file(Application.app_dir(:emisar, "priv/repo/seeds.exs"))
      end)
    end

    output = seed.()

    demo =
      Accounts.Account.Query.not_deleted()
      |> Accounts.Account.Query.by_slug("demo")
      |> Repo.one!()

    assert [key] = Enum.filter(Repo.all(Runners.EnrollmentKey), &(&1.account_id == demo.id))
    assert output =~ "curl -fsSL http://127.0.0.1:4010/install.sh | sudo EMISAR_ENROLLMENT_KEY="
    assert output =~ " EMISAR_URL=http://127.0.0.1:4010 bash"
    refute output =~ "https://emisar.dev"

    # A reseed keeps the existing key: no new key, receipt, or command.
    refute seed.() =~ "EMISAR_ENROLLMENT_KEY="
    assert [receipt] = enrollment_key_receipts(key)
    assert receipt.target_id == key.id
    assert receipt.actor_id == key.created_by_membership_id
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

      # The plan accounts' finished runs carry the receipts a live run leaves.
      for slug <- ["acme", "globex"] do
        {:ok, account} = Accounts.fetch_account_by_id_or_slug(slug)

        runs =
          Runs.ActionRun.Query.all()
          |> Runs.ActionRun.Query.by_account_id(account.id)
          |> Repo.all()

        assert length(runs) == 2

        for run <- runs do
          assert run.status == :success

          assert [receipt] =
                   Audit.Event.Query.all()
                   |> Audit.Event.Query.by_event_type("action_run.success")
                   |> Repo.all()
                   |> Enum.filter(&(&1.request_id == run.request_id))

          assert receipt.occurred_at == run.finished_at

          output = Runs.RunEvent.Query.all() |> Runs.RunEvent.Query.by_run_id(run.id)
          assert Repo.exists?(output)
        end
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

    {:ok, demo} = Accounts.fetch_account_by_id_or_slug("demo")

    for {email, ip_address} <- [
          {"jordan@emisar.dev", "203.0.113.42"},
          {"priya@emisar.dev", "198.51.100.17"}
        ] do
      member = Accounts.peek_sync_membership_by_email(demo.id, email)

      assert [sign_in] =
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_event_type("user.signed_in")
               |> Audit.Event.Query.by_actor_id(member.id)
               |> Repo.all()

      assert sign_in.target_id == member.id
      assert sign_in.ip_address == ip_address
      assert sign_in.payload["method"] == "magic_link"
      # Backdated before the approval story rather than stamped at seed time.
      assert DateTime.diff(DateTime.utc_now(), sign_in.occurred_at, :minute) >= 30
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
