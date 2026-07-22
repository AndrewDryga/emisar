defmodule EmisarWeb.EndpointTest do
  use EmisarWeb.ConnCase, async: true

  test "the session cookie follows the runtime secure-cookie setting" do
    Emisar.Config.put_override(:emisar_web, :force_secure_cookies, true)
    secure_conn = request_with_session()

    Emisar.Config.put_override(:emisar_web, :force_secure_cookies, false)
    insecure_conn = request_with_session()

    assert_session_cookie(secure_conn, true)
    assert_session_cookie(insecure_conn, false)
  end

  defp request_with_session do
    build_conn()
    |> init_test_session(%{})
    |> put_session(:cookie_probe, "value")
    |> get(~p"/")
  end

  defp assert_session_cookie(conn, secure?) do
    assert %{secure: ^secure?} = conn.resp_cookies["_emisar_web_key"]

    set_cookie =
      conn
      |> get_resp_header("set-cookie")
      |> Enum.find(&String.starts_with?(&1, "_emisar_web_key="))

    assert is_binary(set_cookie)

    if secure? do
      assert set_cookie =~ "; secure"
    else
      refute set_cookie =~ "; secure"
    end
  end
end
