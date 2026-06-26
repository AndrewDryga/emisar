defmodule EmisarWeb.TelemetryDashboardTest do
  @moduledoc false
  # The reference Grafana dashboard + Prometheus alerts under priv/observability/
  # are operator artifacts the portal never loads at runtime, so nothing else
  # would catch them drifting from the metrics the app actually emits. This ties
  # the dashboard's metric references back to EmisarWeb.Telemetry.metrics/0.
  use ExUnit.Case, async: true

  @observability_dir Path.expand("../../priv/observability", __DIR__)

  test "the reference dashboard charts only metrics EmisarWeb.Telemetry emits" do
    dashboard =
      @observability_dir |> Path.join("dashboard.json") |> File.read!() |> Jason.decode!()

    assert dashboard["panels"] != []

    emitted =
      EmisarWeb.Telemetry.metrics()
      |> Enum.map(&Enum.join(&1.name, "_"))
      |> MapSet.new()

    referenced =
      for panel <- dashboard["panels"], target <- panel["targets"] || [] do
        target["expr"]
      end
      |> Enum.flat_map(&Regex.scan(~r/\b(?:emisar|vm)_[a-z0-9_]+/, &1))
      |> List.flatten()
      # A histogram exposes <name>_bucket; strip it. (Don't strip _count — a
      # counter's own name legitimately ends in _count.)
      |> Enum.map(&String.replace_suffix(&1, "_bucket", ""))
      |> Enum.uniq()

    assert referenced != []

    missing = Enum.reject(referenced, &MapSet.member?(emitted, &1))

    assert missing == [],
           "dashboard.json references metrics EmisarWeb.Telemetry does not emit: #{inspect(missing)}"
  end

  test "the reference alert rules file is present" do
    assert @observability_dir |> Path.join("alerts.yaml") |> File.exists?()
  end
end
