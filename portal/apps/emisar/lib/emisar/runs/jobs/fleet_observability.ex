defmodule Emisar.Runs.Jobs.FleetObservability do
  @moduledoc """
  Cluster-singleton emitter of the fleet-wide observability signal — the
  connected-runner count and the pending-dispatch backlog depth — as one
  structured log line (`fleet.observability`) that GCP log-based metrics and
  alerts watch (a runner-fleet drop to zero, a dispatch backlog with no eligible
  runner; both are silent to `/readyz` and `lb_5xx`).

  Runs under `GloballyUnique` so exactly ONE node emits per tick — a per-node
  emit would multiply the counts across the cluster and misread the aggregate.
  Emits EVERY tick, including the zero state, so "zero connected runners" is a
  visible data point for the alert rather than indistinguishable from a gap in
  logging.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(1),
    initial_delay: :timer.seconds(60),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Runners, Runs}
  require Logger

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    Logger.info("fleet.observability",
      connected_runners: Runners.connection_counts().connected,
      pending_dispatch_depth: Runs.count_pending_dispatches()
    )

    :ok
  end
end
