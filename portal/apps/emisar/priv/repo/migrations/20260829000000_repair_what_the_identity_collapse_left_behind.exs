defmodule Emisar.Repo.Migrations.RepairWhatTheIdentityCollapseLeftBehind do
  @moduledoc """
  Two earlier migrations are correct about what they enforce and wrong about what
  they leave behind. Both are committed, so this moves the data forward instead.

  `20260826000000` collapsed duplicate identities onto the directory-addressed
  row and soft-deleted the rest. A cookie does not care that its identity row was
  retired, and revocation enumerated only live rows — so every session minted
  through a collapsed identity became unreachable by the disable and delete paths
  meant to end it. Those sessions are revoked here, and the code now enumerates
  retired identities too.

  `20260827000000` freed memberships suspended by a directory that no longer
  exists, identifying them as `directory_suspended` with no
  `directory_provider_id`. But `sync_suspend` never stamped that column, so a
  suspension owned by a LIVE directory looked identical — and clearing the guard
  let an operator reinstate someone their IdP still says is inactive. The write
  path stamps the owner now; this restores the guard on rows whose directory is
  still here and still says no, and records which connection owns each one.
  """
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM auth_user_tokens t
    USING sso_user_identities i
    WHERE t.user_identity_id = i.id
      AND t.context = 'session'
      AND i.deleted_at IS NOT NULL
    """

    # A live identity the directory has marked inactive is proof the suspension
    # is still the directory's, whatever 20260827000000 assumed.
    execute """
    UPDATE account_memberships m
    SET directory_suspended = true,
        directory_provider_id = i.provider_id,
        updated_at = now()
    FROM sso_user_identities i
    WHERE i.user_id = m.user_id
      AND i.account_id = m.account_id
      AND i.deleted_at IS NULL
      AND i.scim_active = false
      AND m.disabled_at IS NOT NULL
      AND m.directory_suspended = false
      AND m.deleted_at IS NULL
    """

    # Suspensions that stayed marked but never recorded an owner.
    execute """
    UPDATE account_memberships m
    SET directory_provider_id = i.provider_id,
        updated_at = now()
    FROM sso_user_identities i
    WHERE i.user_id = m.user_id
      AND i.account_id = m.account_id
      AND i.deleted_at IS NULL
      AND m.directory_suspended = true
      AND m.directory_provider_id IS NULL
      AND m.deleted_at IS NULL
    """
  end

  # No down: the revoked sessions cannot be un-revoked, and re-clearing the
  # restored guards would put those members back in a state nobody can leave.
  def down, do: :ok
end
