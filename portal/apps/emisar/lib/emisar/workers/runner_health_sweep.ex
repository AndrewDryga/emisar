defmodule Emisar.Workers.RunnerHealthSweep do
  @moduledoc """
  Periodic sweep that marks runners stale if they haven't heartbeat in
  the last few minutes. The presence diff is more authoritative, but
  this catches runners whose socket died without a clean close.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  alias Emisar.{Repo, Runners}
  alias Emisar.Runners.Runner

  @stale_threshold_secs 180

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_secs, :second)

    Runner.Query.all()
    |> Runner.Query.stale_connected(cutoff)
    |> Repo.all()
    |> Enum.each(fn runner ->
      {:ok, _updated} = Runners.mark_disconnected(runner, "heartbeat timeout")
    end)

    :ok
  end
end
