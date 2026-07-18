defmodule EmisarWeb.MCPDeviceGrantController do
  @moduledoc """
  Device authorization for the MCP installer (RFC 8628 shape): `authorize`
  opens a pending grant for the requested clients; `token` is the poll that
  redeems an approved grant for its per-client API keys.

  Both actions are UNAUTHENTICATED by design (the IL-15 note): the installer
  has no credential yet — acquiring one is the point. The authorization is
  the operator's approval on the authed portal page; these endpoints only
  shepherd the grant, and the context functions they call own every state
  transition. Field names and poll-error semantics follow RFC 8628 so a
  future bridge-side flow can reuse them unchanged; the success payload is
  emisar's per-client key map, which is why this is NOT the OAuth AS's token
  endpoint (whose advertised contract stays standard OAuth). Abusive polling
  is cut by the IP rate limits — there is no distinct `slow_down` signal; the
  installer treats any non-terminal response as retry-after-interval.
  """
  use EmisarWeb, :controller
  alias Emisar.ApiKeys
  alias EmisarWeb.UrlHelpers

  @poll_interval_s 5

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "mcp_device_authorize", limit: 10, window_ms: 60_000, by: :ip]
       when action == :authorize

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "mcp_device_token", limit: 60, window_ms: 60_000, by: :ip]
       when action == :token

  def authorize(conn, params) do
    context = EmisarWeb.RequestContext.from_conn(conn)
    requested_clients = List.wrap(params["requested_clients"])

    case ApiKeys.open_device_grant(requested_clients, context) do
      {:ok, device_code, user_code, _grant} ->
        base = UrlHelpers.derive_base_url(conn)

        json(conn, %{
          device_code: device_code,
          user_code: user_code,
          verification_uri: base <> "/activate",
          verification_uri_complete: base <> "/activate?code=" <> user_code,
          expires_in: ApiKeys.device_grant_ttl_s(),
          interval: @poll_interval_s
        })

      {:error, %Ecto.Changeset{}} ->
        error_json(
          conn,
          "invalid_request",
          "requested_clients must be a non-empty list of known client ids"
        )
    end
  end

  def token(conn, params) do
    case params["device_code"] do
      device_code when is_binary(device_code) and device_code != "" ->
        respond_token(conn, ApiKeys.claim_device_grant(device_code))

      _missing ->
        error_json(conn, "invalid_request", "device_code is required")
    end
  end

  defp respond_token(conn, {:ok, client_keys}), do: json(conn, %{client_keys: client_keys})

  defp respond_token(conn, {:error, reason})
       when reason in [:authorization_pending, :access_denied, :expired_token, :invalid_grant],
       do: error_json(conn, Atom.to_string(reason), nil)

  # An unexpected claim failure (a mint rejected mid-transaction) burns the
  # poll generically — never a changeset dump to an unauthenticated caller.
  defp respond_token(conn, {:error, _other}), do: error_json(conn, "invalid_grant", nil)

  # RFC 8628 rides OAuth's error envelope: HTTP 400 + {"error": "..."}.
  defp error_json(conn, error, description) do
    body =
      if description,
        do: %{error: error, error_description: description},
        else: %{error: error}

    conn |> put_status(400) |> json(body)
  end
end
