defmodule EmisarWeb.SignInControllerTest do
  @moduledoc """
  `/sign_in` is "which workspace?": every sign-in targets one workspace, so the
  picker sends the operator to that workspace's own sign-in page
  (`/app/:slug/sign_in`). Returning browsers get their recent workspaces as
  one-click buttons (a signed cookie), and anyone can type an address. The page
  stays open to a signed-in browser: it is how one signs in to another
  workspace.
  """
  use EmisarWeb.ConnCase, async: true

  defp with_recent(conn, account) do
    # secret_key_base is needed to sign the recent-workspaces cookie; a bare test
    # conn doesn't carry it until it's been through the endpoint.
    conn
    |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))
    |> EmisarWeb.RecentAccounts.put(%{slug: account.slug, name: account.name})
    |> recycle()
  end

  defp form(conn),
    do: conn |> html_response(200) |> LazyHTML.from_document() |> LazyHTML.query("form")

  describe "GET /sign_in" do
    test "asks for a workspace address and offers creating one", %{conn: conn} do
      html = conn |> get(~p"/sign_in") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert html =~ "Enter your workspace address"

      assert document
             |> LazyHTML.query("form[action='/sign_in'] input[name='workspace[slug]']")
             |> Enum.count() == 1

      assert document |> LazyHTML.query("a[href='/sign_up']") |> LazyHTML.text() =~
               "Create a workspace"

      refute html =~ "Work email"
    end

    test "a returning browser's recent workspace links to its own sign-in page", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      html = conn |> with_recent(account) |> get(~p"/sign_in") |> html_response(200)

      assert html =~ account.name
      # The slug sub-label disambiguates similar names and teaches the URL form.
      assert html =~ "app/#{account.slug}"
      assert html =~ ~s(href="/app/#{account.slug}/sign_in")
    end

    test "a workspace signed in to is remembered for the picker", %{conn: conn} do
      account = Fixtures.Accounts.create_account(%{name: "Remembered Co"})
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      signed_in = email_link_sign_in(conn, account, member.email)
      assert Map.has_key?(signed_in.resp_cookies, "emisar_recent_accounts")

      html = signed_in |> recycle() |> get(~p"/sign_in") |> html_response(200)
      assert html =~ "Remembered Co"
    end

    test "a tampered recent-workspaces cookie is ignored: an empty picker, no crash", %{
      conn: conn
    } do
      # The cookie is SIGNED, so a forged value fails verification and is dropped.
      html =
        conn
        |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.put_req_cookie("emisar_recent_accounts", "not-a-validly-signed-cookie")
        |> get(~p"/sign_in")
        |> html_response(200)

      assert html =~ "Enter your workspace address"
      refute html =~ "Choose a workspace you&#39;ve used before"
    end

    test "stays open to a signed-in browser, to sign in to another workspace", %{conn: conn} do
      {conn, _owner, _account} = register_and_log_in(conn)

      assert conn |> get(~p"/sign_in") |> html_response(200) =~ "Enter your workspace address"
    end
  end

  describe "POST /sign_in" do
    test "a known address, by slug or id, opens that workspace's sign-in page", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      assert redirected_to(post(conn, ~p"/sign_in", workspace: %{slug: account.slug})) ==
               ~p"/app/#{account}/sign_in"

      assert redirected_to(post(conn, ~p"/sign_in", workspace: %{slug: " #{account.slug} "})) ==
               ~p"/app/#{account}/sign_in"

      assert redirected_to(post(conn, ~p"/sign_in", workspace: %{slug: account.id})) ==
               ~p"/app/#{account}/sign_in"
    end

    test "an unknown address re-renders with an inline error, no redirect", %{conn: conn} do
      conn = post(conn, ~p"/sign_in", workspace: %{slug: "no-such-workspace"})
      form = form(conn)

      assert LazyHTML.text(form) =~ "couldn't find a workspace"

      assert form
             |> LazyHTML.query("input[name='workspace[slug]']")
             |> LazyHTML.attribute("value") ==
               ["no-such-workspace"]

      refute Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "blank and malformed fields re-render the same neutral not-found", %{conn: conn} do
      for params <- [
            %{"workspace" => %{"slug" => "   "}},
            %{"workspace" => %{"slug" => %{"nested" => "value"}}},
            %{"workspace" => "not-a-map"},
            %{}
          ] do
        assert conn |> post(~p"/sign_in", params) |> html_response(200) =~
                 "couldn&#39;t find a workspace"
      end
    end

    test "a disabled workspace still routes to its page, which explains itself", %{conn: conn} do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      assert redirected_to(post(conn, ~p"/sign_in", workspace: %{slug: account.slug})) ==
               ~p"/app/#{account}/sign_in"
    end
  end
end
