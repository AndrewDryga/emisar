defmodule EmisarWeb.RunnerInstallLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.Runners.AuthKey

  describe "GET /app/runners/install" do
    test "states the key is one-time and points multi-use at Runner keys", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      assert html =~ "one-time"
      assert html =~ "multi-use"
      assert html =~ ~p"/app/#{account}/runners/keys"
    end

    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      %{conn: conn, account: account}
    end

    test "renders the install one-liner and copies it with its leading space", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runners/install")

      assert html =~ "curl -sSL"

      # The Copy button copies the literal command via data-copy-text,
      # including the intentional leading space (keeps the auth key out of
      # shell history under HISTCONTROL=ignorespace). Regression: copying
      # via the element's innerText used to strip that leading space.
      assert html =~ ~s(data-copy-text=" curl -sSL)
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
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/runners/install")

      assert html =~ "curl -sSL"
      assert html =~ ~s(data-copy-text=" curl -sSL)
      refute html =~ "couldn't mint a bootstrap auth key"
    end

    # a viewer lacks `issue_install_key`, so
    # `mint_install_key` returns {:error, :unauthorized} and the LV renders the
    # `:mint_failed` failure path (pointing at the auth-keys page) instead of a
    # command. The page is reachable (it has no view gate) — the mint is the gate.
    test "a viewer gets the :mint_failed failure path, not a command", %{account: account} do
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, _lv, html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runners/install")

      assert html =~ "couldn&#39;t mint a runner key"
      assert html =~ "Runners &rarr; Runner keys" or html =~ "Runners → Runner keys"
      # No live command was rendered for the viewer.
      refute html =~ ~s(data-copy-text=" curl -sSL)
      # …and no key was minted on their behalf.
      assert Repo.all(AuthKey) == []
    end

    # the connected mount mints exactly one
    # bootstrap key, and it belongs to the current account (no cross-account id).
    test "the minted install key belongs to the current account only", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners/install")

      assert [%AuthKey{} = key] = Repo.all(AuthKey)
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
      refute html =~ ~s(data-copy-text=" curl -sSL)
      # …and crucially mints no auth key.
      assert Repo.all(AuthKey) == []
    end

    # Redirect only for the runner minted from THIS page's key — not any runner
    # that joins the account's presence (a reconnect, another host coming up).
    test "redirects when the runner minted from this page's key connects", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runners/install")

      # The connected mount auto-minted this page's install key.
      assert [%AuthKey{} = key] = Repo.all(AuthKey)

      # A runner registers with THAT key (its bootstrap key) and joins presence.
      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_auth_key_id: key.id,
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

      assert render(lv) =~ "curl -sSL"
    end
  end
end
