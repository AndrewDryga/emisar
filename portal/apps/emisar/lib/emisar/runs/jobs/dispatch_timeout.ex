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

    stale_dispatches = Runs.list_stale_dispatches(grace_cutoff)

    stale_dispatches
    |> Enum.filter(&(&1.status == :sent))
    |> Enum.each(&resolve_stale_dispatch(&1, redispatch_deadline))

    stale_dispatches
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.group_by(& &1.runner_id)
    |> Enum.each(fn {_runner_id, runs} ->
      resolve_stale_pending_dispatches(runs, redispatch_deadline)
    end)

    Runs.list_running_runs()
    |> Enum.each(&maybe_time_out_running(&1, grace_cutoff))

    :ok
  end

  defp resolve_stale_pending_dispatches([oldest | _] = runs, redispatch_deadline) do
    case Runners.peek_runner_by_id(oldest.runner_id) do
      %Runners.Runner{} = runner ->
        resolve_stale_pending_dispatches(runs, runner, oldest, redispatch_deadline)

      nil ->
        Enum.each(runs, &Runs.mark_errored(&1, removed_runner_reason(&1)))
    end
  end

  defp resolve_stale_pending_dispatches([], _redispatch_deadline), do: :ok

  defp resolve_stale_pending_dispatches(runs, runner, oldest, _redispatch_deadline) do
    case Runners.current_connection_generation(runner.account_id, runner.id) do
      {:ok, _generation} ->
        Runs.dispatch_to_runner(oldest)

      {:error, :not_connected} ->
        Enum.each(runs, &Runs.mark_errored(&1, unreachable_reason(&1, runner)))
    end
  end

  defp resolve_stale_dispatch(run, redispatch_deadline) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        resolve_stale_dispatch(run, runner, redispatch_deadline)

      nil ->
        mark_stale_dispatch_errored(run, removed_runner_reason(run))
    end
  end

  defp resolve_stale_dispatch(%{status: :sent} = run, runner, redispatch_deadline) do
    case Runners.current_connection_generation(runner.account_id, runner.id) do
      {:error, :not_connected} ->
        mark_stale_dispatch_errored(run, unreachable_reason(run, runner))

      {:ok, generation} ->
        cond do
          DateTime.compare(run.queued_at, redispatch_deadline) == :lt ->
            mark_stale_dispatch_errored(run, never_acknowledged_reason(runner))

          run.runner_connection_generation != generation ->
            :noop

          true ->
            Logger.info(
              "run_dispatch_redelivered run=#{run.id} runner=#{run.runner_id} " <>
                "request_id=#{run.request_id}"
            )

            Runs.redeliver_to_runner(run)
        end
    end
  end

  defp mark_stale_dispatch_errored(%{status: :sent} = run, reason) do
    case Runs.mark_errored(run, reason) do
      {:ok, _run} = result ->
        Runs.dispatch_queued_for_runner(run.runner_id)
        result

      other ->
        other
    end
  end

  defp mark_stale_dispatch_errored(run, reason), do: Runs.mark_errored(run, reason)

  defp maybe_time_out_running(run, cutoff) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        case Runners.current_connection_generation(runner.account_id, runner.id) do
          {:ok, _generation} ->
            :noop

          {:error, :not_connected} ->
            if offline_past_grace?(runner, cutoff) do
              Runs.mark_errored(
                run,
                "Runner #{runner.name} disconnected while this run was in flight. " <>
                  "The result never arrived."
              )
            else
              :noop
            end
        end

      nil ->
        Runs.mark_errored(run, "Runner was removed while this run was in flight.")
    end
  end

  defp offline_past_grace?(%{last_disconnected_at: nil}, _cutoff), do: true

  defp offline_past_grace?(%{last_disconnected_at: disconnected_at}, cutoff),
    do: DateTime.compare(disconnected_at, cutoff) == :lt

  defp unreachable_reason(%{status: :pending}, runner) do
    state = if runner.disabled_at, do: "disabled", else: "offline"

    "Runner #{runner.name} was #{state} while the dispatch was queued. " <>
      "The action never reached it."
  end

  defp unreachable_reason(%{status: :sent}, runner) do
    state = if runner.disabled_at, do: "disabled", else: "disconnected"

    "Runner #{runner.name} #{state} after accepting this dispatch. " <>
      "Its execution outcome is unknown, so Emisar did not execute it again."
  end

  defp never_acknowledged_reason(%{name: name}) do
    "Runner #{name} stayed online but never produced a durable result. " <>
      "Its execution outcome is unknown, so Emisar did not execute it again."
  end

  defp removed_runner_reason(%{status: :pending}),
    do: "Runner was removed before this run could be dispatched. The action never reached it."

  defp removed_runner_reason(%{status: :sent}) do
    "Runner was removed after accepting this dispatch. " <>
      "Its execution outcome is unknown, so Emisar did not execute it again."
  end
end
