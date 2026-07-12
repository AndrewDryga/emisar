defmodule EmisarWeb.HealthController do
  @moduledoc """
  Process liveness and traffic readiness probes.

  Liveness is intentionally independent of PostgreSQL so a database outage
  does not make the instance manager restart every healthy BEAM. Readiness
  includes PostgreSQL because the load balancer must not send application
  traffic to a node that cannot serve it.
  """
  use EmisarWeb, :controller

  @live_after_ready {__MODULE__, :live_after_ready}

  def live(conn, _params) do
    if :persistent_term.get(@live_after_ready, false) do
      respond(conn, :ok)
    else
      case database_ready?() do
        true ->
          # The MIG must not replace an old VM until its surge replacement has
          # reached readiness once. After that, liveness stays DB-independent so
          # a database outage cannot restart the whole fleet.
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
    case Ecto.Adapters.SQL.query(Emisar.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  end

  defp respond(conn, status) do
    body = if status == :ok, do: %{status: "ok"}, else: %{status: "error"}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
