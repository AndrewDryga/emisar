defmodule Emisar.ApiKeys.ApiKey.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(api_keys in Emisar.ApiKeys.ApiKey, as: :api_keys)

  def none(queryable), do: where(queryable, false)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [api_keys: k], k.id == ^id)

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [api_keys: k], k.id in ^ids)

  @doc "Selects only the creator's user id — for the approval gate's owner lookup."
  def select_created_by_id(queryable),
    do: select(queryable, [api_keys: k], k.created_by_id)

  @doc "Selects only the key ids — for the OAuth cleanup's stale-backing-key lookup."
  def select_ids(queryable),
    do: select(queryable, [api_keys: k], k.id)

  @doc "Selects `{key_id, last_used_at}` for the Agents page's bounded activity poll."
  def select_usage_timestamps(queryable),
    do: select(queryable, [api_keys: k], {k.id, k.last_used_at})

  def by_account_id(queryable, account_id),
    do: where(queryable, [api_keys: k], k.account_id == ^account_id)

  def by_created_by_membership_id(queryable, membership_id),
    do: where(queryable, [api_keys: k], k.created_by_membership_id == ^membership_id)

  def rotation_children(queryable, replaced_ids, rotated_to_ids)
      when is_list(replaced_ids) and is_list(rotated_to_ids) do
    where(
      queryable,
      [api_keys: k],
      k.replaces_id in ^replaced_ids or k.id in ^rotated_to_ids
    )
  end

  def not_revoked(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.revoked_at))

  def not_rotated(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.rotated_to_id))

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

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
  OAuth backing keys — non-expiring MCP keys. Consent mints these with no expiry
  (`ApiKeys.create_backing_key/4`) because OAuth owns their lifecycle, while every
  operator-minted MCP key carries one — so `:mcp` + no `expires_at` uniquely marks
  an OAuth-backed connection.
  """
  def oauth_backing(queryable \\ all()),
    do: where(queryable, [api_keys: k], k.kind == :mcp and is_nil(k.expires_at))

  def never_used(queryable \\ all()),
    do: where(queryable, [api_keys: k], is_nil(k.last_used_at))

  def inserted_before(queryable \\ all(), cutoff),
    do: where(queryable, [api_keys: k], k.inserted_at < ^cutoff)

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

  @doc """
  Audit owner-label lookup: `{key_id, owner label}` for `ids`, naming the
  accountable HUMAN behind an API-key/MCP actor the way `account_id` knows
  them. Joins the key's EXACT minting membership — another membership of the
  same person never stands in — so the label follows that account's directory
  name, then the user's own name, then their email. INNER joins throughout: a
  key whose minting membership is gone, suspended, or in another account (or
  whose user was deleted) resolves no row, and the trail degrades to the key
  name.
  """
  def select_owner_labels(queryable, ids, account_id) do
    owner_membership =
      Emisar.Accounts.Membership.Query.not_deleted()
      |> Emisar.Accounts.Membership.Query.not_disabled()
      |> Emisar.Accounts.Membership.Query.by_account_id(account_id)

    queryable
    |> where([api_keys: k], k.id in ^ids)
    |> join(:inner, [api_keys: k], m in ^owner_membership,
      on: m.id == k.created_by_membership_id,
      as: :owner_membership
    )
    |> join(:inner, [owner_membership: m], u in ^Emisar.Users.User.Query.not_deleted(),
      on: u.id == m.user_id,
      as: :owner
    )
    |> select(
      [api_keys: k, owner_membership: m, owner: u],
      {k.id,
       coalesce(
         fragment("NULLIF(BTRIM(?), '')", m.directory_display_name),
         coalesce(fragment("NULLIF(BTRIM(?), '')", u.full_name), u.email)
       )}
    )
  end

  @doc """
  Preload the (non-deleted) key this one replaced at rotation. A separate
  query, not a self-join — the `replaces` assoc's own `where` scopes it.
  """
  def with_preloaded_replaces(queryable), do: preload(queryable, :replaces)

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
        title: "Name",
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
        # Default to live keys — the connected-agents view shouldn't be cluttered
        # with dead credentials; because it's the DEFAULT, LiveTable renders it
        # un-highlighted. Operators opt into revoked (or "All") explicitly.
        default: "live",
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

  @doc """
  `{key_id, name}` options for the runs "Agent" filter — the keys themselves,
  as pickable choices. Compose with `for_subject/2`.
  """
  def options(queryable \\ visible_to_operators()),
    do: select(queryable, [api_keys: k], {k.id, k.name})

  defp status_dynamic(statuses) do
    cond do
      "live" in statuses and "revoked" in statuses -> dynamic(true)
      "live" in statuses -> dynamic([api_keys: k], is_nil(k.revoked_at))
      "revoked" in statuses -> dynamic([api_keys: k], not is_nil(k.revoked_at))
      true -> dynamic(true)
    end
  end
end
