defmodule EmisarWeb.MCPDeviceGrantController do
  @moduledoc """
  Device authorization for the MCP installers and direct CLI authentication
  (RFC 8628 shape): `authorize` opens a pending grant for the requested clients;
  `token` is the poll that redeems an approved grant for its per-client API keys.

  Both actions are UNAUTHENTICATED by design (the IL-15 note): the installer
  has no credential yet — acquiring one is the point. The authorization is
  the operator's approval on the authed portal page; these endpoints only
  shepherd the grant, and the context functions they call own every state
  transition. Field names and poll-error semantics follow RFC 8628. The success
  payload is emisar's per-client key map, which is why this is NOT the OAuth AS's
  token endpoint (whose advertised contract stays standard OAuth).

  There is no distinct `slow_down` signal, and at 1.0 there cannot be one: the
  poll contract freezes, and a new retryable code would need a whole new
  contract because deployed installers abort on a code they do not know. The
  CLI and both installers treat any non-terminal response as
  retry-after-interval and ignore `Retry-After`. So the throttle is shaped to
  keep the condition UNREACHABLE for legitimate use — the poll is bucketed per
  device code, not per IP — rather than to report it.
  """
  use EmisarWeb, :controller
  alias Emisar.ApiKeys
  alias EmisarWeb.URLHelpers

  @poll_interval_s 5

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "mcp_device_authorize", limit: 10, window_ms: 60_000, by: :ip]
       when action == :authorize

  # Per DEVICE CODE, not per IP. Each pending authorization is its own poll
  # stream, and an installer polls every 5s (12/min) — so a 60/min IP bucket was
  # exhausted by about five concurrent installs behind one NAT, VPN or CI
  # egress, and every one of them then sat at "Waiting for approval" until the
  # grant expired. A wider IP bucket rides alongside as the anti-abuse backstop:
  # it has to admit many legitimate simultaneous installs, so it bounds a
  # scanner rather than a fleet.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "mcp_device_token", limit: 24, window_ms: 60_000, by: :device_code]
       when action == :token

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "mcp_device_token_ip", limit: 600, window_ms: 60_000, by: :ip]
       when action == :token

  def authorize(conn, params) do
    context = EmisarWeb.RequestContext.from_conn(conn)
    requested_clients = List.wrap(params["requested_clients"])

    case ApiKeys.open_device_grant(requested_clients, context) do
      {:ok, device_code, user_code, _grant} ->
        base = URLHelpers.derive_base_url(conn)

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

  defp respond_token(conn, {:ok, payload}), do: json(conn, payload)

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
