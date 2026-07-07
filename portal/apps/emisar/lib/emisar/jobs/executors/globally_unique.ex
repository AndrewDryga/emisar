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
      state = %{module: module, interval: interval, config: config, role: :pending}
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
    schedule_tick(state.interval)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp claim_or_follow(%{module: module} = state) do
    case :global.register_name(global_name(module), self(), &:global.random_notify_name/3) do
      :yes ->
        Logger.debug("job leader acquired job=#{inspect(module)}")
        schedule_tick(Keyword.get(state.config, :initial_delay, 0))
        %{state | role: :leader}

      :no ->
        follow_current_leader(state)
    end
  end

  defp follow_current_leader(%{module: module} = state) do
    case :global.whereis_name(global_name(module)) do
      pid when is_pid(pid) ->
        follow_pid(pid, state)

      _ ->
        Process.send_after(self(), :claim, 100)
        %{state | role: :pending}
    end
  end

  defp follow_pid(pid, state) when pid == self() do
    schedule_tick(Keyword.get(state.config, :initial_delay, 0))
    %{state | role: :leader}
  end

  defp follow_pid(pid, state) do
    monitor_ref = Process.monitor(pid)
    %{state | role: {:fallback, pid, monitor_ref}}
  end

  defp schedule_tick(delay_ms) do
    _ = Process.send_after(self(), :tick, delay_ms)
    :ok
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
        Emisar.Telemetry.job_failed(metadata.job, :error, duration)
        reraise error, __STACKTRACE__
    end
  end

  defp job_name(module), do: module |> Module.split() |> Enum.join(".")
  defp global_name(module), do: {__MODULE__, module}
end
