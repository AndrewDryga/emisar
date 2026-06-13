defmodule EmisarWeb.UserAuthTest do
  use EmisarWeb.ConnCase, async: true

  alias EmisarWeb.UserAuth

  @remember_me_cookie "_emisar_user_remember_me"

  setup %{conn: conn} do
    # secret_key_base is needed to sign the remember-me cookie; a bare test
    # conn doesn't carry it until it's been through the endpoint.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))

    %{conn: conn}
  end

  describe "log_in_user/3" do
    test "remember_me writes a persistent signed cookie alongside the session token", %{
      conn: conn
    } do
      conn =
        UserAuth.log_in_user(conn, Emisar.Fixtures.user_fixture(), %{"remember_me" => "true"})

      assert Plug.Conn.get_session(conn, :user_token)
      assert %{max_age: max_age, value: value} = conn.resp_cookies[@remember_me_cookie]
      assert is_binary(value)
      assert max_age > 0
    end

    test "without remember_me, only the session token is set — no persistent cookie", %{
      conn: conn
    } do
      conn = UserAuth.log_in_user(conn, Emisar.Fixtures.user_fixture())

      assert Plug.Conn.get_session(conn, :user_token)
      refute conn.resp_cookies[@remember_me_cookie]
    end
  end
end
