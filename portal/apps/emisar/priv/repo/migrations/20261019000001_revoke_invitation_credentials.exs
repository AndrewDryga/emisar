defmodule Emisar.Repo.Migrations.RevokeInvitationCredentials do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 500

  # Historical rows predate the accepted/pending authorization boundary. Their
  # timestamps came from different application nodes, so no wall-clock
  # comparison can prove a credential was minted after acceptance. Revoke every
  # live credential attached to a pending or token-accepted membership once;
  # accepted operators can mint a replacement from the now-authorized seat.
  @api_key_repair_sql """
  WITH candidates AS (
    SELECT api_key.id
    FROM api_keys AS api_key
    INNER JOIN account_memberships AS membership
      ON membership.id = api_key.created_by_membership_id
    WHERE (membership.invitation_accepted_at IS NOT NULL
           OR membership.invitation_token_digest IS NOT NULL)
      AND api_key.deleted_at IS NULL
      AND api_key.revoked_at IS NULL
    ORDER BY api_key.id
    LIMIT #{@batch_size}
    FOR UPDATE OF api_key
  )
  UPDATE api_keys AS api_key
  SET revoked_at = now(),
      updated_at = now()
  FROM candidates
  WHERE api_key.id = candidates.id
  RETURNING api_key.id
  """

  @device_grant_repair_sql """
  WITH candidates AS (
    SELECT device_grant.id
    FROM api_key_device_grants AS device_grant
    INNER JOIN account_memberships AS membership
      ON membership.id = device_grant.approved_by_membership_id
    WHERE (membership.invitation_accepted_at IS NOT NULL
           OR membership.invitation_token_digest IS NOT NULL)
      AND device_grant.status = 'approved'
    ORDER BY device_grant.id
    LIMIT #{@batch_size}
    FOR UPDATE OF device_grant
  )
  UPDATE api_key_device_grants AS device_grant
  SET status = 'denied',
      updated_at = now()
  FROM candidates
  WHERE device_grant.id = candidates.id
  RETURNING device_grant.id
  """

  @doc false
  def api_key_repair_sql, do: @api_key_repair_sql

  @doc false
  def device_grant_repair_sql, do: @device_grant_repair_sql

  def up do
    create index(:api_key_device_grants, [:approved_by_membership_id], concurrently: true)

    flush()

    execute(fn ->
      repair_in_batches(@api_key_repair_sql)
      repair_in_batches(@device_grant_repair_sql)
    end)
  end

  def down do
    raise "credentials invalid before invitation acceptance cannot be restored safely"
  end

  defp repair_in_batches(sql) do
    case repo().query!(sql, [], log: :info).num_rows do
      0 -> :ok
      _count -> repair_in_batches(sql)
    end
  end
end
