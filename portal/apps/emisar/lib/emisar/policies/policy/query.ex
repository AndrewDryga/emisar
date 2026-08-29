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

  @doc """
  Rulesets whose target a member's runner access reaches — one of the runner ids
  or group names given. The account default names no host and is always in
  reach; compose `scoped_overrides/1` to drop it where only overrides belong.
  """
  def by_scope_reach(queryable, runner_ids, groups)
      when is_list(runner_ids) and is_list(groups) do
    where(
      queryable,
      [policies: p],
      p.scope_type == :account or
        (p.scope_type == :runner and p.scope_value in ^runner_ids) or
        (p.scope_type == :group and p.scope_value in ^groups)
    )
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

  # Group overrides before runner overrides (enum string order), stable within
  # a type by scope_value so the editor list doesn't jump around.
  def ordered_by_scope(queryable),
    do: order_by(queryable, [policies: p], asc: p.scope_type, asc: p.scope_value)

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
