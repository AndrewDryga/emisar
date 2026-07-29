defmodule Emisar.Repo.Migrations.TrackWhenADirectoryLastPushedGroups do
  @moduledoc """
  Roles are recomputed from the group snapshot, and an identity in no mapped
  group falls back to the connection's `default_role`. That rule cannot tell
  "this person is in no groups" from "no groups have arrived yet" — and the two
  are indistinguishable right after directory sync is re-enabled, because
  disabling it discards the snapshot.

  So an IdP that re-POSTs Users before Groups — nothing in SCIM orders them —
  recomputed every member against an empty snapshot: revoking a group grant that
  was still valid, or, where the default outranks the mapping, raising someone
  the directory never authorized. No Group operation was involved either way.

  `scim_groups_synced_at` records the first group push since sync was enabled.
  Until one arrives there is no snapshot to reason from, and the recompute
  leaves memberships alone rather than acting on an absence of information.

  Existing SCIM connections are backfilled from whether they hold any group
  membership rows: a connection with a live snapshot has plainly been pushed to.
  """
  use Ecto.Migration

  def up do
    alter table(:sso_identity_providers) do
      add :scim_groups_synced_at, :utc_datetime_usec
    end

    execute """
    UPDATE sso_identity_providers p
    SET scim_groups_synced_at = now()
    WHERE p.scim_enabled = true
      AND EXISTS (
        SELECT 1
        FROM sso_directory_group_members g
        WHERE g.provider_id = p.id
          AND g.deleted_at IS NULL
      )
    """
  end

  def down do
    alter table(:sso_identity_providers) do
      remove :scim_groups_synced_at
    end
  end
end
