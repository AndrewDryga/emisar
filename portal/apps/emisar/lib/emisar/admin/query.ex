defmodule Emisar.Admin.Query do
  @moduledoc false
  use Emisar, :query
  alias Emisar.{Accounts, ApiKeys, Approvals, Runners, Runs, Users}

  def accounts_matching(term, limit \\ 25) do
    pattern = "%#{term}%"

    Accounts.Account.Query.not_deleted()
    |> join(:left, [accounts: a], membership in ^Accounts.Membership.Query.not_deleted(),
      on: membership.account_id == a.id,
      as: :memberships
    )
    |> join(:left, [memberships: m], user in ^Users.User.Query.not_deleted(),
      on: user.id == m.user_id,
      as: :users
    )
    |> where(
      [accounts: a, users: u],
      ilike(a.name, ^pattern) or ilike(a.slug, ^pattern) or ilike(u.email, ^pattern)
    )
    |> distinct([accounts: a], a.id)
    |> order_by([accounts: a], asc: a.name, asc: a.id)
    |> limit(^limit)
  end

  def membership_by_id(account_id, membership_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_id(membership_id)
    |> Accounts.Membership.Query.with_preloaded_user()
  end

  def membership_by_email(account_id, email) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> join(:inner, [memberships: m], user in ^Users.User.Query.not_deleted(),
      on: user.id == m.user_id,
      as: :user
    )
    |> where([user: u], u.email == ^email)
    |> preload([user: u], user: u)
  end

  def count_accounts_since(since),
    do: count_since(Accounts.Account.Query.not_deleted(), :accounts, since)

  def count_users_since(since),
    do: count_since(Users.User.Query.not_deleted(), :users, since)

  def count_memberships_since(since),
    do: count_since(Accounts.Membership.Query.not_deleted(), :memberships, since)

  def count_runners_since(since),
    do: count_since(Runners.Runner.Query.not_deleted(), :runners, since)

  def count_runs_since(since),
    do: count_since(Runs.ActionRun.Query.all(), :runs, since)

  def run_statuses_since(since) do
    Runs.ActionRun.Query.all()
    |> where([runs: r], r.inserted_at >= ^since)
    |> group_by([runs: r], r.status)
    |> select([runs: r], %{status: r.status, count: count(r.id)})
    |> order_by([runs: r], desc: count(r.id), asc: r.status)
  end

  def top_actions_since(since, limit \\ 20) do
    Runs.ActionRun.Query.all()
    |> where([runs: r], r.inserted_at >= ^since)
    |> group_by([runs: r], r.action_id)
    |> select([runs: r], %{action_id: r.action_id, count: count(r.id)})
    |> order_by([runs: r], desc: count(r.id), asc: r.action_id)
    |> limit(^limit)
  end

  def mcp_clients_since(since, limit \\ 20) do
    Runs.ActionRun.Query.all()
    |> where([runs: r], r.source == :mcp and r.inserted_at >= ^since)
    |> group_by([runs: r], fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info))
    |> select([runs: r], %{
      client: fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info),
      runs: count(r.id),
      accounts: count(r.account_id, :distinct)
    })
    |> order_by([runs: r], desc: count(r.id))
    |> limit(^limit)
  end

  def approval_statuses_since(since) do
    from(request in Approvals.Request,
      as: :approval_requests,
      where: request.inserted_at >= ^since,
      group_by: request.status,
      select: %{status: request.status, count: count(request.id)},
      order_by: [desc: count(request.id), asc: request.status]
    )
  end

  def subscription_posture do
    from(subscription in Emisar.Billing.Subscription,
      as: :subscriptions,
      group_by: [subscription.plan, subscription.status],
      select: %{
        plan: subscription.plan,
        status: subscription.status,
        accounts: count(subscription.id)
      },
      order_by: [asc: subscription.plan, asc: subscription.status]
    )
  end

  def active_account_ids_since(since, limit \\ 50) do
    Runs.ActionRun.Query.all()
    |> where([runs: r], r.inserted_at >= ^since)
    |> group_by([runs: r], r.account_id)
    |> select([runs: r], %{
      account_id: r.account_id,
      runs: count(r.id),
      last_run_at: max(r.inserted_at)
    })
    |> order_by([runs: r], desc: count(r.id), asc: r.account_id)
    |> limit(^limit)
  end

  def recent_failures(since, limit \\ 50) do
    Runs.ActionRun.Query.all()
    |> where(
      [runs: r],
      r.inserted_at >= ^since and
        r.status in [:failed, :error, :validation_failed, :unknown_action, :timed_out, :refused]
    )
    |> order_by([runs: r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> select([runs: r], %{
      request_id: r.request_id,
      account_id: r.account_id,
      runner_id: r.runner_id,
      action_id: r.action_id,
      status: r.status,
      reason: r.reason_text,
      error: r.error_message,
      occurred_at: r.inserted_at
    })
  end

  def user_session_count(user_id) do
    from(token in Emisar.Auth.UserToken,
      as: :user_tokens,
      where: token.user_id == ^user_id and token.context == "session",
      select: count(token.id)
    )
  end

  def active_api_key_count(account_id, user_id) do
    from(key in ApiKeys.ApiKey,
      as: :api_keys,
      where:
        key.account_id == ^account_id and key.created_by_id == ^user_id and
          is_nil(key.revoked_at) and is_nil(key.deleted_at),
      select: count(key.id)
    )
  end

  def table_counts do
    from(account in Accounts.Account,
      as: :accounts,
      select: %{
        accounts: fragment("(SELECT count(*) FROM accounts WHERE deleted_at IS NULL)"),
        users: fragment("(SELECT count(*) FROM users WHERE deleted_at IS NULL)"),
        memberships:
          fragment("(SELECT count(*) FROM account_memberships WHERE deleted_at IS NULL)"),
        runners: fragment("(SELECT count(*) FROM runners WHERE deleted_at IS NULL)"),
        runs: fragment("(SELECT count(*) FROM action_runs)"),
        audit_events: fragment("(SELECT count(*) FROM audit_events)")
      },
      limit: 1
    )
  end

  defp count_since(queryable, binding, since) do
    where(queryable, [{^binding, row}], field(row, :inserted_at) >= ^since)
  end
end
