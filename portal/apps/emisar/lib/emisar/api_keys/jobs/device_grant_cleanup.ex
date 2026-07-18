defmodule Emisar.ApiKeys.Jobs.DeviceGrantCleanup do
  @moduledoc """
  Periodic sweep for device-authorization grants: expires overdue pending
  grants (freeing their user codes) and deletes rows past retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(5),
    initial_delay: :timer.seconds(45),
    executor: Emisar.Jobs.Executors.GloballyUnique

  require Logger

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    {expired, deleted} = Emisar.ApiKeys.cleanup_device_grants()

    if expired > 0, do: Logger.info("device_grant_cleanup.expired", count: expired)
    if deleted > 0, do: Logger.info("device_grant_cleanup.deleted", count: deleted)

    :ok
  end
end
