defmodule Emisar.ApiKeys.ApiKey.Query do
  use Emisar, :query

  def all,
    do: from(api_keys in Emisar.ApiKeys.ApiKey, as: :api_keys)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [api_keys: k], k.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [api_keys: k], k.account_id == ^account_id)

  @doc """
  Hides auto-generated keys until an LLM has authenticated with one.
  Auto-unused entries stay invisible to operator-facing surfaces.
  """
  def visible_to_operators(queryable \\ not_deleted()) do
    where(queryable, [api_keys: k], is_nil(k.auto_generated_at) or not is_nil(k.last_used_at))
  end

  def ordered_by_recent(queryable \\ not_deleted()),
    do: order_by(queryable, [api_keys: k], desc: k.inserted_at)

  def by_key_prefix(queryable \\ all(), prefix),
    do: where(queryable, [api_keys: k], k.key_prefix == ^prefix)

  @doc """
  Restricts to keys that carry the given scope. Uses Postgres array
  containment so the index on `scopes` (if added later) covers it.
  """
  def with_scope(queryable \\ all(), scope) when is_binary(scope),
    do: where(queryable, [api_keys: k], fragment("? = ANY(?)", ^scope, k.scopes))

  @doc """
  Restricts to keys that do NOT carry the given scope. Used to keep
  audit-export tokens (audit:read) out of the LLM-bridge agents list.
  """
  def without_scope(queryable \\ all(), scope) when is_binary(scope),
    do: where(queryable, [api_keys: k], fragment("NOT (? = ANY(?))", ^scope, k.scopes))

  @doc """
  Auto-generated keys that no LLM has ever authenticated with — the
  pool that ring eviction draws from.
  """
  def auto_unused(queryable \\ not_deleted()) do
    where(queryable, [api_keys: k], not is_nil(k.auto_generated_at) and is_nil(k.last_used_at))
  end

  @doc """
  Rows to drop when the per-account ring of auto-unused keys overflows
  `cap`: any auto-unused key that is BOTH beyond the `cap` newest AND
  was minted before `protected_floor` (anything within the grace
  window is preserved so a freshly-pasted snippet never disappears
  before the LLM gets a chance to bind).
  """
  def evictable_quick_overflow(account_id, cap, protected_floor) do
    overflow_ids =
      auto_unused()
      |> by_account_id(account_id)
      |> order_by([api_keys: k], desc: k.auto_generated_at)
      |> offset(^cap)
      |> select([api_keys: k], k.id)

    all()
    |> by_account_id(account_id)
    |> where(
      [api_keys: k],
      k.id in subquery(overflow_ids) and k.auto_generated_at < ^protected_floor
    )
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([api_keys: k], k.id in ^ids)
    |> select([api_keys: k], {k.id, field(k, ^field)})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:api_keys, :desc, :inserted_at}, {:api_keys, :asc, :id}]
end
