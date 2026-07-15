defmodule Emisar.Runners.Runner.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(runners in Emisar.Runners.Runner, as: :runners)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.deleted_at))

  def not_disabled(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.disabled_at))

  def none(queryable), do: where(queryable, false)

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  def by_id(queryable, id),
    do: where(queryable, [runners: r], r.id == ^id)

  def by_connection_generation(queryable, generation),
    do: where(queryable, [runners: r], r.connection_generation == ^generation)

  def by_connection_lease(queryable, generation, lease_id) do
    where(
      queryable,
      [runners: r],
      r.connection_generation == ^generation and r.connection_lease_id == ^lease_id
    )
  end

  def lease_available(queryable, now) do
    where(
      queryable,
      [runners: r],
      is_nil(r.connection_lease_id) or is_nil(r.connection_lease_expires_at) or
        r.connection_lease_expires_at <= ^now
    )
  end

  def by_ids(queryable, ids),
    do: where(queryable, [runners: r], r.id in ^ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runners: r], r.account_id == ^account_id)

  def by_bootstrap_enrollment_key_id(queryable, enrollment_key_id),
    do: where(queryable, [runners: r], r.bootstrap_enrollment_key_id == ^enrollment_key_id)

  def by_external_id(queryable, external_id),
    do: where(queryable, [runners: r], r.external_id == ^external_id)

  def by_name(queryable, name),
    do: where(queryable, [runners: r], r.name == ^name)

  def by_group(queryable, group),
    do: where(queryable, [runners: r], r.group == ^group)

  def by_groups(queryable, groups) when is_list(groups),
    do: where(queryable, [runners: r], r.group in ^groups)

  def enforcing(queryable \\ all()),
    do: where(queryable, [runners: r], r.enforce_signatures == true)

  @doc """
  Restrict to the runners a per-membership scope set grants — matched by
  runner id (`runner_ids`) or by group (`groups`). Drives query-level runner
  ACLs; the caller handles the empty-scopes-means-all case before calling.
  """
  def by_scope_values(queryable, runner_ids, groups),
    do: where(queryable, [runners: r], r.id in ^runner_ids or r.group in ^groups)

  def ordered_by_group_name(queryable),
    do: order_by(queryable, [runners: r], asc: r.group, asc: r.name)

  @doc """
  Filter by derived connection state. `online_ids` is the set of runner
  ids currently tracked in `Emisar.Runners.Presence` — the DB can't see
  presence, so the context resolves the ids and hands them in. `statuses`
  is any of `"connected"`, `"disconnected"`, `"pending"`, `"disabled"`,
  ORed together. An empty `statuses` list matches nothing.
  """
  def by_connection(queryable \\ all(), statuses, online_ids) when is_list(statuses) do
    # Clauses mirror `Emisar.Runners.connection_state/1`'s precedence
    # (disabled beats a stale socket), so the four states partition the
    # set cleanly — a disabled-never-connected runner is only "disabled".
    condition =
      Enum.reduce(statuses, dynamic(false), fn
        "connected", acc ->
          dynamic([runners: r], ^acc or (r.id in ^online_ids and is_nil(r.disabled_at)))

        "disconnected", acc ->
          dynamic(
            [runners: r],
            ^acc or
              (r.id not in ^online_ids and not is_nil(r.last_connected_at) and
                 is_nil(r.disabled_at))
          )

        "pending", acc ->
          dynamic(
            [runners: r],
            ^acc or
              (is_nil(r.last_connected_at) and r.id not in ^online_ids and is_nil(r.disabled_at))
          )

        "disabled", acc ->
          dynamic([runners: r], ^acc or not is_nil(r.disabled_at))

        _other, acc ->
          acc
      end)

    where(queryable, ^condition)
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([runners: r], r.id in ^ids)
    |> select([runners: r], {r.id, field(r, ^field)})
  end

  def group_summary(queryable \\ not_deleted()) do
    queryable
    |> group_by([runners: r], r.group)
    |> select([runners: r], {r.group, count(r.id)})
    |> order_by([runners: r], asc: r.group)
  end

  # Connection-record state from the DURABLE `last_connected_at` /
  # `last_disconnected_at` columns — NOT live Presence. Drives the fleet-wide
  # ops gauge (`Runners.connection_counts/0`); the per-account UI uses Presence
  # (`by_connection/3`), which catches an ungraceful socket drop these columns
  # only learn about on the next `mark_disconnected`/reconnect.
  def disabled(queryable \\ all()),
    do: where(queryable, [runners: r], not is_nil(r.disabled_at))

  def never_connected(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.last_connected_at))

  def connected(queryable \\ all()) do
    where(
      queryable,
      [runners: r],
      not is_nil(r.last_connected_at) and
        (is_nil(r.last_disconnected_at) or r.last_connected_at > r.last_disconnected_at)
    )
  end

  def disconnected(queryable \\ all()) do
    where(
      queryable,
      [runners: r],
      not is_nil(r.last_connected_at) and not is_nil(r.last_disconnected_at) and
        r.last_disconnected_at >= r.last_connected_at
    )
  end

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runners, :asc, :group}, {:runners, :asc, :name}, {:runners, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads, do: []

  @impl Emisar.Repo.Query
  def filters,
    do: [
      %Filter{
        name: :group,
        title: "Group",
        type: :string,
        fun: fn queryable, group -> {queryable, dynamic([runners: r], r.group == ^group)} end
      },
      %Filter{
        name: :name,
        title: "Name",
        type: :string,
        fun: fn queryable, name ->
          {queryable, dynamic([runners: r], ilike(r.name, ^Like.contains(name)))}
        end
      }
    ]
end
