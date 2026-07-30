defmodule Emisar.Repo.Migrations.ASuspensionNobodyCanProveBelongsToOperators do
  @moduledoc """
  `20260902000000` only re-attributed a suspension when exactly one live identity
  was a candidate, and only cleared ownership when the stamped provider was NOT a
  candidate. Two holes follow from that, both found in review.

  An ambiguous row keeps its guess. If connection A was stamped arbitrarily and
  both A and B are candidates, A satisfies the `EXISTS` and survives — so B, which
  may be the connection that actually deprovisioned the person, cannot lift its own
  hold, while A can lift one it never placed.

  And a single candidate is not provenance. A member suspended by a human can later
  receive `active: false` from a directory: `Accounts.sync_suspend_membership/2`
  deliberately leaves the existing hold alone, but the identity is still marked
  inactive, which makes it a candidate. The earlier migrations then relabel a
  manual hold as directory-owned, and a later IdP activation lifts what an operator
  put there.

  Neither is repairable from the data — nothing recorded WHICH connection
  deprovisioned, and nothing distinguishes a manual hold from a directory one once
  it is stamped. So this takes the conservative side of both: unless exactly one
  candidate exists, the hold stops being the directory's. `disabled_at` is
  untouched, because the member is still out; what changes is that a human can
  release them, instead of an authority nobody can identify.
  """
  use Ecto.Migration

  def up do
    execute """
    WITH candidates AS (
      SELECT m.id AS membership_id, count(*) AS n
      FROM account_memberships m
      JOIN sso_user_identities i
        ON i.user_id = m.user_id
       AND i.account_id = m.account_id
       AND i.deleted_at IS NULL
       AND i.scim_active = false
      JOIN sso_identity_providers p
        ON p.id = i.provider_id
       AND p.deleted_at IS NULL
       AND p.scim_enabled = true
      WHERE m.directory_suspended = true
        AND m.deleted_at IS NULL
      GROUP BY m.id
    )
    UPDATE account_memberships m
    SET directory_suspended = false,
        directory_provider_id = NULL,
        updated_at = now()
    FROM candidates c
    WHERE c.membership_id = m.id
      AND c.n > 1
    """
  end

  # No down. Handing a hold back to operators is the safe direction; re-attaching
  # it to a connection nobody can prove owns it is what this exists to undo.
  def down, do: :ok
end
