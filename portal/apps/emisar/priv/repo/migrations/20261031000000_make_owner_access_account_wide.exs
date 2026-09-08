defmodule Emisar.Repo.Migrations.MakeOwnerAccessAccountWide do
  use Ecto.Migration

  def up do
    # Fence membership and scope writers before touching rows. Existing agent
    # credentials stay valid and inherit the normalized account-wide access.
    # A busy writer aborts this migration without changes; retry when those
    # transactions finish instead of waiting with an incomplete lock set.
    execute "LOCK TABLE accounts, account_memberships, user_runner_scopes IN EXCLUSIVE MODE NOWAIT"

    execute """
    CREATE TEMP TABLE owner_access_changes ON COMMIT DROP AS
    SELECT m.id, m.account_id, m.user_id,
      jsonb_build_object(
        'mode', m.runner_access_mode,
        'groups', COALESCE((SELECT jsonb_agg(s.scope_value ORDER BY s.scope_value)
          FROM user_runner_scopes s WHERE s.membership_id = m.id AND s.scope_type = 'group'), '[]'::jsonb),
        'runner_ids', COALESCE((SELECT jsonb_agg(s.scope_value ORDER BY s.scope_value)
          FROM user_runner_scopes s WHERE s.membership_id = m.id AND s.scope_type = 'runner'), '[]'::jsonb),
        'pack_mode', m.pack_access_mode,
        'pack_ids', to_jsonb(m.pack_scope_pack_ids)
      ) AS before_access
    FROM account_memberships m
    WHERE m.deleted_at IS NULL AND m.role = 'owner'
      AND (m.runner_access_mode <> 'all' OR m.pack_access_mode <> 'all'
        OR cardinality(m.pack_scope_pack_ids) <> 0
        OR EXISTS (SELECT 1 FROM user_runner_scopes s WHERE s.membership_id = m.id))
    """

    execute "SELECT set_config('emisar.runner_access_write', 'enabled', true)"

    execute """
    DELETE FROM user_runner_scopes s USING owner_access_changes m WHERE s.membership_id = m.id
    """

    execute """
    UPDATE account_memberships m
    SET runner_access_mode = 'all', pack_access_mode = 'all',
        pack_scope_pack_ids = '{}', updated_at = now()
    FROM owner_access_changes changed WHERE changed.id = m.id
    """

    execute "SELECT set_config('emisar.runner_access_write', 'disabled', true)"

    # Snapshot Billing's current retention contract; historical migrations must
    # not call a context whose schema or lifecycle rules can change later.
    execute """
    WITH subscriptions AS (
      SELECT s.*,
        COALESCE(s.scheduled_change_action, CASE WHEN s.cancel_at_period_end THEN 'cancel' END) AS action,
        COALESCE(s.scheduled_change_effective_at, CASE WHEN s.cancel_at_period_end THEN s.current_period_end END) AS effective_at
      FROM billing_subscriptions s
    ), postures AS (
      SELECT s.*,
        CASE
          WHEN s.status = 'complimentary' THEN 'active'
          WHEN s.status IN ('paused', 'canceled') THEN 'expired'
          WHEN s.status NOT IN ('active', 'trialing', 'past_due') OR s.status IS NULL THEN 'unresolved'
          WHEN s.status = 'past_due' AND s.collection_mode IS DISTINCT FROM 'automatic' THEN 'unresolved'
          WHEN s.action IS NULL THEN 'active'
          WHEN s.action IN ('cancel', 'pause') AND s.effective_at IS NOT NULL
            THEN CASE WHEN now() < s.effective_at THEN 'active' ELSE 'expired' END
          ELSE 'unresolved'
        END AS state
      FROM subscriptions s
    ), retention AS (
      SELECT changed.*,
        CASE
          WHEN p.state = 'unresolved' THEN 365
          WHEN p.state = 'active' THEN
            CASE
              WHEN jsonb_typeof(p.entitlements->'audit_retention_days') = 'number'
                AND (p.entitlements->>'audit_retention_days') ~ '^[1-9][0-9]*$'
                THEN (p.entitlements->>'audit_retention_days')::integer
              WHEN p.plan = 'enterprise' THEN 365
              WHEN p.plan = 'team' THEN 90
              WHEN p.plan = 'free' OR p.plan IS NULL THEN 7
              ELSE 365
            END
          ELSE 7
        END AS days
      FROM owner_access_changes changed
      LEFT JOIN postures p ON p.account_id = changed.account_id
    )
    INSERT INTO audit_events
      (id, account_id, occurred_at, inserted_at, retain_until, event_type,
       actor_kind, target_kind, target_id, payload)
    SELECT gen_random_uuid(), account_id, now(), now(), now() + days * interval '1 day',
      'membership.runner_access_changed', 'system', 'user', user_id,
      jsonb_build_object(
        'membership_id', id, 'reason', 'owner_access_account_wide',
        'before', before_access,
        'after', jsonb_build_object('mode', 'all', 'groups', '[]'::jsonb, 'runner_ids', '[]'::jsonb,
          'pack_mode', 'all', 'pack_ids', '[]'::jsonb)
      )
    FROM retention
    """

    create constraint(:account_memberships, :account_memberships_owner_access_check,
             check:
               "deleted_at IS NOT NULL OR role <> 'owner' OR (runner_access_mode = 'all' AND pack_access_mode = 'all' AND cardinality(pack_scope_pack_ids) = 0)"
           )
  end

  def down do
    # Do not reconstruct narrower grants on rollback.
    drop constraint(:account_memberships, :account_memberships_owner_access_check)
  end
end
