defmodule Emisar.Approvals.Decision.Query do
  use Emisar, :query

  def all,
    do: from(decisions in Emisar.Approvals.Decision, as: :approval_decisions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [approval_decisions: d], d.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [approval_decisions: d], d.account_id == ^account_id)

  def by_request_id(queryable \\ all(), request_id),
    do: where(queryable, [approval_decisions: d], d.request_id == ^request_id)

  def ordered_by_decided(queryable \\ all()),
    do: order_by(queryable, [approval_decisions: d], asc: d.decided_at)

  @doc """
  Distinct count of approvers for a request — the finalize check. Built as a
  `COUNT(DISTINCT decider_id)` over the approve votes; the context runs it
  with `Repo.one` to get the integer (a double-submit inserts 0 extra rows,
  so it can't inflate the count).
  """
  def approved_distinct_decider_count(request_id) do
    all()
    |> by_request_id(request_id)
    |> where([approval_decisions: d], d.decision == :approve)
    |> select([approval_decisions: d], count(d.decider_id, :distinct))
  end

  @doc """
  Row lock for the finalize re-read, matching the request-row lock in
  `record_decision` so concurrent votes serialize.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  @doc "Left-join + preload the (non-deleted) deciding user, idempotently."
  def with_preloaded_decider(queryable) do
    queryable
    |> with_named_binding(:decider, fn queryable, binding ->
      join(
        queryable,
        :left,
        [approval_decisions: d],
        decider in ^Emisar.Users.User.Query.not_deleted(),
        on: d.decider_id == decider.id,
        as: ^binding
      )
    end)
    |> preload([decider: decider], decider: decider)
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:approval_decisions, :asc, :decided_at}, {:approval_decisions, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads,
    do: [decider: {Emisar.Users.User.Query.not_deleted(), Emisar.Users.User.Query.preloads()}]
end
