defmodule Emisar.OAuth.Jobs.Cleanup do
  @moduledoc """
  Hourly OAuth hygiene sweep: prunes expired authorization codes and tokens,
  reclaims abandoned backing keys, and removes clients that never completed consent.
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
    # After the token sweep, a lapsed connection's backing key has no token left,
    # so this reclaims it (abandoned consents + never-used lapsed connections).
    abandoned = Emisar.OAuth.delete_abandoned_backing_keys()
    clients = Emisar.OAuth.delete_unused_clients()

    if codes > 0, do: Logger.info("oauth_cleanup.codes_swept", count: codes)
    if tokens > 0, do: Logger.info("oauth_cleanup.tokens_swept", count: tokens)
    if abandoned > 0, do: Logger.info("oauth_cleanup.abandoned_keys_swept", count: abandoned)
    if clients > 0, do: Logger.info("oauth_cleanup.unused_clients_swept", count: clients)

    :ok
  end
end
