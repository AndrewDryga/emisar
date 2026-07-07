defmodule Emisar.Approvals.Jobs.ExpireOverdueRequests do
  @moduledoc """
  Periodic sweep that expires approval requests whose decision window elapsed.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(5),
    initial_delay: :timer.seconds(30),
    executor: Emisar.Jobs.Executors.GloballyUnique

  require Logger

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    expired = Emisar.Approvals.expire_overdue_requests()

    if expired > 0 do
      Logger.info("approval_expiry.swept", count: expired)
    end

    :ok
  end
end
