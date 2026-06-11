defmodule Emisar.Policies.Policy.Query do
  use Emisar, :query

  def all,
    do: from(policies in Emisar.Policies.Policy, as: :policies)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [policies: p], is_nil(p.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [policies: p], p.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [policies: p], p.account_id == ^account_id)

  @doc """
  ON CONFLICT update for the one-policy-per-account rules upsert.
  Adopts the incoming rules/editor/timestamp and bumps `vsn` only when
  the rules actually changed — a no-op save must not inflate the
  audit-correlation number.
  """
  def rules_upsert_conflict do
    from(policies in Emisar.Policies.Policy,
      update: [
        set: [
          rules: fragment("EXCLUDED.rules"),
          updated_by_id: fragment("EXCLUDED.updated_by_id"),
          updated_at: fragment("EXCLUDED.updated_at"),
          vsn:
            fragment(
              "CASE WHEN ? IS DISTINCT FROM EXCLUDED.rules THEN ? + 1 ELSE ? END",
              policies.rules,
              policies.vsn,
              policies.vsn
            )
        ]
      ]
    )
  end
end
