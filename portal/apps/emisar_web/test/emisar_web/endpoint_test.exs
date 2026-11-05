defmodule EmisarWeb.EndpointTest do
  use EmisarWeb.ConnCase, async: true

  test "the endpoint and Emisar.PublicUrl advertise the same public origin" do
    assert EmisarWeb.Endpoint.url() == Emisar.PublicUrl.base()
  end

  test "a multipart POST to a capped path is passed through unparsed" do
    body = "--b\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n1\r\n--b--\r\n"

    conn =
      build_conn(:post, "/scim/v2/Users", body)
      |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=b")
      |> EmisarWeb.Endpoint.call([])

    # Plug.Parsers leaves the body untouched when no parser claims it.
    assert %Plug.Conn.Unfetched{} = conn.body_params
    refute is_map_key(conn.params, "a")
  end

  test "an oversized body on an unrouted path is refused before routing" do
    body = Jason.encode!(%{"x" => String.duplicate("a", 2 * 1024 * 1024 + 1)})

    assert_error_sent 413, fn ->
      build_conn(:post, "/no/such/path", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> EmisarWeb.Endpoint.call([])
    end
  end

  test "the session cookie follows the runtime secure-cookie setting" do
    Emisar.Config.put_override(:emisar_web, :force_secure_cookies, true)
    secure_conn = request_with_session()

    Emisar.Config.put_override(:emisar_web, :force_secure_cookies, false)
    insecure_conn = request_with_session()

    assert_session_cookie(secure_conn, true)
    assert_session_cookie(insecure_conn, false)
  end

  test "a real Bandit listener built from the endpoint config accepts a legal 12 KB header" do
    http = Keyword.put(EmisarWeb.Endpoint.config(:http), :port, 0)

    [spec] =
      Bandit.PhoenixAdapter.child_specs(EmisarWeb.Endpoint, otp_app: :emisar_web, http: http)

    pid = start_supervised!(spec)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "GET /healthz HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
        "emisar-attestation: ",
        String.duplicate("a", 12_000),
        "\r\n\r\n"
      ])

    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    assert "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> = response
    refute status == "431"
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
