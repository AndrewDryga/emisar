defmodule EmisarWeb.MetricsPlugTest do
  use ExUnit.Case, async: false
  import Telemetry.Metrics
  alias EmisarWeb.MetricsPlug

  setup do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       start_async: false,
       metrics: [
         counter("emisar_web.metrics_plug_test.count",
           event_name: [:emisar_web, :metrics_plug_test]
         )
       ]}
    )

    :ok
  end

  test "GET /metrics returns the reporter's Prometheus scrape" do
    :telemetry.execute([:emisar_web, :metrics_plug_test], %{}, %{})

    conn =
      :get
      |> Plug.Test.conn("/metrics")
      |> MetricsPlug.call(MetricsPlug.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert conn.private.prometheus_metrics_name == :prometheus_metrics
    assert conn.resp_body =~ "# TYPE emisar_web_metrics_plug_test_count counter"
    assert conn.resp_body =~ "emisar_web_metrics_plug_test_count 1"
  end

  test "all other requests are refused" do
    for {method, path} <- [{:get, "/"}, {:post, "/metrics"}] do
      conn =
        method
        |> Plug.Test.conn(path)
        |> MetricsPlug.call(MetricsPlug.init([]))

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end
end
