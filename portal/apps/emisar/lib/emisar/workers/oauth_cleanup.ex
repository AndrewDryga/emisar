defmodule Emisar.Workers.OAuthCleanup do
  @moduledoc """
  Daily sweep that deletes expired OAuth authorization codes. Codes are
  single-use, 60-second exchange artifacts (`emoc-`) — once expired they
  carry no audit or forensic value, so they're pruned rather than left to
  accumulate one row per authorize flow.

  Access/refresh tokens are deliberately NOT touched here: a revoked or
  expired token is a record of who held access and when, which belongs
  under an audit-retention policy, not this hygiene job.

  Idempotent: deleting already-gone rows is a no-op.
  """
  use Oban.Worker, queue: :default, max_attempts: 2
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = Emisar.OAuth.delete_expired_authorization_codes()

    if deleted > 0 do
      Logger.info("oauth_cleanup.codes_swept", count: deleted)
    end

    :ok
  end
end
