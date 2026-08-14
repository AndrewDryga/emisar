defmodule EmisarWeb.AdminSearchLiveTest do
  @moduledoc """
  The staff console's account search at `/admin`. The gate in front of it is
  `EmisarWeb.AdminGateTest`'s; these drive the surface behind it.
  """
  use EmisarWeb.ConnCase, async: true

  setup %{conn: conn} do
    {conn, staff_user} = register_and_log_in_staff(conn)
    %{conn: conn, staff_user: staff_user}
  end

  describe "GET /admin" do
    test "a blank query lists a recently created account", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ "Recent accounts"
      assert html =~ account.name
      assert html =~ account.slug
    end

    test "a query matches by slug and drops the accounts it does not match", %{conn: conn} do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()

      {:ok, live, _html} = live(conn, ~p"/admin")
      html = render_change(form(live, "form"), %{"query" => account.slug})

      assert html =~ "Matching accounts"
      assert html =~ account.name
      refute html =~ other_account.name
    end

    test "a disabled account is listed and says so", %{conn: conn} do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      {:ok, _live, html} = live(conn, ~p"/admin")

      assert html =~ account.name
      assert html =~ "Disabled"
    end

    test "a query that matches nothing renders the empty state", %{conn: conn} do
      Fixtures.Accounts.create_account()

      {:ok, live, _html} = live(conn, ~p"/admin")
      html = render_change(form(live, "form"), %{"query" => "nothing-matches-this"})

      assert html =~ "No accounts match this search."
      refute html =~ "Matching accounts"
    end

    test "the typed query survives the render round-trip", %{conn: conn} do
      # LiveView resets every non-focused input to the server's render, so the
      # search box only keeps what was typed because the handler assigns it back.
      {:ok, live, _html} = live(conn, ~p"/admin")
      html = render_change(form(live, "form"), %{"query" => "acme-corp"})

      assert html =~ ~s(value="acme-corp")
    end

    test "an account row links to its detail page", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      {:ok, live, _html} = live(conn, ~p"/admin")

      assert has_element?(live, ~s(a[href="/admin/accounts/#{account.id}"]), account.name)
    end
  end
end
