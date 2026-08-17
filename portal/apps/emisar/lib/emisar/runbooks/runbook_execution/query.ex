defmodule Emisar.Runbooks.RunbookExecution.Query do
  use Emisar, :query
  alias Emisar.{Accounts, ApiKeys, Users}

  def all,
    do: from(runbook_executions in Emisar.Runbooks.RunbookExecution, as: :runbook_executions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [runbook_executions: r], r.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [runbook_executions: r], r.account_id == ^account_id)

  def by_runbook_id(queryable \\ all(), runbook_id),
    do: where(queryable, [runbook_executions: r], r.runbook_id == ^runbook_id)

  def by_api_key_id(queryable \\ all(), api_key_id),
    do: where(queryable, [runbook_executions: r], r.api_key_id == ^api_key_id)

  def by_operation_id(queryable \\ all(), operation_id),
    do: where(queryable, [runbook_executions: r], r.operation_id == ^operation_id)

  def active(queryable \\ all()),
    do: where(queryable, [runbook_executions: r], r.status == :active)

  def terminal_with_raw_inputs(queryable \\ all()) do
    where(
      queryable,
      [runbook_executions: r],
      r.status in [:succeeded, :halted, :cancelled] and not is_nil(r.inputs_raw)
    )
  end

  def select_count(queryable),
    do: select(queryable, [runbook_executions: r], count(r.id))

  def with_stages_and_items(queryable \\ all()) do
    queryable
    |> preload(
      [runbook_executions: _execution],
      stages: ^Emisar.Runbooks.ExecutionStage.Query.ordered(),
      items: ^Emisar.Runbooks.ExecutionItem.Query.ordered()
    )
  end

  def with_runbook(queryable \\ all()),
    do: preload(queryable, [runbook_executions: _execution], :runbook)

  @doc """
  Everything `Emisar.Runbooks.execution_who_via/1` reads, joined explicitly and
  idempotently: the requesting user, the API key with its creator, and the
  membership the execution was dispatched under.

  The key and the membership are scoped to the execution's own account, and the
  membership must both be the recorded `initiating_membership_id` and belong to
  the accountable human (requester or key creator). A plain association preload
  cannot express that, and would happily materialize a membership from a
  different account for the projection to name someone by.
  """
  def with_attribution(queryable \\ all()) do
    queryable
    |> with_named_binding(:requested_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runbook_executions: r],
        requested_by in ^Users.User.Query.not_deleted(),
        on: r.requested_by_id == requested_by.id,
        as: ^binding
      )
    end)
    |> with_named_binding(:api_key, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runbook_executions: r],
        api_key in ^ApiKeys.ApiKey.Query.not_deleted(),
        on: r.api_key_id == api_key.id and api_key.account_id == r.account_id,
        as: ^binding
      )
    end)
    |> with_named_binding(:api_key_created_by, fn queryable, binding ->
      join(
        queryable,
        :left,
        [api_key: api_key],
        created_by in ^Users.User.Query.not_deleted(),
        on: api_key.created_by_id == created_by.id,
        as: ^binding
      )
    end)
    |> with_named_binding(:initiating_membership, fn queryable, binding ->
      join(
        queryable,
        :left,
        [runbook_executions: r, requested_by: requested_by, api_key_created_by: created_by],
        membership in ^Accounts.Membership.Query.not_deleted(),
        on:
          membership.id == r.initiating_membership_id and
            membership.account_id == r.account_id and
            (membership.user_id == requested_by.id or membership.user_id == created_by.id),
        as: ^binding
      )
    end)
    |> preload(
      [
        requested_by: requested_by,
        api_key: api_key,
        api_key_created_by: created_by,
        initiating_membership: membership
      ],
      requested_by: requested_by,
      initiating_membership: membership,
      api_key: {api_key, created_by: created_by}
    )
  end

  def older_than(queryable \\ all(), cutoff),
    do: where(queryable, [runbook_executions: r], r.inserted_at <= ^cutoff)

  @doc """
  A bounded page of execution ids that completed before `cutoff`, scoped to
  `account_id`. Keyed on `completed_at` — which every terminal transition
  stamps — rather than `inserted_at`, because deleting an execution cascades
  through its stages and items to the action runs beneath them: a long-running
  execution started before the cutoff can own runs that finished after it, and
  those runs answer to their own retention.
  """
  def prunable_ids(account_id, %DateTime{} = cutoff, limit) when is_integer(limit) do
    all()
    |> by_account_id(account_id)
    |> where(
      [runbook_executions: r],
      not is_nil(r.completed_at) and r.completed_at < ^cutoff
    )
    |> limit(^limit)
    |> select([runbook_executions: r], r.id)
  end

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [runbook_executions: r], r.id in ^ids)

  def ordered_by_oldest(queryable \\ all()),
    do: order_by(queryable, [runbook_executions: r], asc: r.inserted_at, asc: r.id)

  def ordered_by_least_recently_advanced(queryable \\ all()) do
    order_by(queryable, [runbook_executions: r],
      asc_nulls_first: r.last_advanced_at,
      asc: r.inserted_at,
      asc: r.id
    )
  end

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [runbook_executions: r], desc: r.inserted_at, desc: r.id)

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")
end
