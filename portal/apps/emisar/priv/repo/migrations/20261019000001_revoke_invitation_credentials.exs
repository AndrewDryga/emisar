defmodule Emisar.Repo.Migrations.RevokeInvitationCredentials do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  @batch_size 500

  # Historical rows predate the accepted/pending authorization boundary. A
  # credential attached to a still-pending invitation was never authorized and
  # goes. A credential minted by a member who later ACCEPTED is revoked only
  # when it predates that acceptance — with a five-minute margin, because the
  # two timestamps came from different application nodes and a key minted "one
  # minute after" acceptance on a skewed clock may really have been minted
  # before it. Keys minted by an accepted seat after that window are that
  # seat's legitimate credentials and stay.
  #
  # Every revocation writes the same customer-visible audit row the console
  # would (`api_key.revoked` / `api_key.device_grant_denied`, system actor), so
  # an operator whose client starts getting 401s finds the reason in the trail.
  # The retention horizon mirrors what `Emisar.Audit` stamps from the plan; the
  # map is inlined rather than calling the application so this frozen migration
  # never depends on a module that may move.
  @retention_days_sql """
  CASE
    WHEN subscription.id IS NULL THEN 7
    WHEN subscription.status NOT IN ('active', 'trialing', 'past_due', 'complimentary') THEN 7
    WHEN (subscription.entitlements ->> 'audit_retention_days') ~ '^[1-9][0-9]*$'
      THEN (subscription.entitlements ->> 'audit_retention_days')::int
    WHEN subscription.plan = 'free' THEN 7
    WHEN subscription.plan = 'team' THEN 90
    WHEN subscription.plan = 'enterprise' THEN 365
    ELSE 365
  END
  """

  @api_key_repair_sql """
  WITH candidates AS (
    SELECT api_key.id
    FROM api_keys AS api_key
    INNER JOIN account_memberships AS membership
      ON membership.id = api_key.created_by_membership_id
    WHERE api_key.deleted_at IS NULL
      AND api_key.revoked_at IS NULL
      AND ((membership.invitation_accepted_at IS NULL
            AND membership.invitation_token_digest IS NOT NULL)
           OR api_key.inserted_at < membership.invitation_accepted_at + interval '5 minutes')
    ORDER BY api_key.id
    LIMIT #{@batch_size}
    FOR UPDATE OF api_key
  ),
  revoked AS (
    UPDATE api_keys AS api_key
    SET revoked_at = now(),
        updated_at = now()
    FROM candidates
    WHERE api_key.id = candidates.id
    RETURNING api_key.id, api_key.account_id, api_key.key_prefix, api_key.name
  )
  INSERT INTO audit_events
    (id, account_id, occurred_at, retain_until, event_type, actor_kind,
     target_kind, target_id, target_label, payload, inserted_at)
  SELECT uuidv7(),
         revoked.account_id,
         now(),
         now() + (#{@retention_days_sql}) * interval '1 day',
         'api_key.revoked',
         'system',
         'api_key',
         revoked.id,
         revoked.name,
         jsonb_build_object('prefix', revoked.key_prefix,
                            'reason', 'minted_before_invitation_acceptance'),
         now()
  FROM revoked
  LEFT JOIN billing_subscriptions AS subscription
    ON subscription.account_id = revoked.account_id
  RETURNING id
  """

  # A grant carries no approval timestamp of its own; approval is the write
  # that last touched the row, so `updated_at` stands in for it.
  @device_grant_repair_sql """
  WITH candidates AS (
    SELECT device_grant.id
    FROM api_key_device_grants AS device_grant
    INNER JOIN account_memberships AS membership
      ON membership.id = device_grant.approved_by_membership_id
    WHERE device_grant.status = 'approved'
      AND ((membership.invitation_accepted_at IS NULL
            AND membership.invitation_token_digest IS NOT NULL)
           OR device_grant.updated_at < membership.invitation_accepted_at + interval '5 minutes')
    ORDER BY device_grant.id
    LIMIT #{@batch_size}
    FOR UPDATE OF device_grant
  ),
  denied AS (
    UPDATE api_key_device_grants AS device_grant
    SET status = 'denied',
        updated_at = now()
    FROM candidates
    WHERE device_grant.id = candidates.id
    RETURNING device_grant.id, device_grant.account_id, device_grant.requested_clients,
              device_grant.requester_ip
  )
  INSERT INTO audit_events
    (id, account_id, occurred_at, retain_until, event_type, actor_kind,
     target_kind, target_id, target_label, payload, inserted_at)
  SELECT uuidv7(),
         denied.account_id,
         now(),
         now() + (#{@retention_days_sql}) * interval '1 day',
         'api_key.device_grant_denied',
         'system',
         'device_grant',
         denied.id,
         array_to_string(denied.requested_clients, ', '),
         jsonb_build_object('requested_clients', to_jsonb(denied.requested_clients),
                            'requester_ip', denied.requester_ip,
                            'reason', 'approved_before_invitation_acceptance'),
         now()
  FROM denied
  LEFT JOIN billing_subscriptions AS subscription
    ON subscription.account_id = denied.account_id
  RETURNING id
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
