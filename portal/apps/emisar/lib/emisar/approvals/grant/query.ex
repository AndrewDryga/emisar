defmodule Emisar.Approvals.Grant.Query do
  use Emisar, :query

  def all,
    do: from(grants in Emisar.Approvals.Grant, as: :grants)

  def by_id(queryable, id),
    do: where(queryable, [grants: g], g.id == ^id)

  def by_ids(queryable, ids), do: where(queryable, [grants: g], g.id in ^ids)

  def select_ids(queryable), do: select(queryable, [grants: g], g.id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [grants: g], g.account_id == ^account_id)

  def by_api_key_id(queryable, api_key_id),
    do: where(queryable, [grants: g], g.api_key_id == ^api_key_id)

  def by_granted_by_user_id(queryable, user_id),
    do: where(queryable, [grants: g], g.granted_by_id == ^user_id)

  def not_revoked(queryable \\ all()),
    do: where(queryable, [grants: g], is_nil(g.revoked_at))

  def not_expired(queryable, now \\ DateTime.utc_now()),
    do: where(queryable, [grants: g], is_nil(g.expires_at) or g.expires_at > ^now)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [grants: g], desc: g.granted_at)

  def ordered_by_granted(queryable),
    do: order_by(queryable, [grants: g], asc: g.granted_at)

  def ordered_by_id(queryable), do: order_by(queryable, [grants: g], asc: g.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  @doc """
  Selects the whole row so `Repo.update_all/3` can RETURN what it changed — the
  membership cascade audits one row per revoked grant, and a read followed by an
  update would miss a grant minted between the two statements.
  """
  def select_all(queryable), do: select(queryable, [grants: g], g)

  @doc "Audit label-lookup helper for standing-grant targets."
  def select_labels(queryable, ids, field) do
    queryable
    |> where([grants: g], g.id in ^ids)
    |> select([grants: g], {g.id, field(g, ^field)})
  end

  def by_action_id(queryable, action_id),
    do: where(queryable, [grants: g], g.action_id == ^action_id)

  def by_pack_ref(queryable, pack_ref),
    do: where(queryable, [grants: g], g.pack_ref == ^pack_ref)

  def by_target_access(queryable, %Emisar.Accounts.RunnerAccess{} = access) do
    {queryable, allowed} = target_access(queryable, access)
    where(queryable, ^allowed)
  end

  def outside_target_access(queryable, %Emisar.Accounts.RunnerAccess{} = access) do
    {queryable, allowed} = target_access(queryable, access)
    denied = dynamic(not coalesce(^allowed, false))
    where(queryable, ^denied)
  end

  # The same frozen identity/current target rules as the locked revocation
  # guard. A wildcard requires all runners; a concrete target must still exist
  # in this account. Offline and disabled runners remain valid targets.
  defp target_access(queryable, access) do
    queryable =
      with_named_binding(queryable, :scope_runner, fn queryable, binding ->
        join(
          queryable,
          :left,
          [grants: grant],
          runner in ^Emisar.Runners.Runner.Query.not_deleted(),
          on: grant.runner_id == runner.id and grant.account_id == runner.account_id,
          as: ^binding
        )
      end)

    runner_allowed =
      case access do
        %{mode: :none} ->
          dynamic(false)

        %{mode: :all} ->
          dynamic(
            [grants: grant, scope_runner: runner],
            is_nil(grant.runner_id) or not is_nil(runner.id)
          )

        %{mode: :restricted, runner_ids: ids, groups: groups} ->
          dynamic(
            [scope_runner: runner],
            not is_nil(runner.id) and (runner.id in ^ids or runner.group in ^groups)
          )
      end

    pack_allowed =
      case access do
        %{pack_mode: :all} ->
          dynamic(true)

        %{pack_mode: :restricted, pack_ids: ids} ->
          dynamic([grants: grant], fragment("split_part(?, '@', 1)", grant.pack_ref) in ^ids)
      end

    canonical =
      "^[a-z][a-z0-9_-]*@[0-9]+([.][0-9]+)*(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?/sha256:[0-9a-f]{64}$"

    allowed =
      dynamic(
        [grants: grant],
        fragment("? ~ ?", grant.pack_ref, ^canonical) and ^pack_allowed and ^runner_allowed
      )

    {queryable, allowed}
  end

  @doc """
  Match `runner_id` exactly, OR allow a wildcard grant (where
  `runner_id IS NULL`). When the caller has no runner, only wildcard
  grants match.
  """
  def by_runner_or_wildcard(queryable, nil),
    do: where(queryable, [grants: g], is_nil(g.runner_id))

  def by_runner_or_wildcard(queryable, runner_id),
    do: where(queryable, [grants: g], is_nil(g.runner_id) or g.runner_id == ^runner_id)

  def by_args_sha_or_wildcard(queryable, nil),
    do: where(queryable, [grants: g], is_nil(g.args_sha256))

  def by_args_sha_or_wildcard(queryable, args_sha),
    do: where(queryable, [grants: g], is_nil(g.args_sha256) or g.args_sha256 == ^args_sha)

  @doc """
  Candidates for `peek_matching_grant/6` — narrows by api_key + exact
  action contract + un-revoked + not-yet-expired. Caller composes runner /
  args_sha match on top.
  """
  def candidates_for_dispatch(api_key_id, action_id, pack_ref, now) do
    all()
    |> by_api_key_id(api_key_id)
    |> by_action_id(action_id)
    |> by_pack_ref(pack_ref)
    |> not_revoked()
    |> not_expired(now)
    |> ordered_by_granted()
  end

  @doc """
  WHERE clause for `use_grant/1`'s conditional UPDATE: matches the
  grant only if it's still usable AT the moment of the update.
  """
  def consumable_by_id(id, now) do
    all()
    |> where([grants: g], g.id == ^id)
    |> where([grants: g], is_nil(g.revoked_at))
    |> where([grants: g], is_nil(g.expires_at) or g.expires_at > ^now)
    |> where([grants: g], is_nil(g.max_uses) or g.uses_count < g.max_uses)
  end

  def consume_one(queryable, now) do
    update(queryable,
      inc: [uses_count: 1],
      set: [last_used_at: ^now, updated_at: ^now]
    )
  end

  # -- Preload helpers --------------------------------------------------
  # All belongs_to and optional (a deleted key/runner/user must not hide
  # the grant from the audit-relevant list), so every join is :left and
  # scoped to the assoc's not_deleted() where one exists.

  @doc "Left-join + preload the grant's (non-deleted) API key, idempotently."
  def with_preloaded_api_key(queryable) do
    queryable
    |> with_named_binding(:api_key, fn queryable, binding ->
      join(
        queryable,
        :left,
        [grants: g],
        api_key in ^Emisar.ApiKeys.ApiKey.Query.not_deleted(),
        on: g.api_key_id == api_key.id,
        as: ^binding
      )
    end)
    |> preload([api_key: api_key], api_key: api_key)
  end

  @doc "Left-join + preload the grant's (non-deleted) runner, idempotently."
  def with_preloaded_runner(queryable) do
    queryable
    |> with_named_binding(:runner, fn queryable, binding ->
      join(
        queryable,
        :left,
        [grants: g],
        runner in ^Emisar.Runners.Runner.Query.not_deleted(),
        on: g.runner_id == runner.id,
        as: ^binding
      )
    end)
    |> preload([runner: runner], runner: runner)
  end

  @doc """
  Left-join + preload the grant's approval request together with that
  request's run (neither is soft-deleted), idempotently.
  """
  def with_preloaded_approval_request_run(queryable) do
    queryable
    |> with_named_binding(:approval_request, fn queryable, binding ->
      join(
        queryable,
        :left,
        [grants: g],
        approval_request in Emisar.Approvals.Request,
        on: g.approval_request_id == approval_request.id,
        as: ^binding
      )
    end)
    |> with_named_binding(:approval_request_run, fn queryable, binding ->
      join(
        queryable,
        :left,
        [approval_request: approval_request],
        run in Emisar.Runs.ActionRun,
        on: approval_request.run_id == run.id,
        as: ^binding
      )
    end)
    |> preload(
      [approval_request: approval_request, approval_request_run: run],
      approval_request: {approval_request, run: run}
    )
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:grants, :desc, :granted_at}, {:grants, :asc, :id}]

  # api_key / runner / the user assocs are soft-delete schemas — scope
  # each preload to not_deleted() so the filter is explicit at the
  # preload site. approval_request has no deleted_at and falls through
  # to Ecto's machinery.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      api_key:
        {Emisar.ApiKeys.ApiKey.Query.not_deleted(), Emisar.ApiKeys.ApiKey.Query.preloads()},
      runner: {Emisar.Runners.Runner.Query.not_deleted(), Emisar.Runners.Runner.Query.preloads()},
      granted_by: {Emisar.Users.User.Query.not_deleted(), Emisar.Users.User.Query.preloads()},
      revoked_by: {Emisar.Users.User.Query.not_deleted(), Emisar.Users.User.Query.preloads()}
    ]
end
