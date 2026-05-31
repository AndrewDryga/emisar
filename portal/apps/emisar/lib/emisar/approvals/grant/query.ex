defmodule Emisar.Approvals.Grant.Query do
  use Emisar, :query

  def all,
    do: from(grants in Emisar.Approvals.Grant, as: :grants)

  def by_id(q, id),
    do: where(q, [grants: g], g.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [grants: g], g.account_id == ^account_id)

  def by_api_key_id(q, api_key_id),
    do: where(q, [grants: g], g.api_key_id == ^api_key_id)

  def not_revoked(q \\ all()),
    do: where(q, [grants: g], is_nil(g.revoked_at))

  def not_expired(q, now \\ DateTime.utc_now()),
    do: where(q, [grants: g], is_nil(g.expires_at) or g.expires_at > ^now)

  def ordered_by_recent(q \\ all()),
    do: order_by(q, [grants: g], desc: g.granted_at)

  def ordered_by_granted(q),
    do: order_by(q, [grants: g], asc: g.granted_at)

  def by_action_id(q, action_id),
    do: where(q, [grants: g], g.action_id == ^action_id)

  @doc """
  Match `runner_id` exactly, OR allow a wildcard grant (where
  `runner_id IS NULL`). When the caller has no runner, only wildcard
  grants match.
  """
  def by_runner_or_wildcard(q, nil),
    do: where(q, [grants: g], is_nil(g.runner_id))

  def by_runner_or_wildcard(q, runner_id),
    do: where(q, [grants: g], is_nil(g.runner_id) or g.runner_id == ^runner_id)

  def by_args_sha_or_wildcard(q, nil),
    do: where(q, [grants: g], is_nil(g.args_sha256))

  def by_args_sha_or_wildcard(q, args_sha),
    do: where(q, [grants: g], is_nil(g.args_sha256) or g.args_sha256 == ^args_sha)

  @doc """
  Candidates for `peek_matching_grant/4` — narrows by api_key + action
  + un-revoked + not-yet-expired. Caller composes runner / args_sha
  match on top.
  """
  def candidates_for_dispatch(api_key_id, action_id, now) do
    all()
    |> by_api_key_id(api_key_id)
    |> by_action_id(action_id)
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

  def consume_one(q, now) do
    update(q,
      inc: [uses_count: 1],
      set: [last_used_at: ^now, updated_at: ^now]
    )
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:grants, :desc, :granted_at}, {:grants, :asc, :id}]
end
