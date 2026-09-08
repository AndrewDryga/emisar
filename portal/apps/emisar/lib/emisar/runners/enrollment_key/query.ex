defmodule Emisar.Runners.EnrollmentKey.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter
  alias Emisar.Users

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  def all,
    do: from(enrollment_keys in Emisar.Runners.EnrollmentKey, as: :enrollment_keys)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [enrollment_keys: k], is_nil(k.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [enrollment_keys: k], k.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [enrollment_keys: k], k.account_id == ^account_id)

  def ordered_by_recent(queryable \\ not_deleted()),
    do: order_by(queryable, [enrollment_keys: k], desc: k.inserted_at)

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        span: :half,
        # Single-select dropdown (LiveTable adds the "All" option that clears
        # the filter). The list shape lets a value arrive as ["active"].
        # Fresh visits show usable keys by default; the default renders as the
        # BASELINE, never as an applied filter (design-console-ux §7.4).
        default: "active",
        values: [
          {"active", "Active"},
          {"revoked", "Revoked"}
        ],
        fun: fn queryable, statuses ->
          usable = usable_condition(DateTime.utc_now())

          dyn =
            cond do
              "active" in statuses and "revoked" in statuses ->
                dynamic([enrollment_keys: k], ^usable or not is_nil(k.revoked_at))

              "revoked" in statuses ->
                dynamic([enrollment_keys: k], not is_nil(k.revoked_at))

              "active" in statuses ->
                usable

              true ->
                dynamic([enrollment_keys: k], true)
            end

          {queryable, dyn}
        end
      },
      %Filter{
        name: :source,
        title: "Source",
        type: {:list, :string},
        span: :half,
        default: "",
        values: [{"manual", "Created manually"}, {"console", "Runner setup"}],
        fun: fn queryable, sources ->
          condition =
            case Enum.uniq(sources) do
              ["manual"] -> dynamic([enrollment_keys: k], is_nil(k.auto_generated_at))
              ["console"] -> dynamic([enrollment_keys: k], not is_nil(k.auto_generated_at))
              _ -> dynamic([enrollment_keys: k], true)
            end

          {queryable, condition}
        end
      }
    ]

  def by_key_prefix(queryable \\ all(), prefix),
    do: where(queryable, [enrollment_keys: k], k.key_prefix == ^prefix)

  @doc "Auto-generated keys no runner has consumed yet — the eviction pool."
  def auto_unused(queryable \\ not_deleted()) do
    where(
      queryable,
      [enrollment_keys: k],
      not is_nil(k.auto_generated_at) and is_nil(k.last_used_at) and k.uses_count == 0
    )
  end

  def expired_unused_install_keys(account_id, now) do
    auto_unused()
    |> by_account_id(account_id)
    |> where([enrollment_keys: k], k.expires_at <= ^now)
  end

  def prunable_install_ids(account_id, now, batch_size) do
    expired_unused_install_keys(account_id, now)
    |> order_by([enrollment_keys: k], asc: k.id)
    |> limit(^batch_size)
    |> select([enrollment_keys: k], k.id)
  end

  def by_ids(queryable, ids),
    do: where(queryable, [enrollment_keys: k], k.id in ^ids)

  @doc "Install-key ring overflow. Matches the api_key variant — see ApiKey.Query."
  def evictable_install_overflow(account_id, cap, protected_floor) do
    overflow_ids =
      auto_unused()
      |> by_account_id(account_id)
      |> order_by([enrollment_keys: k], desc: k.auto_generated_at)
      |> offset(^cap)
      |> select([enrollment_keys: k], k.id)

    auto_unused()
    |> by_account_id(account_id)
    |> where(
      [enrollment_keys: k],
      k.id in subquery(overflow_ids) and k.auto_generated_at < ^protected_floor
    )
  end

  @doc """
  WHERE clause for `consume_enrollment_key/1`'s conditional UPDATE: matches
  only rows whose every `usable?` condition still holds. The check
  happens at SQL level so two concurrent registrations can't both
  decrement a single-use key.
  """
  def consumable_by_id(id, now) do
    all()
    |> where([enrollment_keys: k], k.id == ^id)
    |> where(^usable_condition(now))
  end

  defp usable_condition(now) do
    dynamic(
      [enrollment_keys: k],
      is_nil(k.revoked_at) and is_nil(k.deleted_at) and
        (is_nil(k.expires_at) or k.expires_at > ^now) and
        ((k.reusable and (is_nil(k.max_uses) or k.uses_count < k.max_uses)) or
           (not k.reusable and k.uses_count == 0))
    )
  end

  @doc """
  Charge one consumption (`inc: uses_count, set: last_used_at`), retaining its
  console origin. Used keys are no longer eligible for cleanup.
  """
  def consume_one(queryable, now) do
    update(queryable,
      inc: [uses_count: 1],
      set: [last_used_at: ^now, updated_at: ^now]
    )
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([enrollment_keys: k], k.id in ^ids)
    |> select([enrollment_keys: k], {k.id, field(k, ^field)})
  end

  @doc "Left-join + preload the key's (non-deleted) creating user, idempotently."
  def with_preloaded_created_by(queryable) do
    queryable
    |> with_named_binding(:created_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [enrollment_keys: k],
        created_by in ^Users.User.Query.not_deleted(),
        on: k.created_by_id == created_by.id,
        as: ^binding
      )
    end)
    |> preload([created_by: created_by], created_by: created_by)
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:enrollment_keys, :desc, :inserted_at}, {:enrollment_keys, :asc, :id}]

  # created_by is a soft-delete schema — scope the preload to
  # not_deleted() so the filter is explicit at the preload site.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      created_by: {Users.User.Query.not_deleted(), Users.User.Query.preloads()}
    ]
end
