defmodule Emisar.Repo.Migrations.NoHistoricalHoldIsTrustedAsTheDirectorys do
  @moduledoc """
  The end of a chain of three repairs, and the one that actually finishes it.

  `20260903000000`'s moduledoc claimed it took the conservative side of both holes
  its predecessor left. Its SQL only cleared the ambiguous ones (`n > 1`). The other
  half survives:

    * `20260829000000` relabels an operator's hold as directory-owned, because a
      manually suspended member whose identity later goes inactive looks identical
      to one the directory suspended.
    * `20260902000000` sees exactly one candidate and keeps that attribution.
    * `20260903000000` sees `n == 1` and leaves it alone.
    * A later IdP activation then lifts a hold a human placed.

  Nothing in the data separates the two cases — nobody recorded which connection
  deprovisioned, or whether a person or a directory placed the hold. So this stops
  trying: no hold that predates today is trusted as the directory's. Every live
  `directory_suspended` row is handed back to operators.

  `disabled_at` is untouched, so nobody's access changes: the member stays out. What
  changes is who may release them — a human, rather than an authority we cannot
  identify. And the directory re-owns the hold the moment it speaks again, because
  `Accounts.sync_suspend_membership/2` re-stamps ownership on the next
  `active: false` for that person.

  The one cost is the reverse of the bug: for a genuinely directory-suspended
  member, an operator can lift the hold before the next directory push re-places it.
  That is the safe direction. The alternative left an IdP able to release what an
  operator decided.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE account_memberships
    SET directory_suspended = false,
        directory_provider_id = NULL,
        updated_at = now()
    WHERE directory_suspended = true
      AND deleted_at IS NULL
    """
  end

  # No down. Re-asserting directory ownership over holds nobody can attribute is
  # the state this exists to leave behind.
  def down, do: :ok
end
