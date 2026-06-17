defmodule EmisarWeb.AccountSlugAuthzTest do
  @moduledoc """
  The account slug in `/app/:account_id_or_slug/...` is a cross-account authz
  input. Every authenticated mount resolves + authorizes it from the URL (the
  conn plug for the dead render, the `:ensure_account_slug` on_mount for the live
  view): a non-member or unknown slug 404s — indistinguishable, so a URL never
  confirms a tenant exists (404, never 403, no leak). Bare `/app` forwards to the
  user's account; a member's deep link opens.
  """
  use EmisarWeb.ConnCase, async: true

  describe "slug-scoped tenant routes" do
    test "a member reaches their own account's slugged pages", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      # The slug also resolves by the account id (the API/SSO/redirect form).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account.id}/runners")
    end

    test "a non-member's slug 404s — same as an unknown slug, so neither leaks", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)

      # A real, populated account the logged-in user has no membership in.
      other = Emisar.Fixtures.account_fixture()

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{other}/runners") end
      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-team/runners") end
      # A deep link is no different — the gate runs on every mount, not just the index.
      assert_error_sent 404, fn -> get(conn, ~p"/app/#{other}/audit/#{Ecto.UUID.generate()}") end
    end

    test "a member of account A cannot reach account B's slug (cross-account)", %{conn: conn} do
      {conn, _user, _account_a} = register_and_log_in(conn)

      # B belongs to someone else; A's member is not in it.
      {_conn_b, _user_b, account_b} = register_and_log_in(build_conn())

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{account_b}/runs") end
    end

    test "bare /app forwards to the user's account slug", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      assert redirected_to(get(conn, ~p"/app")) == ~p"/app/#{account}"
    end
  end
end
