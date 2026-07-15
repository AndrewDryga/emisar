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
  alias EmisarWeb.{RequestContext, RunnerSocket}

  # -- Token exchange -------------------------------------------------

  def register(conn, params) do
    with {:ok, enrollment_key} <- read_bearer(conn),
         {:ok, attrs} <- registration_attrs(params),
         {:ok, _runner, _token, raw_token} <-
           Runners.register_via_enrollment_key(
             enrollment_key,
             attrs,
             RequestContext.from_conn(conn)
           ) do
      conn
      |> put_status(:created)
      |> json(%{token: raw_token})
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
              "Delete or rename that runner in the Emisar dashboard (Runners), or set a " <>
              "different runner.name / runner.id in this host's config, then it will connect."
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
        max_frame_size: 1_048_576
      )
      |> halt()
    else
      :missing_bearer ->
        unauthorized(conn, "missing_bearer")

      {:error, :token_invalid} ->
        unauthorized(conn, "token_invalid")
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
