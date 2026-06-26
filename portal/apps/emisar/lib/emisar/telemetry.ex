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
  # `Oban.Job` is a third-party schema with no domain Query module, so IL-1's
  # "start every pipeline at Schema.Query" cannot apply — the queue-backlog read
  # in `oban_available_by_queue/0` is the one sanctioned inline query here.
  # credo:disable-for-next-line Emisar.Checks.IL01NoInlineEctoDsl
  import Ecto.Query
  alias Emisar.{Approvals, Repo, Runners}

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

  @oban_event [:emisar, :oban, :queue]

  @doc """
  Sampler — Oban queue backlog. Emits `[:emisar, :oban, :queue]` once per
  CONFIGURED queue with the count of `:available` (waiting) jobs, tagged by the
  bounded `:queue` name. Emitting every configured queue — not just the
  non-empty ones — keeps a drained queue's gauge from going stale at its last
  non-zero reading.
  """
  @spec measure_oban_queues() :: :ok
  def measure_oban_queues do
    counts = oban_available_by_queue()

    # Union the configured queues (so a drained one still reports 0, never a stale
    # gauge) with the queues actually holding jobs (so a job in a queue this node
    # doesn't run — or test mode, where `:queues` is `false` — still reports).
    queues = Enum.uniq(configured_oban_queues() ++ Map.keys(counts))

    Enum.each(queues, fn queue ->
      :telemetry.execute(@oban_event, %{available: Map.get(counts, queue, 0)}, %{queue: queue})
    end)
  end

  # `%{queue => available_count}` from oban_jobs. A drained queue is simply
  # absent (no rows); `measure_oban_queues/0` fills it with 0.
  defp oban_available_by_queue do
    query =
      from(j in Oban.Job,
        where: j.state == "available",
        group_by: j.queue,
        select: {j.queue, count(j.id)}
      )

    query |> Repo.all() |> Map.new()
  end

  # The queues this node is configured to run, as strings (oban_jobs.queue is
  # text). `:queues` is `false` when queue-running is disabled (Oban test mode) —
  # then there's no configured set and the caller falls back to queues with jobs.
  defp configured_oban_queues do
    case Application.fetch_env!(:emisar, Oban)[:queues] do
      queues when is_list(queues) -> Enum.map(Keyword.keys(queues), &Atom.to_string/1)
      _ -> []
    end
  end
end
