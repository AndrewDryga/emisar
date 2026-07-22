defmodule EmisarWeb.HealthController do
  @moduledoc """
  Process liveness and traffic readiness probes.

  Application startup already waits for stable PostgreSQL access before the web
  endpoint can serve traffic. Liveness therefore remains independent of later
  database outages so the instance manager does not restart the whole fleet.

  Readiness always checks PostgreSQL. The load balancer therefore stops sending
  traffic to an instance that cannot currently serve it, without replacing an
  otherwise healthy VM.
  """
  use EmisarWeb, :controller
  alias Emisar.DatabaseReadiness
  alias EmisarWeb.AppVersion

  def live(conn, _params), do: respond(conn, :ok)

  def ready(conn, _params) do
    status = if DatabaseReadiness.ready?(), do: :ok, else: :service_unavailable
    respond(conn, status)
  end

  defp respond(conn, status) do
    # Product version drives registry reconciliation; source revision proves
    # which immutable main build is actually serving that version.
    metadata = %{version: AppVersion.version(), revision: AppVersion.revision()}

    body =
      if status == :ok,
        do: Map.put(metadata, :status, "ok"),
        else: Map.put(metadata, :status, "error")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
