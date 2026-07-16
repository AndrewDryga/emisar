defmodule Emisar.OAuth.Jobs.Cleanup do
  @moduledoc """
  Periodic OAuth hygiene sweep for expired codes and abandoned clients.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(3),
    executor: Emisar.Jobs.Executors.GloballyUnique

  require Logger

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    codes = Emisar.OAuth.delete_expired_authorization_codes()
    tokens = Emisar.OAuth.delete_expired_tokens()
    clients = Emisar.OAuth.delete_unused_clients()

    if codes > 0, do: Logger.info("oauth_cleanup.codes_swept", count: codes)
    if tokens > 0, do: Logger.info("oauth_cleanup.tokens_swept", count: tokens)
    if clients > 0, do: Logger.info("oauth_cleanup.unused_clients_swept", count: clients)

    :ok
  end
end
