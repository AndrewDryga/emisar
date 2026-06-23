defmodule Emisar.Telemetry do
  @moduledoc """
  Named, per-event emitters for the domain's operator-facing metrics — the
  Telemetry counterpart to the per-event PubSub functions (§ the broadcast
  rule). Every domain signal goes through a named function here, never a bare
  `:telemetry.execute` at the call site, so the event names, measurements, and
  tags live in one auditable place.

  **Cardinality is fleet-wide / bounded-enum tags only — never `account_id`.**
  Tagging a multi-tenant metric by account would explode the Prometheus series
  count and hand out a tenant-enumeration surface; the only tags here are fixed
  enums (a run status, a webhook outcome) the operator can chart.

  The matching `Telemetry.Metrics` definitions live in `EmisarWeb.Telemetry`.
  """

  @doc """
  A run reached a terminal status. Emits `[:emisar, :run, :finished]` with a
  `:count` (1) and the execution `:duration_ms` (0 for non-executed terminals
  like denied/cancelled), tagged by the bounded `status` enum.
  """
  @spec run_finished(atom(), non_neg_integer() | nil) :: :ok
  def run_finished(status, duration_ms) when is_atom(status) do
    :telemetry.execute(
      [:emisar, :run, :finished],
      %{count: 1, duration_ms: duration_ms || 0},
      %{status: status}
    )
  end

  @doc """
  A Paddle webhook event finished processing. Emits `[:emisar, :billing,
  :webhook]` tagged by `outcome` (`:applied | :duplicate | :failed`). NOT tagged
  by the Paddle event_type — that's a vendor-controlled, unbounded label.
  """
  @spec billing_webhook(atom()) :: :ok
  def billing_webhook(outcome) when is_atom(outcome) do
    :telemetry.execute([:emisar, :billing, :webhook], %{count: 1}, %{outcome: outcome})
  end
end
