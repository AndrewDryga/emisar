defmodule Emisar.Billing.Jobs.ProcessedEventRetention do
  @moduledoc """
  Daily sweep that prunes the Paddle webhook dedup table past its redelivery
  window.

  `paddle_processed_events` records one row per webhook so a redelivery is
  recognized and not re-applied. It had no retention path at all, so the table
  grew forever to defend against redeliveries Paddle stopped attempting long
  before.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(12)

  alias Emisar.Billing.ProcessedEvent
  alias Emisar.Repo
  require Logger

  # Paddle's own retry schedule ends well inside a day; 30 days leaves a wide
  # margin for a manual replay while keeping the table bounded.
  @dedup_window_days 30
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    cutoff = DateTime.add(DateTime.utc_now(), -@dedup_window_days * 24 * 3_600, :second)
    deleted_count = delete_in_batches(cutoff, 0)

    if deleted_count > 0 do
      Logger.info("billing.paddle_processed_events_swept", count: deleted_count)
    end

    :ok
  end

  defp delete_in_batches(cutoff, deleted_total) do
    ids = cutoff |> ProcessedEvent.Query.prunable_ids(@batch_size) |> Repo.all()
    {deleted_count, _} = ids |> ProcessedEvent.Query.by_ids() |> Repo.delete_all()
    deleted_total = deleted_total + deleted_count

    if length(ids) == @batch_size do
      delete_in_batches(cutoff, deleted_total)
    else
      deleted_total
    end
  end
end
