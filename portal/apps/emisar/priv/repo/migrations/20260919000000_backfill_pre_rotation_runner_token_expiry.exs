defmodule Emisar.Repo.Migrations.BackfillPreRotationRunnerTokenExpiry do
  use Ecto.Migration

  # Step two of two, and the last thing keeping a leaked runner token alive
  # forever. Rotation added the column, enforcement started reading it, and
  # every token minted since carries a 90-day life — but a token minted BEFORE
  # rotation existed still has none, and NULL means never expires.
  #
  # Most of these are not credentials anyone still holds. A runner that
  # re-registers leaves its previous token behind, so several hosts have
  # accumulated four or five valid tokens where the process on disk holds one.
  # Nobody would notice one of those leaking, which is precisely the case expiry
  # was chosen to bound.
  #
  # Every NULL row, including tokens belonging to a disabled runner: disable is
  # reversible, so re-enabling one would otherwise hand back an immortal
  # credential. Tokens on soft-deleted runners are already refused at verify;
  # sweeping them costs nothing and needs no exception to reason about.
  #
  # 180 days rather than the usual 90, deliberately. A freshly minted token has
  # a client that asked for it and refreshes itself at 60 days; these have
  # neither guarantee — the host may run a binary with no refresh path at all,
  # and recovers by re-registering with its enrollment key rather than by
  # rotating. Doubling the normal life buys that host a reconnect it can act on.
  #
  # Unbatched on purpose: this touches tens of rows, not millions. The table
  # holds a handful per runner, and the NULL set is historical and only shrinks.
  def up do
    execute("""
    UPDATE runner_tokens
    SET expires_at = now() + interval '180 days'
    WHERE expires_at IS NULL
    """)
  end

  # Irreversible. NULL carried no information beyond "minted before rotation",
  # and restoring it would hand every one of these rows its immortality back.
  def down, do: :ok
end
