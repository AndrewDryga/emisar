defmodule Emisar.Approvals.Request.Query do
  use Emisar, :query

  def all,
    do: from(requests in Emisar.Approvals.Request, as: :requests)

  def by_id(queryable, id),
    do: where(queryable, [requests: r], r.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [requests: r], r.account_id == ^account_id)

  def by_run_id(queryable, run_id),
    do: where(queryable, [requests: r], r.run_id == ^run_id)

  def by_status(queryable, status),
    do: where(queryable, [requests: r], r.status == ^status)

  def pending(queryable \\ all()),
    do: where(queryable, [requests: r], r.status == :pending)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [requests: r], desc: r.requested_at)

  def ordered_by_requested(queryable),
    do: order_by(queryable, [requests: r], asc: r.requested_at)

  def limit_to(queryable, n), do: limit(queryable, ^n)

  def expired_at_before(queryable, now),
    do: where(queryable, [requests: r], not is_nil(r.expires_at) and r.expires_at < ^now)

  @doc """
  Row lock for the finalize re-read in `record_decision` — the decision is
  taken on the LOCKED request row so concurrent votes serialize and a
  finalizing transition can't race another. `FOR NO KEY UPDATE`, matching the
  run-transition lock.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  @doc """
  Conditional UPDATE used by `claim_pending/4`: matches only rows still
  `status == "pending"` AND not past `expires_at` — so two concurrent
  operators racing to decide can't both win, and a request that lapsed
  past its expiry can't be approved in the window before the expiry sweep
  (which runs only every few minutes) flips it to `:expired`. The decision
  boundary is the row predicate here, not the sweep, so the advertised
  hard expiry holds even if the sweep is delayed. Mirrors how
  `Grant.Query.consumable_by_id/2` guards `expires_at` at consumption.
  """
  def decide_pending(id, status, by_user_id, reason, now) do
    all()
    |> where(
      [requests: r],
      r.id == ^id and r.status == :pending and
        (is_nil(r.expires_at) or r.expires_at > ^now)
    )
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
    |> where([requests: r], r.id == ^id and r.status == :pending)
    |> update(
      set: [
        status: :expired,
        decided_at: ^now,
        decision_reason: "pending approval window expired",
        updated_at: ^now
      ]
    )
  end

  @doc """
  Conditional UPDATE for `Approvals.cancel_request_for_run_in_multi/2`: flips a
  still-pending request whose gated RUN was cancelled to `"cancelled"`. Scoped
  by `run_id` (immutable) + `status == :pending` so it composes atomically into
  the run-cancel transaction and can't override an already-decided request.
  """
  def cancel_pending_by_run_id(run_id, now) do
    all()
    |> where([requests: r], r.run_id == ^run_id and r.status == :pending)
    |> update(
      set: [
        status: :cancelled,
        decided_at: ^now,
        decision_reason: "run cancelled before approval",
        updated_at: ^now
      ]
    )
  end

  @doc "Audit label-lookup helper. See Users.User.Query.select_labels/3."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([requests: r], r.id in ^ids)
    |> select([requests: r], {r.id, field(r, ^field)})
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:requests, :desc, :requested_at}, {:requests, :asc, :id}]
end
