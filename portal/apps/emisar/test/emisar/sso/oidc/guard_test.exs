defmodule Emisar.SSO.OIDC.GuardTest do
  @moduledoc """
  The guard is the connect-time SSRF boundary every OIDC fetch goes through, so
  these drive it the way `httpc` does: speak proxy at it over TCP and see what it
  lets through.

  This is where the redirect hole is covered. `httpc` follows redirects and
  `oidcc` gives us no way to disable that, so a redirected request arrives here as
  a fresh CONNECT (or, if the redirect downgraded the scheme, as a cleartext
  request). Refusing both is what closes it — there is no third way for a hop to
  reach the network.
  """
  use ExUnit.Case, async: true
  alias Emisar.SSO.IssuerUrl
  alias Emisar.SSO.OIDC.Guard

  setup do
    port = Guard.port()
    %{port: port}
  end

  test "refuses CONNECT to loopback", %{port: port} do
    assert speak(port, "CONNECT 127.0.0.1:9200 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses CONNECT to the cloud metadata service", %{port: port} do
    assert speak(port, "CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses CONNECT to an RFC-1918 address", %{port: port} do
    assert speak(port, "CONNECT 10.1.2.3:443 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses CONNECT to a loopback address written the long way round", %{port: port} do
    # 0x7f000001, 2130706433 and 127.1 are all 127.0.0.1. `:inet.parse_address`
    # normalizes them, so the policy sees one address rather than four spellings.
    for spelling <- ["0x7f000001", "2130706433", "127.1", "0177.0.0.1"] do
      assert speak(port, "CONNECT #{spelling}:80 HTTP/1.1\r\n\r\n") =~ "403",
             "#{spelling} reached the network"
    end
  end

  test "refuses CONNECT to bracketed IPv6 loopback", %{port: port} do
    assert speak(port, "CONNECT [::1]:443 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses CONNECT to an IPv4-mapped loopback address", %{port: port} do
    assert speak(port, "CONNECT [::ffff:127.0.0.1]:443 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses a cleartext request, which is how a downgrade arrives", %{port: port} do
    # A redirect that swaps https for http reaches a proxy as an absolute-URI
    # request rather than a CONNECT. There is nothing legitimate for an OIDC fetch
    # to do over cleartext.
    response =
      speak(port, "GET http://169.254.169.254/latest/meta-data/ HTTP/1.1\r\nHost: x\r\n\r\n")

    assert response =~ "403"
  end

  test "refuses a hostname that resolves to loopback", %{port: port} do
    # The URL policy deliberately does not resolve names. This is the half that
    # does — and it dials the address it checked, so the name cannot be rebound to
    # something internal between the check and the connection.
    assert speak(port, "CONNECT localhost:9200 HTTP/1.1\r\n\r\n") =~ "403"
  end

  test "refuses a malformed authority", %{port: port} do
    assert speak(port, "CONNECT not-an-authority HTTP/1.1\r\n\r\n") =~ "50"
  end

  test "a declared host is exempt from the address policy; nothing else is" do
    # The guard answers CONNECTs in a process with no relationship to this test, so
    # a per-test config override cannot reach it — the decision is asserted here and
    # the declared path end to end by `./run e2e sso`, whose stack declares its
    # local Keycloak.
    Emisar.Config.put_override(:emisar, :sso_allowed_idp_hosts, [
      "idp.internal:8443",
      "KEYCLOAK:8443"
    ])

    assert Guard.declared?("idp.internal", 8443)
    assert Guard.declared?("IDP.INTERNAL", 8443), "the comparison must not be case-sensitive"
    assert Guard.declared?("keycloak", 8443)

    # The PORT is part of the declaration. Without it, a discovery document naming a
    # declared host reached any TLS-speaking port on that machine.
    refute Guard.declared?("idp.internal", 9200)
    refute Guard.declared?("idp.internal", 443)

    refute Guard.declared?("localhost", 8443)
    refute Guard.declared?("idp.internal.evil.test", 8443), "a declaration is exact, not a prefix"
    refute Guard.declared?("169.254.169.254", 80)
  end

  test "nothing is declared by default" do
    refute Guard.declared?("localhost", 8443)
    refute Guard.declared?("keycloak", 8443)
  end

  test "lets a public address through the policy" do
    # The tunnel itself cannot be exercised here: every address a test can bind is
    # loopback or RFC-1918, which is precisely what the guard refuses. So the
    # decision is asserted directly, and the tunnel is covered by `./run e2e sso`,
    # where a real Keycloak sits on a non-loopback address in the Docker network.
    assert IssuerUrl.address_allowed?({93, 184, 216, 34})
    refute IssuerUrl.address_allowed?({127, 0, 0, 1})
    refute IssuerUrl.address_allowed?({169, 254, 169, 254})
  end

  # Generous timeouts on purpose. Two seconds was enough in isolation and flaked
  # under the full suite, where connect + accept + resolve + reply competes with a
  # few hundred other tests.
  @wait 15_000

  defp speak(port, request) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], @wait)

    :ok = :gen_tcp.send(socket, request)
    response = recv(socket)
    :gen_tcp.close(socket)
    response
  end

  defp recv(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, @wait) do
      {:ok, data} when byte_size(acc) + byte_size(data) < 4_096 -> recv(socket, acc <> data)
      {:ok, data} -> acc <> data
      {:error, _} -> acc
    end
  end
end
