defmodule EmisarWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller — runs `periodic_measurements/0` every 10s so
      # gauge-style metrics (VM memory, run queue lengths) get refreshed.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      | reporter_children()
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Prometheus exporter on a sibling port from the main endpoint so a
  # private scrape (fly's metrics network, kubelet, vmagent) can hit
  # `/metrics` without being routable from the public internet. The
  # port mirrors `fly.toml [metrics] port=9091`; tweak via `METRICS_PORT`
  # if running outside fly.
  #
  # Disabled in :test (the in-process port collision breaks the suite).
  # In :dev the metrics are still useful for local Grafana — set the
  # env var or leave the 9091 default.
  defp reporter_children do
    if Application.get_env(:emisar_web, :enable_prometheus_exporter, Mix.env() != :test) do
      port = String.to_integer(System.get_env("METRICS_PORT") || "9091")
      [{TelemetryMetricsPrometheus, metrics: metrics(), port: port}]
    else
      []
    end
  end

  # TelemetryMetricsPrometheus only supports counter / sum / last_value /
  # distribution — not summary. Phoenix's generated boilerplate uses
  # summary for everything, which silently drops in Prometheus mode.
  # Map latency-shaped metrics to distribution with reasonable web/db
  # buckets, and gauge-shaped (VM memory, queue lengths) to last_value.
  @latency_buckets [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000]
  @db_buckets [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]

  def metrics do
    [
      # Phoenix Metrics
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),
      sum("phoenix.socket_drain.count"),
      distribution("phoenix.channel_joined.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @latency_buckets]
      ),

      # Database Metrics — only the wait + query times are actionable for
      # ops dashboards; total/decode/idle are derivable or noisy.
      distribution("emisar.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "Time spent executing the query",
        reporter_options: [buckets: @db_buckets]
      ),
      distribution("emisar.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "Time spent waiting for a database connection",
        reporter_options: [buckets: @db_buckets]
      ),

      # Oban job metrics — surface stuck queues + retry storms.
      distribution("oban.job.exception.duration",
        unit: {:native, :millisecond},
        tags: [:queue, :worker, :state],
        reporter_options: [buckets: @latency_buckets]
      ),
      distribution("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:queue, :worker, :state],
        reporter_options: [buckets: @latency_buckets]
      ),

      # VM Metrics — last_value, not distribution: these are gauges
      # sampled periodically, not per-event histograms.
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EmisarWeb, :count_users, []}
    ]
  end
end
