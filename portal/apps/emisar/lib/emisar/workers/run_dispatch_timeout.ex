defmodule Emisar.Workers.RunDispatchTimeout do
  @moduledoc """
  Times out runs that have been sitting in `pending` or `sent` longer
  than `@dispatch_grace_secs` when the target runner is offline. Without
  this sweep a run dispatched to a runner that's down — disabled,
  disconnected, missing — would sit in `sent` forever, which reads to
  operators as "the action is still running" and is the opposite of true.

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

    :ok
  end

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
