defmodule Emisar.Workers.RunDispatchTimeout do
  @moduledoc """
  Resolves runs whose dispatch never completed, so none sit non-terminal
  forever — which reads to operators as "still running" and keeps every
  `wait_for_run` long-poll spinning.

  Runs every minute over `pending`/`sent` rows older than
  `@dispatch_grace_secs` and `running` rows whose runner may have died
  mid-flight, deciding per-run from the runner's current presence:

    * **offline / disabled / removed** → mark `:error` with a clear
      `error_message` (the action never reached it, or the socket died
      mid-run and a reconnect re-registers rather than resumes).
    * **online, still pending/sent** → the dispatch most likely never
      landed: a `run_action` publish lost to a socket drop or a reconnect
      race (PubSub is fire-and-forget, with no per-run delivery ack).
      Re-send it — the runner dedupes by `request_id`, so a redelivery
      replays the cached result or runs it for the first time (idempotent
      recovery). If it stays unacknowledged past `@redispatch_deadline_secs`
      the runner is wedged: stop re-sending and mark `:error`.
    * **online, running** → leave it: slow runs are normal and progress
      events keep ticking over the websocket.

  The grace window must outlast the slowest plausible runner ack so a brief
  network blip doesn't false-positive. Two minutes is comfortably outside
  the heartbeat window + transport buffer; the redispatch deadline is the
  point past which an online-but-silent runner is treated as wedged rather
  than merely slow to acknowledge.
  """
  use Oban.Worker, queue: :default, max_attempts: 2
  alias Emisar.{Runners, Runs}
  require Logger

  @dispatch_grace_secs 120
  @redispatch_deadline_secs 600

  @impl true
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    grace_cutoff = DateTime.add(now, -@dispatch_grace_secs, :second)
    redispatch_deadline = DateTime.add(now, -@redispatch_deadline_secs, :second)

    Runs.list_stale_dispatches(grace_cutoff)
    |> Enum.each(&resolve_stale_dispatch(&1, redispatch_deadline))

    Runs.list_running_runs()
    |> Enum.each(&maybe_time_out_running(&1, grace_cutoff))

    :ok
  end

  # A pending/sent run past the grace window: recover it if the runner is
  # reachable, fail it if not (or if it's wedged past the deadline).
  defp resolve_stale_dispatch(run, redispatch_deadline) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        cond do
          not Runners.online?(runner.account_id, runner.id) ->
            Runs.mark_errored(run, unreachable_reason(runner))

          DateTime.compare(run.queued_at, redispatch_deadline) == :lt ->
            # Online but still unacknowledged long past the grace — the
            # socket's up yet the run never reached :running across many
            # re-sends. Stop retrying; give the operator a terminal row.
            Runs.mark_errored(run, never_acknowledged_reason(runner))

          true ->
            # Online + recently stale: the dispatch likely never landed (a
            # publish lost to a socket drop or a reconnect race). Re-send —
            # the runner dedupes by request_id, so this replays the cached
            # result or runs it once. Idempotent best-effort recovery.
            Logger.info(
              "run_dispatch_redelivered run=#{run.id} runner=#{run.runner_id} " <>
                "request_id=#{run.request_id}"
            )

            Runs.dispatch_to_runner(run)
        end

      nil ->
        # Runner row vanished mid-flight (delete_runner).
        Runs.mark_errored(run, "Runner was removed before this run could be dispatched.")
    end
  end

  # A run can sit in `running` legitimately for a long time — but only while
  # its runner stays connected. If the runner has been continuously offline
  # past the grace window, the result is never coming: the socket died
  # mid-run and a reconnect re-registers rather than resumes. Without this
  # pass the run stays `running` forever and every `wait_for_run` poll times
  # out — the "agent stuck waiting forever" failure mode.
  defp maybe_time_out_running(run, cutoff) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        cond do
          Runners.online?(runner.account_id, runner.id) ->
            :noop

          offline_past_grace?(runner, cutoff) ->
            Runs.mark_errored(
              run,
              "Runner #{runner.name} disconnected while this run was in flight. " <>
                "The result never arrived."
            )

          true ->
            # Recently dropped — give it a chance to reconnect (redeploys
            # bounce sockets routinely); the next sweep re-evaluates.
            :noop
        end

      nil ->
        Runs.mark_errored(run, "Runner was removed while this run was in flight.")
    end
  end

  # A nil last_disconnected_at with an offline runner mid-run is an
  # inconsistent state (the run can't have started without a connect) —
  # expire it rather than zombie the run forever.
  defp offline_past_grace?(%{last_disconnected_at: nil}, _cutoff), do: true

  defp offline_past_grace?(%{last_disconnected_at: at}, cutoff),
    do: DateTime.compare(at, cutoff) == :lt

  defp unreachable_reason(runner) do
    state = if runner.disabled_at, do: "disabled", else: "offline"

    "Runner #{runner.name} was #{state} when the dispatch was sent. " <>
      "The action never reached it."
  end

  defp never_acknowledged_reason(runner) do
    "Runner #{runner.name} stayed online but never acknowledged the dispatch. " <>
      "The action was re-sent repeatedly and never started; giving up."
  end
end
