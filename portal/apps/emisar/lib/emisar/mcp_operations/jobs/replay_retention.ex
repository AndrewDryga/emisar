defmodule Emisar.MCPOperations.Jobs.ReplayRetention do
  @moduledoc """
  Daily sweep that prunes MCP operation identities past the replay window.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(6),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.MCPOperations.Operation
  alias Emisar.Repo
  require Logger

  @replay_window_s 24 * 3_600
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@replay_window_s, :second)
    deleted_count = delete_in_batches(cutoff, 0)

    if deleted_count > 0 do
      Logger.info("mcp_operations.replay_swept", count: deleted_count)
    end

    :ok
  end

  defp delete_in_batches(cutoff, deleted_total) do
    ids = Operation.Query.prunable_ids(cutoff, @batch_size) |> Repo.all()
    {deleted_count, _} = ids |> Operation.Query.by_ids() |> Repo.delete_all()
    deleted_total = deleted_total + deleted_count

    if length(ids) == @batch_size do
      delete_in_batches(cutoff, deleted_total)
    else
      deleted_total
    end
  end
end
