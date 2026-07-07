defmodule Emisar.Runs.Jobs.DispatchTimeout do
  @moduledoc """
  Periodic sweep that resolves run dispatches that stopped making progress.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(1),
    initial_delay: :timer.seconds(10),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Runners, Runs}
  require Logger

  @dispatch_grace_secs 120
  @redispatch_deadline_secs 600

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    now = DateTime.utc_now()
    grace_cutoff = DateTime.add(now, -@dispatch_grace_secs, :second)
    redispatch_deadline = DateTime.add(now, -@redispatch_deadline_secs, :second)

    Runs.list_stale_dispatches(grace_cutoff)
    |> Enum.each(&resolve_stale_dispatch(&1, redispatch_deadline))

    Runs.list_running_runs()
    |> Enum.each(&maybe_time_out_running(&1, grace_cutoff))

    :ok
  end

  defp resolve_stale_dispatch(run, redispatch_deadline) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        cond do
          not Runners.online?(runner.account_id, runner.id) ->
            Runs.mark_errored(run, unreachable_reason(runner))

          DateTime.compare(run.queued_at, redispatch_deadline) == :lt ->
            Runs.mark_errored(run, never_acknowledged_reason(runner))

          true ->
            Logger.info(
              "run_dispatch_redelivered run=#{run.id} runner=#{run.runner_id} " <>
                "request_id=#{run.request_id}"
            )

            Runs.dispatch_to_runner(run)
        end

      nil ->
        Runs.mark_errored(run, "Runner was removed before this run could be dispatched.")
    end
  end

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
            :noop
        end

      nil ->
        Runs.mark_errored(run, "Runner was removed while this run was in flight.")
    end
  end

  defp offline_past_grace?(%{last_disconnected_at: nil}, _cutoff), do: true

  defp offline_past_grace?(%{last_disconnected_at: disconnected_at}, cutoff),
    do: DateTime.compare(disconnected_at, cutoff) == :lt

  defp unreachable_reason(runner) do
    state = if runner.disabled_at, do: "disabled", else: "offline"

    "Runner #{runner.name} was #{state} when the dispatch was sent. " <>
      "The action never reached it."
  end

  defp never_acknowledged_reason(%{name: name}) do
    "Runner #{name} stayed online but never acknowledged the dispatch. " <>
      "The action was re-sent repeatedly and never started; giving up."
  end
end
