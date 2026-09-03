defmodule Emisar.Jobs.Executors.GloballyUnique do
  @moduledoc """
  Runs one recurrent job process across the clustered control plane.

  The scheduler is intentionally in-memory: jobs must be idempotent and derive
  the work set from durable domain rows each tick. A restart may repeat or delay
  a tick, but it cannot lose a durable work item because no work item lives only
  in the scheduler.
  """
  use GenServer
  require Logger

  @callback execute(config :: Keyword.t()) :: :ok

  def start_link({module, interval, config}) do
    GenServer.start_link(__MODULE__, {module, interval, config})
  end

  @impl true
  def init({module, interval, config}) do
    if Keyword.get(config, :enabled, true) do
      state = %{
        module: module,
        interval: interval,
        config: config,
        role: :pending,
        tick_ref: nil
      }

      {:ok, claim_or_follow(state)}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:claim, state), do: {:noreply, claim_or_follow(state)}

  def handle_info(
        {:global_name_conflict, {__MODULE__, module}},
        %{module: module} = state
      ) do
    {:noreply, follow_current_leader(state), :hibernate}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{role: {:fallback, pid, _monitor_ref}} = state
      ) do
    Logger.info(
      "job leader down job=#{inspect(state.module)} leader_pid=#{inspect(pid)} " <>
        "leader_exit_reason=#{inspect(reason)}"
    )

    Process.send_after(self(), :claim, :rand.uniform(200) - 1)
    {:noreply, %{state | role: :pending}}
  end

  def handle_info(:tick, %{role: :leader} = state) do
    execute_job(state.module, state.config)
    {:noreply, schedule_tick(state, state.interval)}
  end

  # The timer that delivered this tick is spent, and this process is no longer
  # the leader, so nothing replaces it.
  def handle_info(:tick, state), do: {:noreply, %{state | tick_ref: nil}}

  defp claim_or_follow(%{module: module} = state) do
    case :global.register_name(global_name(module), self(), &:global.random_notify_name/3) do
      :yes ->
        Logger.debug("job leader acquired job=#{inspect(module)}")
        state = schedule_tick(state, Keyword.get(state.config, :initial_delay, 0))
        %{state | role: :leader}

      :no ->
        follow_current_leader(state)
    end
  end

  defp follow_current_leader(%{module: module} = state) do
    state = cancel_tick(state)

    case :global.whereis_name(global_name(module)) do
      pid when is_pid(pid) ->
        follow_pid(pid, state)

      _ ->
        Process.send_after(self(), :claim, 100)
        %{state | role: :pending}
    end
  end

  # Deliberately NO `pid == self()` clause promoting us back to leader.
  #
  # :global notifies only the LOSER of a name conflict, and that process may
  # read its own node's stale table before the delete has been applied — so
  # whereis_name/1 could answer with the loser's own pid. Treating that as "I am
  # the leader" made both nodes tick forever, with no path back: nothing
  # re-verifies leadership once role is :leader. Re-claim through
  # :global.register_name instead, which takes a global lock and actually
  # decides.
  defp follow_pid(pid, state) when pid == self() do
    Process.send_after(self(), :claim, 100)
    %{state | role: :pending}
  end

  defp follow_pid(pid, state) do
    monitor_ref = Process.monitor(pid)
    %{state | role: {:fallback, pid, monitor_ref}}
  end

  # Exactly one tick timer may be outstanding, so the reference is kept and
  # every scheduling point cancels the previous one first. Throwing the
  # reference away meant a leader that flapped — lost the name, then re-claimed
  # it — kept its old timer AND started a new chain, permanently doubling the
  # job's cadence on that node with no way back.
  defp schedule_tick(state, delay_ms) do
    state = cancel_tick(state)
    %{state | tick_ref: Process.send_after(self(), :tick, delay_ms)}
  end

  defp cancel_tick(%{tick_ref: nil} = state), do: state

  defp cancel_tick(%{tick_ref: tick_ref} = state) do
    _ = Process.cancel_timer(tick_ref)
    %{state | tick_ref: nil}
  end

  defp execute_job(module, config) do
    metadata = %{job: job_name(module)}
    started_at = System.monotonic_time()

    try do
      :ok = module.execute(config)
      duration = System.monotonic_time() - started_at
      Emisar.Telemetry.job_finished(metadata.job, duration)
    rescue
      error ->
        duration = System.monotonic_time() - started_at

        Logger.error("recurrent_job.failed",
          job: metadata.job,
          error: inspect(error.__struct__)
        )

        Emisar.Telemetry.job_failed(metadata.job, :error, duration)
        reraise error, __STACKTRACE__
    end
  end

  defp job_name(module), do: module |> Module.split() |> Enum.join(".")
  defp global_name(module), do: {__MODULE__, module}
end
