defmodule EmisarWeb.RunnerConnectController do
  @moduledoc """
  Entry points for the runner transport:

    * `POST /runner/register` — exchanges a bootstrap enrollment key (the one
      baked into the image) for a per-runner token. Called once at first
      boot. Idempotent on `external_id`.

    * `GET  /runner/socket/websocket` — upgrades to the WebSock transport
      after authenticating via `Authorization: Bearer <runner_token>`.
  """

  use EmisarWeb, :controller
  alias Emisar.Runners
  alias EmisarWeb.{RequestContext, RunnerSocket}

  @runner_frame_max_bytes 2 * 1_024 * 1_024

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "runner_register", limit: 30, window_ms: 60_000, by: :ip]
       when action == :register

  # -- Token exchange -------------------------------------------------

  @doc """
  Exchange a live runner token for its successor. The presented token IS the
  authorization, as it is for the socket upgrade — no enrollment key, no host
  access, which is the whole point: a token can be rotated without anyone
  touching the machine.

  `409 not_due` when the token is too young to rotate. A runner that asks early
  gets an answer rather than an error it has to interpret, and it keeps using
  the token it has.
  """
  def refresh_token(conn, _params) do
    with {:ok, token} <- read_bearer(conn),
         {:ok, raw_token, refresh_after} <- Runners.refresh_runner_token(token) do
      json(conn, %{token: raw_token, refresh_after: iso8601(refresh_after)})
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :not_due} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "not_due"})

      {:error, :runner_disabled} ->
        unauthorized(conn, "runner_disabled")

      {:error, :account_disabled} ->
        unauthorized(conn, "account_disabled")

      # An expired token cannot buy a live successor — otherwise expiry would
      # be a formality any leaked credential could refresh its way out of.
      {:error, :token_expired} ->
        unauthorized(conn, "token_expired")

      {:error, _reason} ->
        unauthorized(conn, "token_invalid")
    end
  end

  # nil for a token that never rotates, so an older runner sees no field and a
  # newer one reads "never due" — the same answer, spelled once.
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  def register(conn, params) do
    with {:ok, enrollment_key} <- read_bearer(conn),
         {:ok, attrs} <- registration_attrs(params),
         {:ok, _runner, token, raw_token} <-
           Runners.register_via_enrollment_key(
             enrollment_key,
             attrs,
             RequestContext.from_conn(conn)
           ) do
      conn
      |> put_status(:created)
      |> json(%{token: raw_token, refresh_after: iso8601(Runners.token_refresh_after(token))})
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :enrollment_key_invalid} ->
        unauthorized(conn, "enrollment_key_invalid")

      {:error, :invalid_registration} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "register_failed"})

      {:error, :invalid_external_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_external_id"})

      {:error, :over_limit, plan, limit} ->
        conn
        |> put_status(:payment_required)
        |> json(%{error: "runner_limit_exceeded", plan: plan, limit: limit})

      {:error, :runner_name_taken, name} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "runner_name_taken",
          name: name,
          message:
            "The name #{inspect(name)} is already used by another runner in this account. " <>
              "A runner's name defaults to its hostname and cannot be changed after it " <>
              "registers. Delete that runner in the Emisar console (Runners) to free the " <>
              "name, or set runner.id in this host's config to register under a declared " <>
              "name, then it will connect."
        })

      {:error, _reason} ->
        # Don't echo the internal reason term to an unauthenticated
        # caller — the specific failure modes above are already named.
        conn
        |> put_status(:bad_request)
        |> json(%{error: "register_failed"})
    end
  end

  # -- WebSocket upgrade ----------------------------------------------

  def websocket(conn, _params) do
    with {:ok, raw} <- read_bearer(conn),
         {:ok, token, runner} <- Runners.verify_runner_token(raw) do
      # Threaded into the socket process so its lifecycle audit events
      # (connect in init, disconnect in terminate) carry the connecting
      # host's IP + UA — `init/1` builds the `%RequestContext{}` from
      # these. The conn's process won't outlive the upgrade.
      state = %{
        token: token,
        runner: runner,
        ip_address: conn |> ip_string() |> RunnerSocket.normalize_ip(),
        user_agent: get_req_header(conn, "user-agent") |> List.first()
      }

      conn
      |> WebSockAdapter.upgrade(RunnerSocket, state,
        timeout: 60_000,
        max_frame_size: @runner_frame_max_bytes
      )
      |> halt()
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :token_invalid} ->
        unauthorized(conn, "token_invalid")

      # 401 rather than 403 on purpose: the runner drops its cached token on a
      # 401 and re-registers with its enrollment key, which is exactly the
      # recovery an expired credential needs and no operator action at all.
      {:error, :token_expired} ->
        unauthorized(conn, "token_expired")

      {:error, :runner_disabled} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "runner_disabled"})

      {:error, :account_disabled} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "account_disabled"})
    end
  end

  # -- Helpers --------------------------------------------------------

  # Stringify `conn.remote_ip` for audit metadata. Falls back to
  # "unknown" if the tuple isn't an IP (test sockets, unusual
  # transports); `RunnerSocket.normalize_ip/1` strips that sentinel.
  defp ip_string(%Plug.Conn{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  defp ip_string(_), do: "unknown"

  defp read_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      ["bearer " <> token] -> {:ok, token}
      _ -> :missing_bearer
    end
  end

  defp registration_attrs(%{} = params) do
    labels = if is_nil(params["labels"]), do: %{}, else: params["labels"]

    attrs = %{
      external_id: params["external_id"],
      hostname: params["hostname"],
      group: params["group"],
      labels: labels,
      version: params["version"]
    }

    case attrs.external_id do
      external_id when is_binary(external_id) ->
        if Enum.all?([attrs.hostname, attrs.group, attrs.version], &optional_string?/1) and
             is_map(labels) do
          {:ok, attrs}
        else
          {:error, :invalid_registration}
        end

      _ ->
        {:error, :invalid_external_id}
    end
  end

  defp registration_attrs(_), do: {:error, :invalid_registration}

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp unauthorized(conn, code) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: code})
  end
end
