defmodule EmisarWeb.HealthController do
  @moduledoc """
  Process liveness and traffic readiness probes.

  A new BEAM reports unhealthy until it reaches PostgreSQL once, preventing a
  rollout from accepting an instance with broken database configuration. After
  that first success, liveness remains independent of PostgreSQL so a later
  database outage does not make the instance manager restart the whole fleet.

  Readiness always checks PostgreSQL. The load balancer therefore stops sending
  traffic to an instance that cannot currently serve it, without replacing an
  otherwise healthy VM.
  """
  use EmisarWeb, :controller
  alias EmisarWeb.AppVersion

  @live_after_ready {__MODULE__, :live_after_ready}

  def live(conn, _params) do
    if :persistent_term.get(@live_after_ready, false) do
      respond(conn, :ok)
    else
      case database_ready?() do
        true ->
          # Remember that this BEAM proved its database configuration. This value
          # resets with the BEAM: it gates each new process through one successful
          # connection, then keeps a shared database outage from causing restarts.
          :persistent_term.put(@live_after_ready, true)
          respond(conn, :ok)

        false ->
          respond(conn, :service_unavailable)
      end
    end
  end

  def ready(conn, _params) do
    status = if database_ready?(), do: :ok, else: :service_unavailable
    respond(conn, status)
  end

  defp database_ready? do
    check =
      Application.get_env(:emisar_web, :database_health_check, fn ->
        Ecto.Adapters.SQL.query(Emisar.Repo, "SELECT 1", [], timeout: 2_000)
      end)

    case check.() do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  end

  defp respond(conn, status) do
    # `version` rides both probes — the MCP registry reconciler compares it
    # against the latest release tag to publish the listing only once the
    # deploy actually serves that version.
    body =
      if status == :ok,
        do: %{status: "ok", version: AppVersion.version()},
        else: %{status: "error", version: AppVersion.version()}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
