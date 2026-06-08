defmodule Emisar.Runners.AuthKey.Query do
  use Emisar, :query

  alias Emisar.Repo.Filter

  def all,
    do: from(auth_keys in Emisar.Runners.AuthKey, as: :auth_keys)

  def not_deleted(q \\ all()),
    do: where(q, [auth_keys: k], is_nil(k.deleted_at))

  def by_id(q, id),
    do: where(q, [auth_keys: k], k.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [auth_keys: k], k.account_id == ^account_id)

  @doc """
  Hides auto-generated keys until they've been bound to a runner.
  Auto-unused entries stay invisible to operator-facing surfaces.
  """
  def visible_to_operators(q \\ not_deleted()) do
    where(q, [auth_keys: k], is_nil(k.auto_generated_at) or not is_nil(k.last_used_at))
  end

  def ordered_by_recent(q \\ not_deleted()),
    do: order_by(q, [auth_keys: k], desc: k.inserted_at)

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        # Single-select dropdown (LiveTable adds the "All" option that clears
        # the filter). The list shape lets a value arrive as ["active"].
        values: [
          {"active", "Active"},
          {"revoked", "Revoked"}
        ],
        fun: fn q, statuses ->
          dyn =
            cond do
              "active" in statuses and "revoked" in statuses -> dynamic([auth_keys: k], true)
              "revoked" in statuses -> dynamic([auth_keys: k], not is_nil(k.revoked_at))
              "active" in statuses -> dynamic([auth_keys: k], is_nil(k.revoked_at))
              true -> dynamic([auth_keys: k], true)
            end

          {q, dyn}
        end
      }
    ]

  def by_key_prefix(q \\ all(), prefix),
    do: where(q, [auth_keys: k], k.key_prefix == ^prefix)

  @doc "Auto-generated keys no runner has consumed yet — the eviction pool."
  def auto_unused(q \\ not_deleted()),
    do: where(q, [auth_keys: k], not is_nil(k.auto_generated_at) and is_nil(k.last_used_at))

  @doc "Install-key ring overflow. Matches the api_key variant — see ApiKey.Query."
  def evictable_install_overflow(account_id, cap, protected_floor) do
    overflow_ids =
      auto_unused()
      |> by_account_id(account_id)
      |> order_by([auth_keys: k], desc: k.auto_generated_at)
      |> offset(^cap)
      |> select([auth_keys: k], k.id)

    all()
    |> by_account_id(account_id)
    |> where(
      [auth_keys: k],
      k.id in subquery(overflow_ids) and k.auto_generated_at < ^protected_floor
    )
  end

  @doc """
  WHERE clause for `consume_auth_key/1`'s conditional UPDATE: matches
  only rows whose every `usable?` condition still holds. The check
  happens at SQL level so two concurrent registrations can't both
  decrement a single-use key.
  """
  def consumable_by_id(id, now) do
    all()
    |> where([auth_keys: k], k.id == ^id)
    |> where([auth_keys: k], is_nil(k.revoked_at))
    |> where([auth_keys: k], is_nil(k.deleted_at))
    |> where([auth_keys: k], is_nil(k.expires_at) or k.expires_at > ^now)
    |> where(
      [auth_keys: k],
      (k.reusable and (is_nil(k.max_uses) or k.uses_count < k.max_uses)) or
        (not k.reusable and k.uses_count == 0)
    )
  end

  @doc """
  Charge one consumption (`inc: uses_count, set: last_used_at`,
  clearing `auto_generated_at` so the key is no longer eligible for
  ring eviction).
  """
  def consume_one(q, now) do
    update(q,
      inc: [uses_count: 1],
      set: [last_used_at: ^now, updated_at: ^now, auto_generated_at: nil]
    )
  end

  @doc "Audit label-lookup helper. See Accounts.User.Query.select_labels/3."
  def select_labels(q, ids, field) do
    q
    |> where([auth_keys: k], k.id in ^ids)
    |> select([auth_keys: k], {k.id, field(k, ^field)})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:auth_keys, :desc, :inserted_at}, {:auth_keys, :asc, :id}]
end
