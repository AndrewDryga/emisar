defmodule EmisarWeb.RunnerInstallLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.Runners.EnrollmentKey

  describe "GET /app/runners/install" do
    test "states the key is one-time and points multi-use at Enrollment keys", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      conn = local_conn(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      assert html =~ "one-time"
      assert html =~ "multi-use"
      assert html =~ ~p"/app/#{account}/runners/keys"
    end

    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: local_conn(conn), account: account}
    end

    test "renders the install one-liner and copies it with its leading space", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      [raw_secret] = Regex.run(~r/emkey-enroll-[A-Za-z0-9_-]{43}/, html)

      # The Copy button copies the literal command via data-copy-text — the
      # domain's one-liner verbatim, including the intentional leading space
      # (keeps the enrollment key out of shell history under
      # HISTCONTROL=ignorespace). Regression: copying via the element's
      # innerText used to strip that leading space.
      assert html =~
               ~s(data-copy-text=" curl --proto &#39;=http,https&#39; --proto-redir &#39;=https&#39; --globoff -fsSL http://localhost:4000/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{raw_secret} EMISAR_URL=http://localhost:4000 bash")
    end

    test "public HTTP refuses before minting an install key", %{account: account} do
      owner = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      {:ok, _lv, html} =
        build_conn() |> log_in_user(owner) |> live(~p"/app/#{account}/runners/install")

      assert html =~ "Install command unavailable over HTTP"
      refute html =~ "Waiting for a runner to connect"
      refute html =~ ~r/emkey-enroll-[A-Za-z0-9_-]{43}/
      refute Repo.exists?(EnrollmentKey.Query.all())
    end

    test "puts the live wait status directly after the command, before the script details", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      {waiting_pos, _} = :binary.match(html, "Waiting for a runner to connect")
      {script_pos, _} = :binary.match(html, "What the script does")

      assert waiting_pos < script_pos
      # Pre-grace the page carries NO amber spine — the credential note is
      # neutral and the wait is a brand ping; amber belongs to the overdue
      # "Not seeing it yet?" escalation alone.
      refute html =~ "bg-amber-300/40"
      refute html =~ "border-dashed border-amber"
    end

    # an operator (not just an admin) can open the wizard
    # and gets a live install command: `issue_install_key` is owner/admin/operator,
    # so `mint_install_key` succeeds and the one-liner renders with a real key.
    test "an operator can mint the install key and gets a live command", %{account: account} do
      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, _lv, html} =
        build_conn()
        |> local_conn()
        |> log_in_user(operator)
        |> live(~p"/app/#{account}/runners/install")

      assert html =~ "curl --proto"
      assert html =~ ~s(data-copy-text=" curl --proto)
      refute html =~ "couldn't mint a bootstrap enrollment key"
    end

    test "a viewer is redirected at mount — install is issue-tier", %{conn: conn} do
      {_conn, _owner, account} = register_and_log_in(conn)
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      dest = ~p"/app/#{account}/runners"

      assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
               build_conn()
               |> log_in_user(viewer)
               |> live(~p"/app/#{account}/runners/install")

      assert %{
               "info" =>
                 "Connecting a runner needs an operator role or above, with access to all runners."
             } = flash
    end

    # Minting is what the wizard does at mount, and a key is a fleet-wide grant
    # — the enrolling host names its own group — so the reach matters as much as
    # the role. An admin with only part of the fleet is turned away too.
    test "a runner-restricted admin is redirected at mount", %{conn: conn} do
      {_conn, _owner, account} = register_and_log_in(conn)
      {:ok, production} = Emisar.Accounts.RunnerAccess.restricted(["production"], [])

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.force_runner_access(production)

      dest = ~p"/app/#{account}/runners"

      assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
               build_conn()
               |> log_in_user(Emisar.Repo.preload(membership, :user).user)
               |> live(~p"/app/#{account}/runners/install")

      assert flash["info"] =~ "with access to all runners"
    end

    # the connected mount mints exactly one
    # bootstrap key, and it belongs to the current account (no cross-account id).
    test "the minted install key belongs to the current account only", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners/install")

      assert [%EnrollmentKey{} = key] = Repo.all(EnrollmentKey)
      assert key.account_id == account.id
      # Auto-generated (the install ring), not yet bound to a runner.
      assert key.auto_generated_at != nil
    end

    # the dead/pre-connect (static) render
    # mints no key and shows no command: minting is deferred to the connected
    # mount, so a bare GET can't burn an enrollment secret.
    test "the dead render mints nothing and shows no command", %{conn: conn, account: account} do
      html = conn |> get(~p"/app/#{account}/runners/install") |> html_response(200)

      # Static render falls through to the "generating…" placeholder, not a
      # real command…
      assert html =~ "Generating your install command"
      refute html =~ ~s(data-copy-text=" curl --proto)
      # …and crucially mints no enrollment key.
      assert Repo.all(EnrollmentKey) == []
    end

    # Redirect only for the runner minted from THIS page's key — not any runner
    # that joins the account's presence (a reconnect, another host coming up).
    test "redirects when the runner minted from this page's key connects", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/install")

      # The connected mount auto-minted this page's install key.
      assert [%EnrollmentKey{} = key] = Repo.all(EnrollmentKey)

      # A runner registers with THAT key (its bootstrap key) and joins presence.
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: key.id,
          connected?: false
        )

      send(lv.pid, %{event: "presence_diff", payload: %{joins: %{runner.id => %{metas: [%{}]}}}})

      assert_redirect(lv, ~p"/app/#{account}/runners")
    end

    test "does NOT redirect when a different runner joins the account's presence", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/install")

      # A runner that registered with some OTHER key (here: none) joins — it is
      # not this operator's install, so the wizard must stay put. This is the
      # exact scenario that used to hijack the page: any presence join redirected.
      other = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      send(lv.pid, %{event: "presence_diff", payload: %{joins: %{other.id => %{metas: [%{}]}}}})

      assert render(lv) =~ "curl --proto"
    end

    test "does NOT query or redirect for heartbeat metadata updates", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/install")
      assert [%EnrollmentKey{} = key] = Repo.all(EnrollmentKey)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: key.id,
          connected?: false
        )

      send(lv.pid, %{
        event: "presence_diff",
        payload: %{
          joins: %{runner.id => %{metas: [%{action_load: 1}]}},
          leaves: %{runner.id => %{metas: [%{action_load: 0}]}}
        }
      })

      assert render(lv) =~ "curl --proto"
    end
  end

  defp local_conn(conn), do: %{conn | host: "localhost", port: 4000}
end
