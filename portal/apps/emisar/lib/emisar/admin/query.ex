defmodule Emisar.Admin.Query do
  @moduledoc false
  use Emisar, :query
  alias Emisar.{Accounts, ApiKeys, Approvals, Audit, Runners, Runs, SSO, Users}
  alias Emisar.Repo.Like

  @non_success_outcome_statuses Runs.ActionRun.terminal_statuses() -- [:success]

  def accounts_matching(term, limit \\ 25) do
    pattern = Like.contains(term)

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

  # Disabled accounts stay in the listing: staff triage starts from the ones a
  # customer can no longer reach themselves.
  def recent_accounts(limit \\ 20) do
    Accounts.Account.Query.not_deleted()
    |> order_by([accounts: a], desc: a.inserted_at, desc: a.id)
    |> Accounts.Account.Query.limit_to(limit)
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

  # The whole roster, suspended members and unaccepted invitations included —
  # "who can reach this account" is the first question a support case asks.
  def account_memberships(account_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.with_preloaded_user()
    |> order_by([memberships: m, user: u], asc: m.role, asc: u.email)
  end

  # An account holds at most one provider per kind, so this is a list, not a
  # single row; disabled providers are kept — "SSO configured but switched off"
  # is exactly the state a support case is opened about.
  def account_identity_providers(account_id) do
    SSO.IdentityProvider.Query.not_deleted()
    |> SSO.IdentityProvider.Query.by_account_id(account_id)
    |> SSO.IdentityProvider.Query.ordered_by_name()
  end

  # The four connection states are disjoint, so the fleet posture is one scan
  # rather than a count per state.
  def account_runner_connection_counts(account_id) do
    Runners.Runner.Query.not_deleted()
    |> Runners.Runner.Query.by_account_id(account_id)
    |> Runners.Runner.Query.connection_counts()
  end

  def recent_account_runners(account_id, limit \\ 50) do
    Runners.Runner.Query.not_deleted()
    |> Runners.Runner.Query.by_account_id(account_id)
    |> order_by([runners: r], desc_nulls_last: r.last_connected_at, asc: r.name)
    |> Runners.Runner.Query.limit_to(limit)
  end

  def account_runs_since(account_id, since) do
    Runs.ActionRun.Query.all()
    |> Runs.ActionRun.Query.by_account_id(account_id)
    |> Runs.ActionRun.Query.inserted_after(since)
  end

  def recent_account_runs(account_id, limit \\ 10) do
    Runs.ActionRun.Query.all()
    |> Runs.ActionRun.Query.by_account_id(account_id)
    |> Runs.ActionRun.Query.ordered_by_recent()
    |> Runs.ActionRun.Query.limit_to(limit)
  end

  def recent_audit_events(account_id, limit \\ 10) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.ordered_by_recent()
    |> Audit.Event.Query.limit_to(limit)
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

  # The per-account cut of `mcp_clients_since/2`: within one account the
  # distinct-account tally is always 1, so the run count is the whole answer.
  def account_mcp_clients_since(account_id, since, limit \\ 10) do
    Runs.ActionRun.Query.all()
    |> Runs.ActionRun.Query.by_account_id(account_id)
    |> Runs.ActionRun.Query.inserted_after(since)
    |> where([runs: r], r.source == :mcp)
    |> group_by([runs: r], fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info))
    |> select([runs: r], %{
      client: fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info),
      runs: count(r.id)
    })
    |> order_by([runs: r], desc: count(r.id))
    |> Runs.ActionRun.Query.limit_to(limit)
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

  # The recent sample and `non_success_outcome_groups_since/2` are returned by
  # one RPC and must answer "what is failing?" with one definition: a group
  # counting 412 `:denied` runs the sample can never contain reads as a broken
  # sample. Both derive their set from `terminal_statuses/0`, so a new terminal
  # status reaches both halves at once.
  def recent_failures(since, limit \\ 50) do
    Runs.ActionRun.Query.all()
    |> where(
      [runs: r],
      r.inserted_at >= ^since and r.status in ^@non_success_outcome_statuses
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

  def non_success_outcome_groups_since(since, limit \\ 100) do
    Runs.ActionRun.Query.all()
    |> where(
      [runs: r],
      r.inserted_at >= ^since and r.status in ^@non_success_outcome_statuses
    )
    |> group_by(
      [runs: r],
      [
        r.action_id,
        r.pack_ref,
        r.status,
        r.source,
        fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info)
      ]
    )
    |> select([runs: r], %{
      action_id: r.action_id,
      pack_ref: r.pack_ref,
      status: r.status,
      source: r.source,
      client: fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info),
      run_count: count(r.id),
      operation_count: count(r.operation_id, :distinct),
      account_count: count(r.account_id, :distinct),
      last_seen_at: max(r.inserted_at)
    })
    |> order_by(
      [runs: r],
      desc: count(r.id),
      asc: r.action_id,
      asc: r.status,
      asc: r.source,
      asc: fragment("COALESCE(NULLIF(?->>'name', ''), 'unknown')", r.client_info)
    )
    |> limit(^limit)
  end

  def user_session_count(user_id) do
    from(token in Emisar.Auth.UserToken,
      as: :user_tokens,
      where: token.user_id == ^user_id and token.context == "session",
      select: count(token.id)
    )
  end

  def active_api_key_count(account_id),
    do: account_id |> active_api_keys() |> select([api_keys: k], count(k.id))

  def active_api_key_count(account_id, user_id) do
    account_id
    |> active_api_keys()
    |> where([api_keys: k], k.created_by_id == ^user_id)
    |> select([api_keys: k], count(k.id))
  end

  defp active_api_keys(account_id) do
    ApiKeys.ApiKey.Query.not_deleted()
    |> ApiKeys.ApiKey.Query.by_account_id(account_id)
    |> ApiKeys.ApiKey.Query.not_revoked()
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
