defmodule Emisar.SSO.Jobs.AuthorizationReconcile do
  @moduledoc """
  Retries durable, fail-closed directory authorization reconciliation.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(1),
    initial_delay: :timer.seconds(10),
    executor: Emisar.Jobs.Executors.GloballyUnique

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    Emisar.SSO.reconcile_pending_authorizations()
    :ok
  end
end
