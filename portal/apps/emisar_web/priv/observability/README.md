# emisar observability — reference dashboard + alerts

Drop-in Grafana dashboard and Prometheus alerting rules for an emisar control
plane. They chart and alert on the domain signals emisar emits — run outcomes,
the approval SLO, runner fleet health, recurrent job failures, billing webhooks — plus
a few infrastructure lines (DB latency, the BEAM atom-table leak warning).

These are **reference artifacts you import into your own stack**; the portal does
not load them at runtime. The single source of truth for the metric names is
`EmisarWeb.Telemetry.metrics/0` — a test (`telemetry_dashboard_test.exs`) asserts
every metric the dashboard charts is one the app actually emits, so the dashboard
can't silently drift from the code.

## 1. Scrape emisar

The portal runs a Prometheus exporter (`TelemetryMetricsPrometheus`) on a sibling
port to the main endpoint — `METRICS_PORT`, default **9091** — so a private scrape
(Fly's metrics network, a kubelet, vmagent) can reach `/metrics` without it being
publicly routable. Point a scrape job at `:9091/metrics`.

The names map from `Telemetry.Metrics` dotted names to Prometheus form: dots
become underscores, counters and gauges carry no suffix, and histograms expose
`_bucket` / `_sum` / `_count` (e.g. `emisar.run.finished.duration_ms` →
`emisar_run_finished_duration_ms_bucket`). All domain metrics are **fleet-wide and
never tagged by account** (series cardinality + tenant enumeration — see
`Emisar.Telemetry`).

## 2. Load the alerts

Reference `alerts.yaml` from your Prometheus config and reload:

```yaml
# prometheus.yml
rule_files:
  - /etc/prometheus/emisar/alerts.yaml
```

Validate after any edit:

```sh
promtool check rules alerts.yaml
```

The rules fire on the SLOs the code calls out: approvals waiting too long
(`emisar_approvals_pending_oldest_age_seconds`), runners dropped, recurrent job
failures, host run-failure rate, failing Paddle webhooks, and atom-table growth
(the IL-14 early-warning line).

## 3. Import the dashboard

In Grafana: **Dashboards → New → Import → Upload `dashboard.json`**, then pick your
Prometheus data source when prompted (the dashboard exposes it as a `datasource`
template variable, so nothing is hard-coded).
