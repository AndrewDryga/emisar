defmodule Emisar.Accounts.Membership.Query do
  use Emisar, :query
  alias Emisar.{ApiKeys, Auth}
  alias Emisar.Repo.{Filter, Like}

  def all,
    do: from(memberships in Emisar.Accounts.Membership, as: :memberships)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [memberships: m], is_nil(m.deleted_at))

  def not_disabled(queryable \\ all()),
    do: where(queryable, [memberships: m], is_nil(m.disabled_at))

  @doc "Exclude unresolved account invitations, which grant no authority until acceptance."
  def not_pending_invitation(queryable \\ all()) do
    where(
      queryable,
      [memberships: m],
      not (is_nil(m.invitation_accepted_at) and not is_nil(m.invitation_token_digest))
    )
  end

  @doc "Memberships that currently grant account access."
  def authorized(queryable \\ all()) do
    queryable
    |> not_deleted()
    |> not_disabled()
    |> not_pending_invitation()
  end

  def by_id(queryable, id),
    do: where(queryable, [memberships: m], m.id == ^id)

  def removed(queryable \\ all()),
    do: where(queryable, [memberships: m], not is_nil(m.deleted_at))

  @doc "The fail-closed scope: a session that may act in no account reads nothing."
  def none(queryable), do: where(queryable, false)

  def not_id(queryable, id),
    do: where(queryable, [memberships: m], m.id != ^id)

  def by_ids(queryable, ids) when is_list(ids),
    do: where(queryable, [memberships: m], m.id in ^ids)

  def by_account_id(queryable, account_id),
    do: where(queryable, [memberships: m], m.account_id == ^account_id)

  def by_account_ids(queryable, account_ids) when is_list(account_ids),
    do: where(queryable, [memberships: m], m.account_id in ^account_ids)

  # Read credential validity and membership scope in one database snapshot.
  # A revoked or expired bearer cannot resolve the membership's current scope.
  def by_active_api_key_id(queryable, key_id, now) do
    join(queryable, :inner, [memberships: m], key in ApiKeys.ApiKey,
      as: :scope_api_key,
      on:
        key.id == ^key_id and key.created_by_membership_id == m.id and
          key.account_id == m.account_id and is_nil(key.deleted_at) and
          is_nil(key.revoked_at) and (is_nil(key.expires_at) or key.expires_at > ^now)
    )
  end

  def by_role(queryable, role),
    do: where(queryable, [memberships: m], m.role == ^role)

  def ordered_by_id(queryable),
    do: order_by(queryable, [memberships: m], asc: m.id)

  def after_id(queryable, id),
    do: where(queryable, [memberships: m], m.id > ^id)

  def by_roles(queryable, roles),
    do: where(queryable, [memberships: m], m.role in ^roles)

  @doc "Membership activity is stale when it has never been recorded or predates `cutoff`."
  def last_active_before(queryable, %DateTime{} = cutoff) do
    where(
      queryable,
      [memberships: m],
      is_nil(m.last_active_at) or m.last_active_at < ^cutoff
    )
  end

  def select_ids(queryable), do: select(queryable, [memberships: m], m.id)

  def by_directory_provider_or_unmanaged(queryable, provider_id) do
    where(
      queryable,
      [memberships: m],
      is_nil(m.directory_provider_id) or m.directory_provider_id == ^provider_id
    )
  end

  def authorization_sync_pending(queryable \\ all()) do
    where(
      queryable,
      [memberships: m],
      not is_nil(m.directory_authorization_pending_version)
    )
  end

  # Oldest-touched first, so a bounded batch over the fail-closed set is
  # deterministic rather than whatever the planner hands back. A successful
  # reconcile clears the pending version and leaves the set entirely, so the
  # queue drains instead of re-serving the same arbitrary rows.
  def ordered_by_least_recently_updated(queryable),
    do: order_by(queryable, [memberships: m], asc: m.updated_at, asc: m.id)

  def limit_to(queryable, limit), do: limit(queryable, ^limit)

  def by_invitation_token_digest(queryable, digest),
    do: where(queryable, [memberships: m], m.invitation_token_digest == ^digest)

  def pending_invitation(queryable) do
    where(
      queryable,
      [memberships: m],
      is_nil(m.invitation_accepted_at) and not is_nil(m.invitation_token_digest)
    )
  end

  # Invitation links lapse after a week — long enough for a weekend
  # inbox, short enough that a leaked link isn't a standing seat. The
  # row's inserted_at IS the invite time (fresh invites insert rows;
  # resends refresh it with the replacement token).
  @invitation_validity_in_days 7

  @doc "Pending invitations still inside their validity window."
  def invitation_not_expired(queryable) do
    where(
      queryable,
      [memberships: m],
      m.inserted_at > ago(@invitation_validity_in_days, "day")
    )
  end

  @doc "Earliest-joined membership only — orders and limits in one step."
  def oldest(queryable),
    do: queryable |> order_by([memberships: m], asc: m.inserted_at, asc: m.id) |> limit(1)

  @doc """
  Inner-join the membership's active account, idempotently. Use it
  on its own to filter on account columns; pair with a preload via
  `with_preloaded_account/1`. A membership whose account is deleted or disabled
  is dropped (inner join to `active/0`).
  """
  def with_joined_account(queryable) do
    with_named_binding(queryable, :account, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [memberships: m],
        account in ^Emisar.Accounts.Account.Query.active(),
        on: m.account_id == account.id,
        as: ^binding
      )
    end)
  end

  @doc "Join (if needed) and preload the membership's account. See `with_joined_account/1`."
  def with_preloaded_account(queryable) do
    queryable
    |> with_joined_account()
    |> preload([memberships: m, account: account], account: account)
  end

  @doc "Restrict to Members with an enrolled authenticator."
  def with_mfa_enrolled(queryable),
    do: where(queryable, [memberships: m], not is_nil(m.mfa_enabled_at))

  @doc """
  Members that name an address. Only the invited address can accept an
  invitation; an invitation issued before invitations recorded it has none.
  """
  def with_email(queryable),
    do: where(queryable, [memberships: m], not is_nil(m.email))

  @doc "Members whose address was proved by joining (invitation or sign-up), so mail and email sign-in may use it."
  def with_verified_email(queryable) do
    where(queryable, [memberships: m], not is_nil(m.email) and not is_nil(m.email_verified_at))
  end

  @doc "Members with no proved address, which therefore cannot sign in by email."
  def with_unverified_email(queryable),
    do: where(queryable, [memberships: m], is_nil(m.email) or is_nil(m.email_verified_at))

  @doc "Members whose workspace contact is `email`; the citext column compares case-insensitively."
  def by_email(queryable, email),
    do: where(queryable, [memberships: m], m.email == ^email)

  @doc "Select local contact addresses for the workspace deliverability overlay."
  def select_user_emails(queryable) do
    select(queryable, [memberships: m], m.email)
  end

  # -- Pagination + preloads -------------------------------------------

  @impl Emisar.Repo.Query
  def filters do
    role_values = Enum.map(Auth.roles(), &{Atom.to_string(&1), Auth.role_label(&1)})

    [
      %Filter{
        name: :name_or_email,
        title: "Name or email",
        type: :string,
        fun: fn queryable, term ->
          pattern = Like.contains(term)

          {queryable,
           dynamic(
             [memberships: m],
             ilike(m.display_name, ^pattern) or
               ilike(m.email, ^pattern)
           )}
        end
      },
      %Filter{
        name: :role,
        title: "Role",
        type: {:list, :string},
        values: role_values,
        fun: fn queryable, roles -> {queryable, role_dynamic(roles)} end
      },
      %Filter{
        name: :status,
        title: "Status",
        type: {:list, :string},
        values: [
          {"active", "Active"},
          {"pending_invitation", "Pending invitation"},
          {"suspended", "Suspended"}
        ],
        fun: fn queryable, statuses -> {queryable, status_dynamic(statuses)} end
      }
    ]
  end

  defp role_dynamic(roles) do
    chosen =
      Auth.roles()
      |> Enum.filter(&(Atom.to_string(&1) in roles))

    if chosen == [],
      do: dynamic(true),
      else: dynamic([memberships: m], m.role in ^chosen)
  end

  # Statuses intentionally overlap. A suspended invitation remains both
  # suspended and pending, so either lens can find it. "Active" is the clean
  # complement: enabled and no unresolved invitation.
  defp status_dynamic(statuses) do
    case Enum.filter(statuses, &(&1 in status_values())) do
      [] -> dynamic(true)
      chosen -> Enum.reduce(chosen, dynamic(false), &status_or/2)
    end
  end

  defp status_or("active", acc) do
    dynamic(
      [memberships: m],
      ^acc or
        (is_nil(m.disabled_at) and
           not (is_nil(m.invitation_accepted_at) and not is_nil(m.invitation_token_digest)))
    )
  end

  defp status_or("pending_invitation", acc) do
    dynamic(
      [memberships: m],
      ^acc or (is_nil(m.invitation_accepted_at) and not is_nil(m.invitation_token_digest))
    )
  end

  defp status_or("suspended", acc),
    do: dynamic([memberships: m], ^acc or not is_nil(m.disabled_at))

  defp status_values, do: ["active", "pending_invitation", "suspended"]

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:memberships, :desc, :inserted_at}, {:memberships, :asc, :id}]

  @doc """
  Row lock for the last-active-owner guard (`FOR NO KEY UPDATE`):
  concurrent owner demotions/suspensions/removals lock the account's
  owner rows and serialize, so the loser re-counts after the winner
  committed instead of both passing a stale count and orphaning the
  account.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # Each preload is `{scope_query, nested_preloads}` so the associated
  # schema's own preloads/0 cascades — deep nesting composes. The scope is
  # not_deleted/0 so a membership never resolves a soft-deleted account.
  @impl Emisar.Repo.Query
  def preloads,
    do: [
      account:
        {Emisar.Accounts.Account.Query.not_deleted(), Emisar.Accounts.Account.Query.preloads()}
    ]
end
