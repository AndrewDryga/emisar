defmodule Emisar.Workers.RunDispatchTimeout do
  @moduledoc """
  Times out runs whose runner went away: `pending`/`sent` rows older than
  `@dispatch_grace_secs` with an offline runner, and `running` rows whose
  runner has been continuously offline past the same grace (the socket
  died mid-run — the result is never coming). Without this sweep those
  runs sit non-terminal forever, which reads to operators as "still
  running" and keeps every `wait_for_run` long-poll spinning.

  Behavior:

    * runner is online (tracked in `Emisar.Runners.Presence`) → leave the
      run alone (slow runs are normal, progress events keep ticking over
      the websocket).
    * runner is offline / disabled / deleted → mark the run as `:error`
      with a clear `error_message` explaining the runner was unreachable.
      Operator sees a terminal red row with context.

  The grace window has to be longer than the slowest plausible runner
  ack so we don't false-positive a brief network blip. Two minutes is
  comfortably outside the heartbeat window + transport buffer.
  """
  use Oban.Worker, queue: :default, max_attempts: 2
  alias Emisar.{Runners, Runs}

  @dispatch_grace_secs 120

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@dispatch_grace_secs, :second)

    Runs.list_stale_dispatches(cutoff)
    |> Enum.each(&maybe_time_out/1)

    Runs.list_running_runs()
    |> Enum.each(&maybe_time_out_running(&1, cutoff))

    :ok
  end

  # A run can sit in `running` legitimately for a long time — but only while
  # its runner stays connected. If the runner has been continuously offline
  # past the grace window, the result is never coming: the socket died
  # mid-run and a reconnect re-registers rather than resumes. Without this
  # pass the run stays `running` forever and every `wait_for_run` poll times
  # out — the "agent stuck waiting forever" failure mode.
  defp maybe_time_out_running(run, cutoff) do
    case Runners.peek_runner_by_id(run.runner_id) do
      {:ok, runner} ->
        cond do
          Runners.online?(runner.account_id, runner.id) ->
            :noop

          offline_past_grace?(runner, cutoff) ->
            Runs.mark_runner_unreachable(
              run,
              "Runner #{runner.name} disconnected while this run was in flight. " <>
                "The result never arrived."
            )

          true ->
            # Recently dropped — give it a chance to reconnect (redeploys
            # bounce sockets routinely); the next sweep re-evaluates.
            :noop
        end

      {:error, :not_found} ->
        Runs.mark_runner_unreachable(run, "Runner was removed while this run was in flight.")
    end
  end

  # A nil last_disconnected_at with an offline runner mid-run is an
  # inconsistent state (the run can't have started without a connect) —
  # expire it rather than zombie the run forever.
  defp offline_past_grace?(%{last_disconnected_at: nil}, _cutoff), do: true

  defp offline_past_grace?(%{last_disconnected_at: at}, cutoff),
    do: DateTime.compare(at, cutoff) == :lt

  defp maybe_time_out(run) do
    case Runners.peek_runner_by_id(run.runner_id) do
      {:ok, runner} ->
        if Runners.online?(runner.account_id, runner.id) do
          # Runner's online — the run is just slow. Leave it.
          :noop
        else
          Runs.mark_runner_unreachable(run, unreachable_reason(runner))
        end

      {:error, :not_found} ->
        # Runner row vanished mid-flight (delete_runner).
        Runs.mark_runner_unreachable(
          run,
          "Runner was removed before this run could be dispatched."
        )
    end
  end

  defp unreachable_reason(runner) do
    state = if runner.disabled_at, do: "disabled", else: "offline"

    "Runner #{runner.name} was #{state} when the dispatch was sent. " <>
      "The action never reached it."
  end
end
