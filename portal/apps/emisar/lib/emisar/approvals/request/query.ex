defmodule Emisar.Approvals.Request.Query do
  use Emisar, :query

  def all,
    do: from(requests in Emisar.Approvals.Request, as: :requests)

  def by_id(q, id),
    do: where(q, [requests: r], r.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [requests: r], r.account_id == ^account_id)

  def by_run_id(q, run_id),
    do: where(q, [requests: r], r.run_id == ^run_id)

  def by_status(q, status),
    do: where(q, [requests: r], r.status == ^status)

  def pending(q \\ all()),
    do: where(q, [requests: r], r.status == "pending")

  def ordered_by_recent(q \\ all()),
    do: order_by(q, [requests: r], desc: r.requested_at)

  def ordered_by_requested(q),
    do: order_by(q, [requests: r], asc: r.requested_at)

  def limit_to(q, n), do: limit(q, ^n)

  def expired_at_before(q, now),
    do: where(q, [requests: r], not is_nil(r.expires_at) and r.expires_at < ^now)

  @doc """
  Conditional UPDATE used by `claim_pending/4`: matches only rows
  still `status == "pending"` so two concurrent operators racing to
  decide can't both win.
  """
  def decide_pending(id, status, by_user_id, reason, now) do
    all()
    |> where([requests: r], r.id == ^id and r.status == "pending")
    |> update(
      set: [
        status: ^status,
        decided_by_id: ^by_user_id,
        decided_at: ^now,
        decision_reason: ^reason
      ]
    )
  end

  @doc """
  Conditional UPDATE for `expire_overdue_requests/1`: flips a still-pending
  expired request to `"expired"` with the cancel reason in
  `decision_reason`.
  """
  def expire_pending(id, now) do
    all()
    |> where([requests: r], r.id == ^id and r.status == "pending")
    |> update(
      set: [
        status: "expired",
        decided_at: ^now,
        decision_reason: "pending approval window expired",
        updated_at: ^now
      ]
    )
  end

  @doc "Audit label-lookup helper. See Accounts.User.Query.select_labels/3."
  def select_labels(q, ids, field) do
    q
    |> where([requests: r], r.id in ^ids)
    |> select([requests: r], {r.id, field(r, ^field)})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:requests, :desc, :requested_at}, {:requests, :asc, :id}]
end
