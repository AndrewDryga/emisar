defmodule EmisarWeb.RunnerConnectController do
  @moduledoc """
  Entry points for the runner transport:

    * `POST /runner/register` — exchanges a bootstrap auth key (the one
      baked into the image) for a per-runner token. Called once at first
      boot. Idempotent on `external_id`.

    * `GET  /runner/socket/websocket` — upgrades to the WebSock transport
      after authenticating via `Authorization: Bearer <runner_token>`.
  """

  use EmisarWeb, :controller

  alias Emisar.Runners
  alias EmisarWeb.RunnerSocket

  # -- Token exchange -------------------------------------------------

  def register(conn, params) do
    # 30 registrations per IP per minute. High enough that a real
    # autoscaler bringing up a fleet of nodes won't trip; low enough
    # that an attacker scripting key-guesses against /runner/register
    # is bottlenecked.
    ip = ip_key(conn)

    case EmisarWeb.RateLimiter.check("runner_register:" <> ip, 30, 60_000) do
      {:error, :rate_limited, _ms} ->
        require Logger
        Logger.warning("runner_register.throttled", ip: ip)

        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited"})

      :ok ->
        do_register(conn, params)
    end
  end

  defp do_register(conn, params) do
    with {:ok, auth_key} <- read_bearer(conn),
         {:ok, runner, token, raw_token} <-
           Runners.register_via_auth_key(auth_key, %{
             external_id: params["external_id"],
             hostname: params["hostname"],
             group: params["group"],
             labels: params["labels"] || %{},
             version: params["version"]
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        runner_id: runner.id,
        token: raw_token,
        token_id: token.id,
        account_id: runner.account_id
      })
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :auth_key_invalid} ->
        unauthorized(conn, "auth_key_invalid")

      {:error, :over_limit, plan, limit} ->
        conn
        |> put_status(:payment_required)
        |> json(%{error: "runner_limit_exceeded", plan: plan, limit: limit})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "register_failed", reason: inspect(reason)})
    end
  end

  defp ip_key(conn), do: EmisarWeb.RateLimiter.ip_key(conn)

  # -- WebSocket upgrade ----------------------------------------------

  def websocket(conn, _params) do
    with {:ok, raw} <- read_bearer(conn),
         {:ok, token, runner} <- Runners.verify_runner_token(raw) do
      # Threaded into the socket process so its `Audit.log` calls (in
      # init + terminate) can stash IP + UA on the new process's
      # metadata. The conn's process won't outlive the upgrade.
      state = %{
        token: token,
        runner: runner,
        ip_address: ip_key(conn) |> RunnerSocket.normalize_ip(),
        user_agent: get_req_header(conn, "user-agent") |> List.first()
      }

      conn
      |> WebSockAdapter.upgrade(RunnerSocket, state,
        timeout: 60_000,
        max_frame_size: 1_048_576
      )
      |> halt()
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :token_invalid} ->
        unauthorized(conn, "token_invalid")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "connect_failed", reason: inspect(reason)})
    end
  end

  # -- Helpers --------------------------------------------------------

  defp read_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      ["bearer " <> token] -> {:ok, token}
      _ -> :missing_bearer
    end
  end

  defp unauthorized(conn, code) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: code})
  end
end
