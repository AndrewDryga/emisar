defmodule Emisar.Policies.Target.Query do
  @moduledoc false
  use Emisar, :query
  alias Emisar.Repo.Like

  def all(targets) do
    from(t in subquery(targets), as: :policy_targets)
  end

  def by_account_id(query, account_id),
    do: where(query, [policy_targets: t], t.account_id == ^account_id)

  def by_scope(query, scope_type, scope_value) do
    where(
      query,
      [policy_targets: t],
      t.scope_type == ^to_string(scope_type) and t.scope_value == ^scope_value
    )
  end

  def with_policy(query) do
    query
    |> join(:left, [policy_targets: t], p in Emisar.Policies.Policy,
      as: :target_policy,
      on:
        p.account_id == t.account_id and p.scope_type == t.scope_type and
          p.scope_value == t.scope_value and is_nil(p.deleted_at)
    )
    |> select([policy_targets: t, target_policy: p], %{
      account_id: t.account_id,
      scope_type: t.scope_type,
      scope_value: t.scope_value,
      group_sort: t.group_sort,
      kind_sort: t.kind_sort,
      label: t.label,
      policy_id: p.id,
      taken?: not is_nil(p.id)
    })
  end

  def available(query, reserved) do
    query = where(query, [target_policy: p], is_nil(p.id))

    Enum.reduce(reserved, query, fn {scope_type, scope_value}, query ->
      where(
        query,
        [policy_targets: t],
        not (t.scope_type == ^to_string(scope_type) and t.scope_value == ^scope_value)
      )
    end)
  end

  def search(query, ""), do: query

  def search(query, search) do
    pattern = Like.contains(search)

    where(
      query,
      [policy_targets: t],
      ilike(t.label, ^pattern) or ilike(t.group_sort, ^pattern) or ilike(t.scope_value, ^pattern)
    )
  end

  def cursor_fields,
    do: [
      {:policy_targets, :asc, :group_sort},
      {:policy_targets, :asc, :kind_sort},
      {:policy_targets, :asc, :label},
      {:policy_targets, :asc, :scope_value}
    ]
end
