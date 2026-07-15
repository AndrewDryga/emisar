defmodule Emisar.Repo.Migrations.BackfillPolicyApprovalSettings do
  use Ecto.Migration

  # Approval settings used to be optional and were defaulted at read time.
  # Materialize that legacy behavior once so future reads can reject incomplete
  # or corrupt policy JSON instead of silently choosing a permissive value.
  def up do
    execute("""
    UPDATE policies
    SET rules = CASE
      WHEN NOT (rules ? 'approval') THEN
        jsonb_set(
          rules,
          '{approval}',
          '{"min_approvals": 1, "allow_self_approval": true}'::jsonb,
          true
        )
      WHEN jsonb_typeof(rules->'approval') = 'object' THEN
        jsonb_set(
          jsonb_set(
            rules,
            '{approval,min_approvals}',
            COALESCE(rules#>'{approval,min_approvals}', '1'::jsonb),
            true
          ),
          '{approval,allow_self_approval}',
          COALESCE(rules#>'{approval,allow_self_approval}', 'true'::jsonb),
          true
        )
      ELSE rules
    END
    WHERE jsonb_typeof(rules) = 'object'
      AND (
        NOT (rules ? 'approval')
        OR rules#>'{approval,min_approvals}' IS NULL
        OR rules#>'{approval,allow_self_approval}' IS NULL
      )
    """)
  end

  # Irreversible: after the backfill there is no reliable way to distinguish a
  # legacy default from an operator who explicitly chose the same value.
  def down, do: :ok
end
