defmodule Emisar.Accounts.Account.Query do
  use Emisar, :query

  def all,
    do: from(accounts in Emisar.Accounts.Account, as: :accounts)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [accounts: a], is_nil(a.deleted_at))

  def active(queryable \\ not_deleted()),
    do: where(queryable, [accounts: a], is_nil(a.disabled_at))

  def by_id(queryable, id),
    do: where(queryable, [accounts: a], a.id == ^id)

  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # Keyset paging by id (UUIDv7, time-ordered) — system sweep account
  # cursor: order by id, take a page, continue past the last id.
  def after_id(queryable, id),
    do: where(queryable, [accounts: a], a.id > ^id)

  def by_slug(queryable, slug),
    do: where(queryable, [accounts: a], a.slug == ^slug)

  def by_paddle_customer_id(queryable, customer_id),
    do: where(queryable, [accounts: a], a.paddle_customer_id == ^customer_id)

  def ordered_by_name(queryable),
    do: order_by(queryable, [accounts: a], asc: a.name)

  def ordered_by_id(queryable),
    do: order_by(queryable, [accounts: a], asc: a.id)

  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  @doc """
  Accounts whose monthly value report is due at `cutoff` (start of the current
  month): never sent, or last sent in an earlier month. Pairs with the report
  job's per-month cadence.
  """
  def due_for_report(queryable, %DateTime{} = cutoff) do
    where(
      queryable,
      [accounts: a],
      is_nil(a.last_report_sent_at) or a.last_report_sent_at < ^cutoff
    )
  end

  @doc """
  Accounts whose Paddle Customer is missing or stale. The billing contact is
  stable while the stored user remains an active owner with a confirmed email;
  when that owner is removed, suspended, demoted, deleted, or changes email, the
  next customer-sync sweep reselects/updates Paddle.
  """
  def needing_paddle_customer_sync(queryable) do
    queryable
    |> with_joined_paddle_billing_contact_membership()
    |> with_joined_paddle_billing_contact_user()
    |> where(
      [
        accounts: a,
        paddle_billing_contact_membership: m,
        paddle_billing_contact_user: u
      ],
      is_nil(a.paddle_customer_id) or
        is_nil(a.paddle_billing_contact_user_id) or
        is_nil(a.paddle_customer_synced_at) or
        a.updated_at > a.paddle_customer_synced_at or
        is_nil(m.id) or
        m.updated_at > a.paddle_customer_synced_at or
        is_nil(u.id) or
        is_nil(u.email) or
        is_nil(u.confirmed_at) or
        u.updated_at > a.paddle_customer_synced_at
    )
  end

  defp with_joined_paddle_billing_contact_membership(queryable) do
    with_named_binding(queryable, :paddle_billing_contact_membership, fn queryable, binding ->
      join(
        queryable,
        :left,
        [accounts: a],
        membership in ^Emisar.Accounts.Membership.Query.not_deleted(),
        on:
          membership.account_id == a.id and
            membership.user_id == a.paddle_billing_contact_user_id and
            membership.role == :owner and
            is_nil(membership.disabled_at),
        as: ^binding
      )
    end)
  end

  defp with_joined_paddle_billing_contact_user(queryable) do
    with_named_binding(queryable, :paddle_billing_contact_user, fn queryable, binding ->
      join(
        queryable,
        :left,
        [accounts: a],
        user in ^Emisar.Users.User.Query.not_deleted(),
        on: user.id == a.paddle_billing_contact_user_id,
        as: ^binding
      )
    end)
  end

  @doc """
  Restrict to accounts the given user is a member of — joins through
  membership on `membership.user_id` and excludes suspended memberships
  (`disabled_at`). Used by the "switch account" picker, so a suspended user
  isn't shown the tenant that suspended them. The join composes
  `Membership.Query.not_deleted/0` so a tombstoned membership can't
  resurface an account either.
  """
  def by_membership_user_id(queryable, user_id) do
    queryable
    |> join(:inner, [accounts: a], m in ^Emisar.Accounts.Membership.Query.not_deleted(),
      on: m.account_id == a.id,
      as: :memberships
    )
    |> where([memberships: m], m.user_id == ^user_id and is_nil(m.disabled_at))
  end

  # -- Pagination ------------------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:accounts, :asc, :name}, {:accounts, :asc, :id}]

  # No nested preloads cascade when an account is loaded through the
  # Preloader; declared so callers can compose `{not_deleted(), preloads()}`.
  @impl Emisar.Repo.Query
  def preloads, do: []
end
