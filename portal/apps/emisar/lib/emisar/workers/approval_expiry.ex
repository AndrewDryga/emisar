defmodule Emisar.Workers.ApprovalExpiry do
  @moduledoc """
  Sweeps expired approval requests: every 5 minutes, any pending
  request whose `expires_at` has passed is transitioned to `"expired"`
  and the underlying run is cancelled. The intent is twofold:

    * An LLM agent must not be able to hold a high-risk action open
      indefinitely waiting for an operator who never decides. A 24-hour
      default window (set in `Emisar.Approvals.create_request/3`) is
      the SOC-2-friendly bound.
    * Operators clicking into the approvals page only see live work.
      Stale requests pile up otherwise and the queue becomes useless.

  Idempotent: re-running over the same row is a no-op (the inner
  update is gated on `status == "pending"`).
  """
  use Oban.Worker, queue: :default, max_attempts: 2
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    expired = Emisar.Approvals.expire_overdue_requests()

    if expired > 0 do
      Logger.info("approval_expiry.swept", count: expired)
    end

    :ok
  end
end
