defmodule Emisar.Runners.Runner.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter

  def all,
    do: from(runners in Emisar.Runners.Runner, as: :runners)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.deleted_at))

  def not_disabled(queryable \\ all()),
    do: where(queryable, [runners: r], is_nil(r.disabled_at))

  def by_id(queryable, id),
    do: where(queryable, [runners: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [runners: r], r.account_id == ^account_id)

  def by_external_id(queryable, external_id),
    do: where(queryable, [runners: r], r.external_id == ^external_id)

  def by_name(queryable, name),
    do: where(queryable, [runners: r], r.name == ^name)

  def by_group(queryable, group),
    do: where(queryable, [runners: r], r.group == ^group)

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
        fun: fn q, group -> {q, dynamic([runners: r], r.group == ^group)} end
      },
      %Filter{
        name: :name,
        title: "Name contains",
        type: :string,
        fun: fn q, name -> {q, dynamic([runners: r], ilike(r.name, ^"%#{name}%"))} end
      }
    ]
end
