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
    # Product version drives registry reconciliation and is already public (the
    # marketing footer renders it). The source revision is deliberately withheld
    # from these anonymous probes: the repository is public, so the exact deployed
    # Git SHA would hand a caller the precise source tree and lockfile serving
    # production. The baked revision is verified from the image itself
    # (/app/REVISION) in CI and confirmed by a deploy's reviewed image digest.
    metadata = %{version: AppVersion.version()}

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
