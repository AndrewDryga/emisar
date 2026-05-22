defmodule EmisarWeb.HealthController do
  @moduledoc """
  Liveness probe. Returns 200 if the BEAM is responsive and the DB
  connection pool can answer a `SELECT 1`. Used by fly.io / kubernetes
  to decide whether to route traffic.
  """
  use EmisarWeb, :controller

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Emisar.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{status: "ok"})

      {:error, _} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error"})
    end
  end
end
