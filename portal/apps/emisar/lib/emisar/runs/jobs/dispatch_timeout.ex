defmodule Emisar.Runs.Jobs.DispatchTimeout do
  @moduledoc """
  Periodic sweep that resolves run dispatches that stopped making progress.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(1),
    initial_delay: :timer.seconds(10)

  alias Emisar.{Runners, Runs}
  require Logger

  @dispatch_grace_secs 120
  @batch_size 2_000

  @doc "Whether the sweep clock has reached a run's published dispatch deadline. Pure."
  def deadline_reached?(%DateTime{} = now, %DateTime{} = deadline),
    do: DateTime.compare(now, deadline) != :lt

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    now = DateTime.utc_now()
    grace_cutoff = DateTime.add(now, -@dispatch_grace_secs, :second)
    limit = config |> Keyword.get(:batch_size, @batch_size) |> min(@batch_size) |> max(1)

    sweep_sent(grace_cutoff, now, limit, nil)
    sweep_pending(grace_cutoff, limit, nil, nil)
    sweep_running(grace_cutoff, limit, nil)

    :ok
  end

  defp sweep_sent(cutoff, now, limit, cursor) do
    rows = Runs.list_stale_sent_dispatches(cutoff, limit, cursor)
    generations = connection_generations(rows)

    Enum.each(rows, fn run ->
      resolve_safely(run, fn ->
        generation = generations[{run.account_id, run.runner_id}]
        %{dispatch_deadline_at: deadline} = Runs.run_outcome_facts(run)

        cond do
          is_nil(generation) or deadline_reached?(now, deadline) ->
            resolve_stale_dispatch(run, now)

          generation == run.runner_connection_generation ->
            redeliver(run)

          true ->
            :noop
        end
      end)
    end)

    if length(rows) == limit, do: sweep_sent(cutoff, now, limit, List.last(rows).id)
  end

  defp sweep_pending(cutoff, limit, cursor, last_dispatched_runner) do
    rows = Runs.list_stale_pending_dispatches(cutoff, limit, cursor)
    generations = connection_generations(rows)

    last_dispatched_runner =
      Enum.reduce(rows, last_dispatched_runner, fn run, last_runner ->
        case resolve_safely(run, fn -> resolve_pending(run, generations, last_runner) end) do
          :dispatched -> run.runner_id
          _other -> last_runner
        end
      end)

    if length(rows) == limit do
      last = List.last(rows)
      sweep_pending(cutoff, limit, {last.runner_id, last.id}, last_dispatched_runner)
    end
  end

  defp resolve_pending(run, generations, last_runner) do
    if Map.has_key?(generations, {run.account_id, run.runner_id}) do
      dispatch_pending(run.runner_id, last_runner)
    else
      # A connection may have arrived since the batch read. Negative facts
      # never authorize a terminal transition without a fresh connection check.
      case Runners.peek_runner_by_id(run.runner_id) do
        nil ->
          Runs.mark_errored(run, removed_runner_reason(run))

        %Runners.Runner{} = runner ->
          case Runners.current_connection_generation(run.account_id, run.runner_id) do
            {:ok, _generation} -> dispatch_pending(run.runner_id, last_runner)
            {:error, :not_connected} -> Runs.mark_errored(run, unreachable_reason(run, runner))
          end
      end
    end
  end

  defp dispatch_pending(runner_id, runner_id), do: :noop

  defp dispatch_pending(runner_id, _last_runner) do
    Runs.dispatch_queued_for_runner(runner_id)
    :dispatched
  end

  defp sweep_running(cutoff, limit, cursor) do
    rows = Runs.list_running_runs(limit, cursor)
    generations = connection_generations(rows)

    Enum.each(rows, fn run ->
      unless Map.has_key?(generations, {run.account_id, run.runner_id}) do
        resolve_safely(run, fn -> maybe_time_out_running(run, cutoff) end)
      end
    end)

    if length(rows) == limit, do: sweep_running(cutoff, limit, List.last(rows).id)
  end

  defp connection_generations([]), do: %{}

  defp connection_generations(rows) do
    rows
    |> Enum.map(&{&1.account_id, &1.runner_id})
    |> Runners.current_connection_generations()
  end

  defp resolve_safely(run, resolve) do
    resolve.()
  rescue
    error ->
      Logger.warning("sweep.row_failed row=#{run.id}",
        job: inspect(__MODULE__),
        error: inspect(error.__struct__)
      )

      :failed
  end

  defp resolve_stale_dispatch(run, now) do
    case Runners.peek_runner_by_id(run.runner_id) do
      %Runners.Runner{} = runner ->
        resolve_stale_dispatch(run, runner, now)

      nil ->
        mark_stale_dispatch_errored(run, removed_runner_reason(run))
    end
  end

  defp resolve_stale_dispatch(%{status: :sent} = run, runner, now) do
    %{dispatch_deadline_at: deadline} = Runs.run_outcome_facts(run)

    case Runners.current_connection_generation(runner.account_id, runner.id) do
      {:error, :not_connected} ->
        mark_stale_dispatch_errored(run, unreachable_reason(run, runner))

      {:ok, generation} ->
        cond do
          deadline_reached?(now, deadline) ->
            mark_stale_dispatch_errored(run, never_acknowledged_reason(runner))

          run.runner_connection_generation != generation ->
            :noop

          true ->
            redeliver(run)
        end
    end
  end

  defp redeliver(run) do
    Logger.info(
      "run_dispatch_redelivered run=#{run.id} runner=#{run.runner_id} " <>
        "request_id=#{run.request_id}"
    )

    Runs.redeliver_to_runner(run)
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
