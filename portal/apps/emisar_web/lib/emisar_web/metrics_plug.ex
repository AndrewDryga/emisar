defmodule EmisarWeb.MetricsPlug do
  @moduledoc false

  use Plug.Router
  alias Plug.Conn

  plug(:match)
  plug(Plug.Telemetry, event_prefix: [:prometheus_metrics, :plug])
  plug(:dispatch)

  get "/metrics" do
    body = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> Conn.put_private(:prometheus_metrics_name, :prometheus_metrics)
    |> Conn.put_resp_content_type("text/plain")
    |> Conn.send_resp(200, body)
  end

  match _ do
    Conn.send_resp(conn, 404, "Not Found")
  end
end
