defmodule Emisar.Workers.OAuthCleanup do
  @moduledoc """
  Daily OAuth hygiene sweep: deletes expired authorization codes and prunes
  dynamically-registered clients that never completed consent (abandoned
  drive-by registrations). Codes are single-use, 60-second exchange artifacts
  (`emoc-`) with no value once expired; an unused client is one no operator
  ever authorized.

  Access/refresh tokens and once-authorized clients are deliberately NOT touched
  here: a revoked/expired token (or a consented client) is a record of access
  that belongs under a retention policy, not this hygiene job.

  Idempotent: deleting already-gone rows is a no-op.
  """
  use Oban.Worker, queue: :default, max_attempts: 2
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    codes = Emisar.OAuth.delete_expired_authorization_codes()
    clients = Emisar.OAuth.delete_unused_clients()

    if codes > 0, do: Logger.info("oauth_cleanup.codes_swept", count: codes)
    if clients > 0, do: Logger.info("oauth_cleanup.unused_clients_swept", count: clients)

    :ok
  end
end
