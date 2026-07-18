defmodule EmisarWeb.ActivateLiveTest do
  @moduledoc """
  The device-grant approval page: code lookup, the explicit account
  destination, approve/deny, and the honest states for viewers and dead codes.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{ApiKeys, RequestContext}
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.{Fixtures, Repo}

  defp open_grant(clients \\ ["claude-code"]) do
    {:ok, device_code, user_code, grant} =
      ApiKeys.open_device_grant(clients, %RequestContext{ip_address: "203.0.113.9"})

    {device_code, user_code, grant}
  end

  describe "GET /app/:slug/activate" do
    test "a URL-carried code resolves straight into the approval card", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {_device_code, user_code, _grant} = open_grant(["claude-code", "cursor"])

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      # The consent-card grammar: brand-named clients, requester, phish line.
      assert html =~ "Claude Code &amp; Cursor"
      assert html =~ "requested by the emisar installer from"
      assert html =~ "203.0.113.9"
      assert html =~ "Only approve a request you just started"

      # The consequence names the destination account and the key count.
      assert html =~ account.name
      assert html =~ "2 API keys (one per client)"
      assert html =~ "Approve connection"
    end

    test "an unknown or expired code shows the inline dead-code message", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/activate?code=XXXX-2418")
      assert html =~ "No pending request matches this code"

      {_device_code, user_code, grant} = open_grant()
      Fixtures.ApiKeys.backdate_device_grant_expiry(grant)

      {:ok, _lv, expired_html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")
      assert expired_html =~ "No pending request matches this code"
    end

    test "the code form looks a request up by hand, normalizing the input", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {_device_code, user_code, _grant} = open_grant()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/activate")
      assert html =~ "Enter the approval code"

      typed = user_code |> String.downcase() |> String.replace("-", " ")
      found = render_submit(lv, "lookup", %{"lookup" => %{"code" => typed}})
      assert found =~ "requested by the emisar installer from"
      assert found =~ "Claude Code"
    end

    test "approve flips the grant, and the poll then delivers keys", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {device_code, user_code, _grant} = open_grant(["codex"])

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      approved = render_click(lv, "approve", %{})
      assert approved =~ "Approved — return to your terminal"

      assert {:ok, client_keys} = ApiKeys.claim_device_grant(device_code)
      assert Map.keys(client_keys) == ["codex"]

      [key] = Repo.all(ApiKey)
      assert key.account_id == account.id
      assert key.name == "Codex CLI"
    end

    test "deny kills the request — the poll reports access_denied", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {device_code, user_code, _grant} = open_grant()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      denied = render_click(lv, "deny", %{})
      assert denied =~ "Denied — the installer stops"

      assert ApiKeys.claim_device_grant(device_code) == {:error, :access_denied}
      assert Repo.all(ApiKey) == []
    end

    test "a viewer gets the honest role note and no approval card", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      # Downgrade to viewer AFTER login so the session stays valid.
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "viewer")

      {_device_code, user_code, _grant} = open_grant()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      assert html =~ "needs an operator role or above"
      refute html =~ "Approve connection"
    end

    test "a single-account approver sees the named destination, not a selector", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {_device_code, user_code, _grant} = open_grant()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      refute html =~ "Approve into"
      assert html =~ account.name
    end

    test "a multi-account approver picks the workspace; the pick keeps the code", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      other_account = Fixtures.Accounts.create_account(name: "Second Workspace")

      Fixtures.Memberships.create_membership(
        account_id: other_account.id,
        user_id: user.id,
        role: "owner"
      )

      {_device_code, user_code, _grant} = open_grant()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/activate?code=#{user_code}")

      assert html =~ "Approve into"
      assert html =~ "Second Workspace"

      render_change(lv, "pick_account", %{"account" => other_account.slug})
      assert_redirect(lv, "/app/#{other_account.slug}/activate?code=#{user_code}")
    end
  end

  describe "GET /activate (slugless forward)" do
    test "forwards into the current account's activate page, keeping the code", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/activate?code=FKZQ-2418")
      assert redirected_to(conn) == "/app/#{account.slug}/activate?code=FKZQ-2418"
    end

    test "an anonymous visitor is sent to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/activate?code=FKZQ-2418")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end
end
