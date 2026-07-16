defmodule Emisar.SSO.OIDC.OidccTest do
  use ExUnit.Case, async: true
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

  test "clears the pre-network gate and reaches the token exchange for a well-formed callback" do
    issuer = start_local_idp()
    provider = provider(%{issuer: issuer})

    on_exit(fn -> terminate_provider_worker(provider) end)

    params = %{
      "state" => "expected-state",
      "iss" => issuer,
      "code" => "authorization-code"
    }

    # A well-formed callback must clear the state/issuer/code gate and reach the
    # token exchange. The stub IdP's token response is not a real signed grant,
    # so the exchange itself fails (error or a downstream raise); we only prove
    # the pre-network gate let it through — evidenced by the outbound discovery
    # and token requests below.
    try do
      Oidcc.verify_callback(provider, params, stashed())
    rescue
      _ -> :reached_exchange
    end

    assert_receive {:oidc_request, "GET", "/.well-known/openid-configuration", _body}
    assert_receive {:oidc_request, "POST", "/token", body}
    assert body =~ "code=authorization-code"
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

  defp stashed do
    %{
      state: "expected-state",
      redirect_uri: "https://app.example/sso/callback",
      nonce: "nonce",
      pkce_verifier: "pkce-verifier"
    }
  end

  defp start_local_idp do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    issuer = "http://127.0.0.1:#{port}"
    test_pid = self()

    spawn_link(fn -> serve(listener, test_pid, issuer) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    issuer
  end

  defp serve(listener, test_pid, issuer) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket)
        send(test_pid, {:oidc_request, request.method, request.path, request.body})
        :ok = :gen_tcp.send(socket, response(request.path, issuer))
        :ok = :gen_tcp.close(socket)
        serve(listener, test_pid, issuer)

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

  defp response("/.well-known/openid-configuration", issuer) do
    body =
      Jason.encode!(%{
        issuer: issuer,
        authorization_endpoint: issuer <> "/authorize",
        token_endpoint: issuer <> "/token",
        jwks_uri: issuer <> "/jwks",
        scopes_supported: ["openid"],
        response_types_supported: ["code"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"]
      })

    http_response(200, body)
  end

  defp response("/jwks", _issuer), do: http_response(200, ~s({"keys":[]}))
  defp response("/token", _issuer), do: http_response(400, ~s({"error":"invalid_grant"}))
  defp response(_path, _issuer), do: http_response(404, ~s({"error":"not_found"}))

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

  defp terminate_provider_worker(provider) do
    provider_key = {provider.id, provider.issuer}

    Emisar.SSO.OIDC.Registry
    |> Registry.lookup(provider_key)
    |> Enum.each(fn {pid, _value} ->
      DynamicSupervisor.terminate_child(Emisar.SSO.OIDC.ProviderSupervisor, pid)
    end)
  end
end
