defmodule Emisar.Workers.RunnerHealthSweep do
  @moduledoc """
  Periodic sweep that marks runners stale if they haven't heartbeat in
  the last few minutes. The presence diff is more authoritative, but
  this catches runners whose socket died without a clean close.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Runners.Runner
  alias Emisar.PubSub

  @stale_threshold_secs 180

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_secs, :second)

    stale =
      from(a in Runner,
        where: a.status == "connected" and (is_nil(a.last_heartbeat_at) or a.last_heartbeat_at < ^cutoff)
      )
      |> Repo.all()

    Enum.each(stale, fn runner ->
      {:ok, updated} =
        runner
        |> Runner.disconnected_changeset("heartbeat timeout")
        |> Repo.update()

      PubSub.broadcast_runner(updated, :runner_disconnected)
    end)

    :ok
  end
end
