defmodule EmisarWeb.SSOPendingLiveTest do
  @moduledoc """
  The pending-approval page a `:manual`-provisioner SSO first login lands on. The
  request id rides a session cookie; the page live-updates when an admin approves
  (re-runs SSO) or dismisses it.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.SSO.{IdentityProvider, LinkRequest}

  defp pending(conn, opts \\ []) do
    account = Fixtures.Accounts.create_account(name: Keyword.get(opts, :org, "Acme Corp"))

    {:ok, provider} =
      Repo.insert(
        IdentityProvider.Changeset.create(account.id, %{
          kind: :okta,
          name: "Okta",
          issuer: "https://acme.okta.com",
          client_id: "cid",
          client_secret: "secret",
          provisioner: :manual
        })
      )

    {:ok, request} =
      Repo.insert(
        LinkRequest.Changeset.create(account.id, provider.id, %{
          provider_identifier: "okta|pending",
          email: "newbie@acme.test",
          full_name: "New Bie",
          claims: %{}
        })
      )

    conn = Plug.Test.init_test_session(conn, %{"sso_pending_request" => request.id})
    %{conn: conn, account: account, provider: provider, request: request}
  end

  test "shows the waiting state with the person's email and org", %{conn: conn} do
    %{conn: conn, request: request, account: account} = pending(conn)

    {:ok, _lv, html} = live(conn, ~p"/sign_in/sso/pending")

    assert html =~ "Access pending"
    assert html =~ request.email
    assert html =~ account.name
  end

  test "re-runs SSO automatically when an admin approves", %{conn: conn} do
    %{conn: conn, request: request, provider: provider} = pending(conn)
    {:ok, lv, _html} = live(conn, ~p"/sign_in/sso/pending")

    send(lv.pid, {:sso_link_request, :approved, %{id: request.id, provider_id: provider.id}})

    assert_redirect(lv, ~p"/sign_in/sso/#{provider.id}")
  end

  test "shows a declined message when an admin dismisses the request", %{conn: conn} do
    %{conn: conn, request: request} = pending(conn)
    {:ok, lv, _html} = live(conn, ~p"/sign_in/sso/pending")

    send(lv.pid, {:sso_link_request, :dismissed, %{id: request.id}})

    assert render(lv) =~ "declined"
  end

  test "with no pending request in the session it redirects to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/sso/pending")
  end
end
