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

  def by_status(q, status),
    do: where(q, [runners: r], r.status == ^status)

  def ordered_by_group_name(q),
    do: order_by(q, [runners: r], asc: r.group, asc: r.name)

  @doc """
  Runners that opened a socket, sent at least one heartbeat, but went
  silent before `cutoff`. Used by `Workers.RunnerHealthSweep` to mark
  stale runners disconnected.

  Excludes runners that never heartbeat (`last_heartbeat_at IS NULL`) —
  those are caught by the WebSock-level heartbeat_timeout in
  `runner_socket.ex` and would otherwise race the 5-minute sweep cron
  against freshly-connected runners.
  """
  def stale_connected(q \\ all(), cutoff) do
    q
    |> where(
      [runners: r],
      r.status == "connected" and
        not is_nil(r.last_heartbeat_at) and
        r.last_heartbeat_at < ^cutoff
    )
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
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [
          {"connected", "Connected"},
          {"disconnected", "Disconnected"},
          {"disabled", "Disabled"},
          {"pending", "Pending"}
        ],
        fun: fn q, statuses -> {q, dynamic([runners: r], r.status in ^statuses)} end
      },
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
