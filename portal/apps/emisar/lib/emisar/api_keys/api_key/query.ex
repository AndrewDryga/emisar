defmodule Emisar.ApiKeys.ApiKey.Query do
  use Emisar, :query

  def all,
    do: from(api_keys in Emisar.ApiKeys.ApiKey, as: :api_keys)

  def not_deleted(q \\ all()),
    do: where(q, [api_keys: k], is_nil(k.deleted_at))

  def by_id(q, id),
    do: where(q, [api_keys: k], k.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [api_keys: k], k.account_id == ^account_id)

  @doc """
  Hides auto-generated keys until an LLM has authenticated with one.
  Auto-unused entries stay invisible to operator-facing surfaces.
  """
  def visible_to_operators(q \\ not_deleted()) do
    where(q, [api_keys: k], is_nil(k.auto_generated_at) or not is_nil(k.last_used_at))
  end

  def ordered_by_recent(q \\ not_deleted()),
    do: order_by(q, [api_keys: k], desc: k.inserted_at)

  def by_key_prefix(q \\ all(), prefix),
    do: where(q, [api_keys: k], k.key_prefix == ^prefix)

  @doc """
  Restricts to keys that carry the given scope. Uses Postgres array
  containment so the index on `scopes` (if added later) covers it.
  """
  def with_scope(q \\ all(), scope) when is_binary(scope),
    do: where(q, [api_keys: k], fragment("? = ANY(?)", ^scope, k.scopes))

  @doc """
  Restricts to keys that do NOT carry the given scope. Used to keep
  audit-export tokens (audit:read) out of the LLM-bridge agents list.
  """
  def without_scope(q \\ all(), scope) when is_binary(scope),
    do: where(q, [api_keys: k], fragment("NOT (? = ANY(?))", ^scope, k.scopes))

  @doc """
  Auto-generated keys that no LLM has ever authenticated with — the
  pool that ring eviction draws from.
  """
  def auto_unused(q \\ not_deleted()),
    do: where(q, [api_keys: k], not is_nil(k.auto_generated_at) and is_nil(k.last_used_at))

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

  @doc "Audit label-lookup helper. See Accounts.User.Query.select_labels/3."
  def select_labels(q, ids, field) do
    q
    |> where([api_keys: k], k.id in ^ids)
    |> select([api_keys: k], {k.id, field(k, ^field)})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:api_keys, :desc, :inserted_at}, {:api_keys, :asc, :id}]
end
