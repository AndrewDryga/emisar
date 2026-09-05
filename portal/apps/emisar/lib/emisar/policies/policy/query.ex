defmodule Emisar.Policies.Policy.Query do
  use Emisar, :query

  def all,
    do: from(policies in Emisar.Policies.Policy, as: :policies)

  def none(queryable), do: where(queryable, false)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [policies: p], is_nil(p.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [policies: p], p.id == ^id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def by_account_id(queryable, account_id),
    do: where(queryable, [policies: p], p.account_id == ^account_id)

  def account_scope(queryable),
    do: where(queryable, [policies: p], p.scope_type == :account)

  # Non-account scopes (runner/group overrides) — the list the policy editor
  # shows alongside the account default.
  def scoped_overrides(queryable),
    do: where(queryable, [policies: p], p.scope_type != :account)

  def select_summary(queryable) do
    select(queryable, [policies: p], %{
      id: p.id,
      scope_type: fragment("?::text", p.scope_type),
      scope_value: p.scope_value,
      vsn: p.vsn,
      updated_at: p.updated_at
    })
  end

  def select_scope(queryable),
    do: select(queryable, [policies: p], map(p, [:scope_type, :scope_value]))

  def cursor_fields,
    do: [{:policies, :asc, :scope_type}, {:policies, :asc, :scope_value}, {:policies, :asc, :id}]

  def by_scope_targets(queryable, targets) do
    reachable =
      from(t in subquery(targets),
        where:
          t.scope_type == parent_as(:policies).scope_type and
            t.scope_value == parent_as(:policies).scope_value,
        select: 1
      )

    where(queryable, exists(subquery(reachable)))
  end

  def by_scope(queryable, scope_type, scope_value) do
    where(
      queryable,
      [policies: p],
      p.scope_type == ^scope_type and p.scope_value == ^scope_value
    )
  end

  # The candidate set for a dispatch to `runner_id` (in `group`): the account
  # default plus any policy scoped to that exact runner or group. The context
  # picks the most specific (runner > group > account) from the ≤3 rows.
  def resolvable_for(queryable, runner_id, group) do
    where(
      queryable,
      [policies: p],
      p.scope_type == :account or
        (p.scope_type == :runner and p.scope_value == ^to_string(runner_id)) or
        (p.scope_type == :group and p.scope_value == ^to_string(group))
    )
  end

  def resolvable_for_many(queryable, runner_ids, groups)
      when is_list(runner_ids) and is_list(groups) do
    runner_ids = Enum.map(runner_ids, &to_string/1)
    groups = Enum.map(groups, &to_string/1)

    where(
      queryable,
      [policies: p],
      p.scope_type == :account or
        (p.scope_type == :runner and p.scope_value in ^runner_ids) or
        (p.scope_type == :group and p.scope_value in ^groups)
    )
  end

  @doc "Audit label-lookup helper for policy targets."
  def select_audit_labels(queryable, ids) do
    queryable
    |> where([policies: p], p.id in ^ids)
    |> select([policies: p], {p.id, p.scope_type, p.scope_value})
  end

  @doc """
  ON CONFLICT update for the one-policy-per-(account, scope) rules upsert.
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
