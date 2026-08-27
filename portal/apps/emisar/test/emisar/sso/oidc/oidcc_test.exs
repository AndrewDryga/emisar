defmodule Emisar.SSO.OIDC.OidccTest do
  use ExUnit.Case, async: false
  alias Emisar.SSO.IdentityProvider
  alias Emisar.SSO.OIDC.Oidcc

  describe "verify_callback/3 pre-network validation" do
    test "rejects a mismatched state before contacting the provider" do
      provider = provider()
      params = %{"state" => "attacker-state", "code" => "authorization-code"}

      assert Oidcc.verify_callback(provider, params, stashed()) ==
               {:error, :state_mismatch}
    end

    test "rejects a callback with no state before contacting the provider" do
      provider = provider()
      params = %{"code" => "authorization-code"}

      assert Oidcc.verify_callback(provider, params, stashed()) ==
               {:error, :state_mismatch}
    end

    test "rejects an issuer that does not match the configured provider" do
      provider = provider()

      params = %{
        "state" => "expected-state",
        "iss" => "https://different-idp.example",
        "code" => "authorization-code"
      }

      assert Oidcc.verify_callback(provider, params, stashed()) ==
               {:error, :issuer_mismatch}
    end

    test "rejects a callback with no authorization code" do
      provider = provider()
      params = %{"state" => "expected-state", "iss" => provider.issuer}

      assert Oidcc.verify_callback(provider, params, stashed()) ==
               {:error, :missing_code}
    end
  end

  test "the callback accepts only this client as the ID-token audience" do
    provider = provider()
    opts = Oidcc.callback_token_options(provider, stashed())
    assert opts.trusted_audiences == []
    key = JOSE.JWK.generate_key({:rsa, 2048})

    configuration = %Elixir.Oidcc.ProviderConfiguration{
      issuer: provider.issuer,
      id_token_signing_alg_values_supported: ["RS256"],
      id_token_encryption_alg_values_supported: [],
      id_token_encryption_enc_values_supported: []
    }

    context =
      Elixir.Oidcc.ClientContext.from_manual(
        configuration,
        JOSE.JWK.to_public(key),
        provider.client_id,
        :unauthenticated
      )

    claims = %{
      "iss" => provider.issuer,
      "sub" => "subject",
      "aud" => provider.client_id,
      "exp" => System.system_time(:second) + 60,
      "iat" => System.system_time(:second),
      "nonce" => stashed().nonce
    }

    assert {:ok, %{"sub" => "subject"}} =
             claims
             |> sign_id_token(key)
             |> Elixir.Oidcc.Token.validate_id_token(context, opts)

    client_only_array =
      Map.merge(claims, %{"aud" => [provider.client_id], "azp" => provider.client_id})

    assert {:ok, %{"sub" => "subject"}} =
             client_only_array
             |> sign_id_token(key)
             |> Elixir.Oidcc.Token.validate_id_token(context, opts)

    claims =
      Map.merge(claims, %{
        "aud" => [provider.client_id, "attacker-audience"],
        "azp" => provider.client_id
      })

    assert {:error, {:missing_claim, {"aud", "client-id"}, _claims}} =
             claims
             |> sign_id_token(key)
             |> Elixir.Oidcc.Token.validate_id_token(context, opts)
  end

  test "callback requests use the bounded Guard transport policy" do
    opts = Oidcc.callback_token_options(provider(), stashed())

    assert opts.request_opts.timeout == 15_000

    assert opts.request_opts.http_adapter ==
             {Emisar.SSO.OIDC.BoundedHTTPAdapter, %{profile: Emisar.SSO.OIDC.Guard.profile()}}
  end

  describe "the bounded HTTP adapter" do
    test "does not schedule a Retry-After request after returning" do
      profile = start_httpc_profile(:emisar_oidcc_no_retry_test)
      url = start_http_policy_probe(:retry)

      assert {:error, {:http_error, 503, %{}}} =
               :oidcc_http_util.request(
                 :get,
                 {url, []},
                 %{topic: [:emisar, :oidcc_retry_test]},
                 %{
                   timeout: 50,
                   http_adapter: {Emisar.SSO.OIDC.BoundedHTTPAdapter, %{profile: profile}}
                 }
               )

      assert_receive {:adapter_request, "/"}
      refute_receive {:adapter_request, "/"}, 1_100
    end

    test "does not follow a redirect outside the caller's request lifetime" do
      profile = start_httpc_profile(:emisar_oidcc_no_redirect_test)
      url = start_http_policy_probe(:redirect)

      assert {:error, {:http_error, 302, %{}}} =
               :oidcc_http_util.request(
                 :get,
                 {url, []},
                 %{topic: [:emisar, :oidcc_redirect_test]},
                 %{
                   timeout: 50,
                   http_adapter: {Emisar.SSO.OIDC.BoundedHTTPAdapter, %{profile: profile}}
                 }
               )

      assert_receive {:adapter_request, "/"}
      refute_receive {:adapter_request, "/followed"}, 100
    end
  end

  test "a well-formed callback clears the gates and every fetch goes through the guard" do
    # Two things at once. The state/issuer/code gates let a well-formed callback
    # through — the failure it gets is a transport refusal, not `:state_mismatch` —
    # and that refusal comes from `Emisar.SSO.OIDC.Guard`, which proves the httpc
    # profile is actually wired: an `http://` issuer is a cleartext fetch, and the
    # guard answers 403 to those. If the profile were not in effect, this stub IdP
    # would have been reached instead.
    issuer = start_local_idp()
    provider = provider(%{issuer: issuer})

    params = %{
      "state" => "expected-state",
      "iss" => issuer,
      "code" => "authorization-code"
    }

    assert {:error, {:http_error, 403, _}} = Oidcc.verify_callback(provider, params, stashed())

    # Nothing reached the IdP. The guard refused before a connection was made.
    refute_receive {:oidc_request, _method, _path, _body}, 100
  end

  test "a discovery document pointing elsewhere is refused before anything fetches it" do
    # A real listener stands in for the internal target, so "was it fetched" is
    # observed rather than inferred. It is reachable — only the policy stops us.
    #
    # There are now two independent reasons it is never contacted: the endpoint
    # policy refuses the document between the discovery fetch and the JWKS fetch,
    # and the guard refuses the connection itself. Loopback is exactly what both
    # refuse, which is why this cannot be a happy-path test — see
    # `Emisar.SSO.OIDC.GuardTest` for the boundary's own coverage.
    forbidden_port = start_probe_listener()
    issuer = start_local_idp(jwks_uri: "http://localhost:#{forbidden_port}/jwks")
    provider = provider(%{issuer: issuer})

    params = %{"state" => "expected-state", "iss" => issuer, "code" => "authorization-code"}

    assert {:error, _reason} = Oidcc.verify_callback(provider, params, stashed())

    refute_receive :forbidden_endpoint_contacted, 200
    refute_receive {:oidc_request, "POST", "/token", _body}, 50
  end

  describe "validate_discovered_configuration/1" do
    test "rejects credentials and fragments even on the issuer's own origin" do
      for endpoint <- [
            "https://user:CLIENT_SECRET_SENTINEL@idp.example/token",
            "https://idp.example/token#FRAGMENT_SENTINEL"
          ] do
        config = configuration(%{token_endpoint: endpoint})

        assert Oidcc.validate_discovered_configuration(config) ==
                 {:error, :blocked_discovery_endpoint}
      end
    end

    test "allows fixed query parameters on a public OAuth endpoint" do
      config =
        configuration(%{
          token_endpoint: "https://tokens.other-idp.test/oauth/token?tenant=acme&version=2"
        })

      assert Oidcc.validate_discovered_configuration(config) == :ok
    end

    test "allows only structurally safe endpoints on an exactly declared private IdP" do
      Emisar.Config.put_override(:emisar, :sso_allowed_idp_hosts, ["localhost:8443"])

      allowed =
        configuration(%{
          token_endpoint: "https://localhost:8443/token?tenant=acme"
        })

      assert Oidcc.validate_discovered_configuration(allowed) == :ok

      for endpoint <- [
            "https://localhost:8444/token",
            "http://localhost:8443/token",
            "https://user:secret@localhost:8443/token",
            "https://localhost:8443/token#fragment"
          ] do
        config = configuration(%{token_endpoint: endpoint})

        assert Oidcc.validate_discovered_configuration(config) ==
                 {:error, :blocked_discovery_endpoint}
      end
    end
  end

  defp provider(attrs \\ %{}) do
    defaults = %{
      id: System.unique_integer([:positive]),
      issuer: "https://idp.example",
      client_id: "client-id",
      client_secret: "client-secret"
    }

    struct!(IdentityProvider, Map.merge(defaults, Map.new(attrs)))
  end

  defp configuration(attrs) do
    defaults = %{
      issuer: "https://idp.example",
      authorization_endpoint: "https://idp.example/authorize",
      token_endpoint: "https://idp.example/token",
      userinfo_endpoint: :undefined,
      jwks_uri: "https://idp.example/jwks",
      pushed_authorization_request_endpoint: :undefined
    }

    struct!(Elixir.Oidcc.ProviderConfiguration, Map.merge(defaults, attrs))
  end

  defp stashed do
    %{
      state: "expected-state",
      redirect_uri: "https://app.example/sso/callback",
      nonce: "nonce",
      pkce_verifier: "pkce-verifier"
    }
  end

  defp sign_id_token(claims, key) do
    key
    |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  # Accepts one connection and tells the test. Stands in for the internal host a
  # malicious discovery document points at.
  defp start_probe_listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    test_pid = self()

    spawn_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          send(test_pid, :forbidden_endpoint_contacted)
          :gen_tcp.close(socket)

        {:error, _reason} ->
          :ok
      end
    end)

    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  defp start_local_idp(opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    issuer = "http://127.0.0.1:#{port}"
    test_pid = self()
    jwks_uri = Keyword.get(opts, :jwks_uri, issuer <> "/jwks")

    spawn_link(fn -> serve(listener, test_pid, issuer, jwks_uri) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    issuer
  end

  defp start_httpc_profile(profile) do
    assert {:ok, _pid} = :inets.start(:httpc, profile: profile)
    on_exit(fn -> :inets.stop(:httpc, profile) end)
    profile
  end

  defp start_http_policy_probe(mode) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    test_pid = self()

    spawn_link(fn -> serve_http_policy_probe(listener, test_pid, mode, port) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    ~c"http://127.0.0.1:#{port}/"
  end

  defp serve_http_policy_probe(listener, test_pid, mode, port) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket)
        send(test_pid, {:adapter_request, request.path})
        :ok = :gen_tcp.send(socket, http_policy_response(mode, request.path, port))
        :ok = :gen_tcp.close(socket)
        serve_http_policy_probe(listener, test_pid, mode, port)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp http_policy_response(:retry, _path, _port) do
    [
      "HTTP/1.1 503 Service Unavailable\r\n",
      "retry-after: 1\r\n",
      "content-type: application/json\r\n",
      "content-length: 2\r\n",
      "connection: close\r\n\r\n{}"
    ]
  end

  defp http_policy_response(:redirect, "/", port) do
    [
      "HTTP/1.1 302 Found\r\n",
      "location: http://127.0.0.1:#{port}/followed\r\n",
      "content-type: application/json\r\n",
      "content-length: 2\r\n",
      "connection: close\r\n\r\n{}"
    ]
  end

  defp http_policy_response(:redirect, "/followed", _port), do: http_response(200, "{}")

  defp serve(listener, test_pid, issuer, jwks_uri) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket)
        send(test_pid, {:oidc_request, request.method, request.path, request.body})
        :ok = :gen_tcp.send(socket, response(request.path, issuer, jwks_uri))
        :ok = :gen_tcp.close(socket)
        serve(listener, test_pid, issuer, jwks_uri)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp read_request(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} ->
        body_start = header_end + 4
        headers = binary_part(buffer, 0, header_end)
        body = binary_part(buffer, body_start, byte_size(buffer) - body_start)
        content_length = content_length(headers)

        if byte_size(body) >= content_length do
          parse_request(headers, binary_part(body, 0, content_length))
        else
          receive_request_bytes(socket, buffer)
        end

      :nomatch ->
        receive_request_bytes(socket, buffer)
    end
  end

  defp receive_request_bytes(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> read_request(socket, buffer <> bytes)
      {:error, reason} -> exit({:request_failed, reason})
    end
  end

  defp parse_request(headers, body) do
    [request_line | _header_lines] = String.split(headers, "\r\n")
    [method, target, _version] = String.split(request_line, " ", parts: 3)
    [path | _query] = String.split(target, "?", parts: 2)

    %{method: method, path: path, body: body}
  end

  defp content_length(headers) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers, capture: :all_but_first) do
      [length] -> String.to_integer(length)
      nil -> 0
    end
  end

  defp response("/.well-known/openid-configuration", issuer, jwks_uri) do
    body =
      Jason.encode!(%{
        issuer: issuer,
        authorization_endpoint: issuer <> "/authorize",
        token_endpoint: issuer <> "/token",
        jwks_uri: jwks_uri,
        scopes_supported: ["openid"],
        response_types_supported: ["code"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"]
      })

    http_response(200, body)
  end

  defp response("/jwks", _issuer, _jwks), do: http_response(200, ~s({"keys":[]}))
  defp response("/token", _issuer, _jwks), do: http_response(400, ~s({"error":"invalid_grant"}))
  defp response(_path, _issuer, _jwks), do: http_response(404, ~s({"error":"not_found"}))

  defp http_response(status, body) do
    status_text = if status == 200, do: "OK", else: "Bad Request"

    [
      "HTTP/1.1 #{status} #{status_text}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end
end
