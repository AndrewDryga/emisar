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

  Event emitters take their value as arguments (the call site has it). Periodic
  GAUGES — fleet-wide state sampled on a timer — are the `measure_*/0` functions
  at the bottom: the telemetry poller invokes them, each reads a fleet-wide
  domain aggregate and emits it. Same cardinality rule (no `account_id`).

  The matching `Telemetry.Metrics` definitions live in `EmisarWeb.Telemetry`.
  """
  alias Emisar.{Approvals, Runners}

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

  @doc """
  An approval request reached a terminal decision. Emits `[:emisar, :approval,
  :decided]` tagged by the bounded `decision` (`:approved | :denied | :expired`).
  """
  @spec approval_decided(atom()) :: :ok
  def approval_decided(decision) when is_atom(decision) do
    :telemetry.execute([:emisar, :approval, :decided], %{count: 1}, %{decision: decision})
  end

  @doc """
  A magic-link sign-in failed for a token that couldn't be resolved to a user
  (a consumed / unknown / undecodable token), so there was no account to write an
  `user.sign_in_failed` audit row onto — this is the only visibility that failure
  gets. Emits `[:emisar, :auth, :magic_link_failed]` tagged by the bounded `reason`.
  """
  @spec magic_link_failed(atom()) :: :ok
  def magic_link_failed(reason) when is_atom(reason) do
    :telemetry.execute([:emisar, :auth, :magic_link_failed], %{count: 1}, %{reason: reason})
  end

  @doc """
  A supervised recurrent job completed. Emits duration tagged by bounded job
  module name.
  """
  @spec job_finished(String.t(), integer()) :: :ok
  def job_finished(job, duration) when is_binary(job) and is_integer(duration) do
    :telemetry.execute([:emisar, :job, :finished], %{duration: duration}, %{job: job})
  end

  @doc """
  A supervised recurrent job crashed. Emits one failure and its duration tagged
  by bounded job module name and failure kind.
  """
  @spec job_failed(String.t(), atom(), integer()) :: :ok
  def job_failed(job, kind, duration) when is_binary(job) and is_atom(kind) do
    :telemetry.execute(
      [:emisar, :job, :failed],
      %{count: 1, duration: duration},
      %{job: job, kind: kind}
    )
  end

  # -- Periodic gauges (poller-invoked samplers) ------------------------

  @doc """
  Sampler — the fleet-wide approval queue. Reads `Approvals.pending_queue_stats/0`
  and emits `[:emisar, :approvals, :pending]` with the unresolved `:count` and the
  `:oldest_age_seconds` of the longest-waiting request. The telemetry poller
  invokes this; fleet-wide and untagged (the no-`account_id` rule above).
  """
  @spec measure_approval_queue() :: :ok
  def measure_approval_queue do
    %{count: count, oldest_age_seconds: age} = Approvals.pending_queue_stats()
    :telemetry.execute([:emisar, :approvals, :pending], %{count: count, oldest_age_seconds: age})
  end

  @doc """
  Sampler — the fleet-wide runner connection tally from the durable connection
  record (see `Runners.connection_counts/0`). Emits `[:emisar, :runners,
  :connection]` with `:connected` / `:disconnected` / `:never_connected` /
  `:disabled` counts. Poller-invoked; fleet-wide and untagged.
  """
  @spec measure_runner_connections() :: :ok
  def measure_runner_connections do
    :telemetry.execute([:emisar, :runners, :connection], Runners.connection_counts())
  end
end
