defmodule Emisar.ApiKeys.ApiKey.Query do
  use Emisar, :query

  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(api_keys in Emisar.ApiKeys.ApiKey, as: :api_keys)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [api_keys: k], k.id == ^id)

  @doc "Selects only the creator's user id — for the approval gate's owner lookup."
  def select_created_by_id(queryable),
    do: select(queryable, [api_keys: k], k.created_by_id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [api_keys: k], k.account_id == ^account_id)

  def by_created_by_membership_id(queryable, membership_id),
    do: where(queryable, [api_keys: k], k.created_by_membership_id == ^membership_id)

  def not_revoked(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.revoked_at))

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
  Restricts to keys of a given `kind` (`:mcp` LLM-bridge keys vs
  `:audit_export` SIEM tokens) — the type split behind the agents-page
  and audit-page lists.
  """
  def by_kind(queryable \\ all(), kind) when is_atom(kind),
    do: where(queryable, [api_keys: k], k.kind == ^kind)

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

  @doc "Left-join + preload the key's (non-deleted) creating user, idempotently."
  def with_preloaded_created_by(queryable) do
    queryable
    |> with_named_binding(:created_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [api_keys: k],
        created_by in ^Emisar.Users.User.Query.not_deleted(),
        on: k.created_by_id == created_by.id,
        as: ^binding
      )
    end)
    |> preload([created_by: created_by], created_by: created_by)
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:api_keys, :desc, :inserted_at}, {:api_keys, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads, do: []

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :name,
        title: "Name contains",
        type: :string,
        fun: fn queryable, name ->
          {queryable, dynamic([api_keys: k], ilike(k.name, ^Like.contains(name)))}
        end
      },
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [{"live", "Live"}, {"revoked", "Revoked"}],
        fun: fn queryable, statuses -> {queryable, status_dynamic(statuses)} end
      },
      # Filter by who created the key. `values` are filled in by the LiveView
      # from `owner_options/1` (only owners who actually have keys).
      %Filter{
        name: :owner,
        title: "Owner",
        type: {:list, :string},
        values: [],
        fun: fn queryable, ids -> {queryable, dynamic([api_keys: k], k.created_by_id in ^ids)} end
      }
    ]

  @doc """
  Distinct `{user_id, email}` options for the agents "Owner" filter — the users
  who created a still-visible key in the account. Compose with `for_subject/2`.
  """
  def owner_options(queryable \\ visible_to_operators()) do
    queryable
    |> join(:inner, [api_keys: k], u in assoc(k, :created_by), as: :owner)
    |> distinct(true)
    |> select([owner: u], {u.id, u.email})
  end

  defp status_dynamic(statuses) do
    cond do
      "live" in statuses and "revoked" in statuses -> dynamic(true)
      "live" in statuses -> dynamic([api_keys: k], is_nil(k.revoked_at))
      "revoked" in statuses -> dynamic([api_keys: k], not is_nil(k.revoked_at))
      true -> dynamic(true)
    end
  end
end
