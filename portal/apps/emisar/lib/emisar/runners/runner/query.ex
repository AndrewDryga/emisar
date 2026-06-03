defmodule Emisar.Runners.Runner.Query do
  use Emisar, :query

  alias Emisar.Repo.Filter

  def all,
    do: from(runners in Emisar.Runners.Runner, as: :runners)

  def not_deleted(q \\ all()),
    do: where(q, [runners: r], is_nil(r.deleted_at))

  def not_disabled(q \\ all()),
    do: where(q, [runners: r], is_nil(r.disabled_at))

  def by_id(q, id),
    do: where(q, [runners: r], r.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [runners: r], r.account_id == ^account_id)

  def by_external_id(q, external_id),
    do: where(q, [runners: r], r.external_id == ^external_id)

  def by_name(q, name),
    do: where(q, [runners: r], r.name == ^name)

  def by_group(q, group),
    do: where(q, [runners: r], r.group == ^group)

  def ordered_by_group_name(q),
    do: order_by(q, [runners: r], asc: r.group, asc: r.name)

  @doc """
  Filter by derived connection state. `online_ids` is the set of runner
  ids currently tracked in `Emisar.Runners.Presence` — the DB can't see
  presence, so the context resolves the ids and hands them in (Firezone's
  pattern). `statuses` is any of `"connected"`, `"disconnected"`,
  `"pending"`, `"disabled"`, ORed together. An empty `statuses` list
  matches nothing.
  """
  def by_connection(q \\ all(), statuses, online_ids) when is_list(statuses) do
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

    where(q, ^condition)
  end

  @doc "Audit label-lookup helper. See Accounts.User.Query.select_labels/3."
  def select_labels(q, ids, field) do
    q
    |> where([runners: r], r.id in ^ids)
    |> select([runners: r], {r.id, field(r, ^field)})
  end

  def group_summary(q \\ not_deleted()) do
    q
    |> group_by([runners: r], r.group)
    |> select([runners: r], {r.group, count(r.id)})
    |> order_by([runners: r], asc: r.group)
  end

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:runners, :asc, :group}, {:runners, :asc, :name}, {:runners, :asc, :id}]

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
