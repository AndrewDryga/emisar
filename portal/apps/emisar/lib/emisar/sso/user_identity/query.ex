defmodule Emisar.SSO.UserIdentity.Query do
  use Emisar, :query
  alias Emisar.SSO.UserIdentity

  def all,
    do: from(identities in UserIdentity, as: :identities)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [identities: i], is_nil(i.deleted_at))

  def scim_not_deleted(queryable \\ all()),
    do: where(queryable, [identities: i], is_nil(i.scim_deleted_at))

  def scim_deleted(queryable \\ all()),
    do: where(queryable, [identities: i], not is_nil(i.scim_deleted_at))

  def provider_identifier_active(queryable \\ all()),
    do: where(queryable, [identities: i], is_nil(i.provider_identifier_retired_at))

  def by_id(queryable, id),
    do: where(queryable, [identities: i], i.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [identities: i], i.account_id == ^account_id)

  def excluding_account_id(queryable, account_id),
    do: where(queryable, [identities: i], i.account_id != ^account_id)

  # The (provider, sub) binding lookup — the only way an OIDC login resolves
  # to an identity. Never matched by email.
  def by_provider_and_identifier(queryable, provider_id, identifier) do
    queryable
    |> provider_identifier_active()
    |> where(
      [identities: i],
      i.provider_id == ^provider_id and i.provider_identifier == ^identifier
    )
  end

  def by_provider_identifier(queryable, identifier),
    do: where(queryable, [identities: i], i.provider_identifier == ^identifier)

  def by_user_id(queryable, user_id),
    do: where(queryable, [identities: i], i.user_id == ^user_id)

  @doc """
  Row lock for the SCIM update transition (`FOR NO KEY UPDATE`): concurrent
  directory operations on the same identity serialize here, so each one's
  guards and name merge judge state the previous writer committed.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # Identities whose (live) provider currently runs directory sync — the
  # "directory-managed" boundary the synced role chip and the profile-name
  # lock share. Disabling SCIM on the provider unmatches automatically.
  def scim_managed(queryable) do
    queryable
    |> with_joined_provider()
    |> where([provider: p], p.scim_enabled == true)
  end

  @doc """
  Identities an ADMIN approved, rather than ones the directory itself asserted.
  These are the bindings made through a link approval, which is the only path
  where a person inside emisar decides that a credential belongs to someone.
  """
  def admin_approved(queryable \\ all()),
    do: where(queryable, [identities: i], i.created_by == :admin)

  @doc """
  Live OIDC bindings whose authority came from an emisar administrator.

  `created_by` follows the current OIDC binding rather than the row's original
  provisioning path. The forward migration normalizes pre-field-semantics
  directory rebinds once; future approvals set it directly.
  """
  def admin_approved_provider_identifiers(queryable \\ all()) do
    queryable
    |> provider_identifier_active()
    |> admin_approved()
  end

  @doc "Just the ids, for a caller that needs them before and after a bulk write."
  def select_ids(queryable), do: select(queryable, [identities: i], i.id)

  def by_user_ids(queryable, user_ids),
    do: where(queryable, [identities: i], i.user_id in ^user_ids)

  # Join (if needed) + preload the identity's provider — powers the team page's
  # "synced from <provider>" attribution and the provider's synced-users list.
  # Matched on the account as well as the id: the identity carries its own
  # `account_id`, so joining on the id alone would let a row whose provider was
  # moved or mis-stamped resolve a connection from another tenant.
  def with_joined_provider(queryable) do
    with_named_binding(queryable, :provider, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [identities: i],
        provider in ^Emisar.SSO.IdentityProvider.Query.not_deleted(),
        on: i.provider_id == provider.id and i.account_id == provider.account_id,
        as: ^binding
      )
    end)
  end

  # Directory-managed identities first, then provider name and id — a person who
  # holds identities on several connections always attributes to the same one
  # instead of whichever row the database happened to return first.
  def ordered_by_directory_precedence(queryable) do
    queryable
    |> with_joined_provider()
    |> order_by([identities: i, provider: p], desc: p.scim_enabled, asc: p.name, asc: p.id)
  end

  # `{user_id, provider_id, provider_name, provisioned_via, directory_managed?}` —
  # the roster's narrow attribution projection. The connection's configuration
  # (secrets, claim mapping, defaults) never leaves the query.
  def select_directory_facts(queryable) do
    queryable
    |> with_joined_provider()
    |> select(
      [identities: i, provider: p],
      {i.user_id, i.provider_id, p.name, i.provisioned_via, p.scim_enabled}
    )
  end

  def with_preloaded_provider(queryable) do
    queryable
    |> with_joined_provider()
    |> preload([identities: i, provider: provider], provider: provider)
  end

  # Join (if needed) + preload the identity's user — for the provider's
  # synced-users list (name/email alongside the SCIM external id + state).
  def with_joined_user(queryable) do
    with_named_binding(queryable, :user, fn queryable, binding ->
      join(
        queryable,
        :inner,
        [identities: i],
        user in ^Emisar.Users.User.Query.not_deleted(),
        on: i.user_id == user.id,
        as: ^binding
      )
    end)
  end

  def with_preloaded_user(queryable) do
    queryable
    |> with_joined_user()
    |> preload([identities: i, user: user], user: user)
  end

  @doc """
  Identities the directory has not stamped yet. Lets adoption write under the
  same condition it decided on, so two pushes cannot both claim one row.
  """
  def without_scim_external_id(queryable \\ all()),
    do: where(queryable, [identities: i], is_nil(i.scim_external_id))

  def by_ids(queryable, ids),
    do: where(queryable, [identities: i], i.id in ^ids)

  def by_provider_id(queryable, provider_id),
    do: where(queryable, [identities: i], i.provider_id == ^provider_id)

  def excluding_provider_id(queryable, provider_id),
    do: where(queryable, [identities: i], i.provider_id != ^provider_id)

  def with_enabled_provider(queryable) do
    queryable
    |> with_joined_provider()
    |> where([provider: provider], provider.enabled == true)
  end

  def select_user_ids(queryable \\ all()),
    do: select(queryable, [identities: i], i.user_id)

  # {provider_id, count} rows — the per-connection synced-user tallies for the
  # overview. Group by provider so one query covers every connection.
  def count_by_provider(queryable) do
    queryable
    |> group_by([identities: i], i.provider_id)
    |> select([identities: i], {i.provider_id, count(i.id)})
  end

  # POST reconciliation and externalId filters use the IdP-owned correlation
  # value. Resource routes use the identity row's server-issued id instead.
  def by_provider_and_scim_external_id(queryable, provider_id, scim_external_id) do
    where(
      queryable,
      [identities: i],
      i.provider_id == ^provider_id and i.scim_external_id == ^scim_external_id
    )
  end

  # The SCIM `GET /Users?filter=userName eq "x"` existence probe, matched in
  # the QUERY so it finds a user anywhere in the directory — not just the page
  # the IdP happened to fetch. The coalesce chain mirrors the rendered handle in
  # `SCIM.Resource.user_name/2` exactly — user email, then the `preferred_username`
  # / `nickname` claims, then the identifiers. Any step the renderer can pick and
  # this cannot is a `userName` we hand back and then fail to find.
  def by_user_name(queryable, user_name) do
    queryable
    |> with_joined_user()
    |> where(
      [identities: i, user: u],
      fragment(
        """
        lower(coalesce(
          nullif(?, ''),
          nullif(?->>'email', ''),
          nullif(?->>'preferred_username', ''),
          nullif(?->>'nickname', ''),
          ?,
          ?
        )) = lower(?)
        """,
        u.email,
        i.claims,
        i.claims,
        i.claims,
        i.scim_external_id,
        i.provider_identifier,
        ^user_name
      )
    )
  end

  # The SCIM `filter=externalId eq "x"` probe — the rendered externalId is
  # `scim_external_id` falling back to `provider_identifier` (decision 4).
  def by_external_id(queryable, external_id) do
    where(
      queryable,
      [identities: i],
      coalesce(i.scim_external_id, i.provider_identifier) == ^external_id
    )
  end

  def ordered_by_recent(queryable),
    do: order_by(queryable, [identities: i], desc: i.inserted_at, desc: i.id)

  def latest_scim_deleted(queryable) do
    queryable
    |> order_by([identities: i], desc: i.scim_deleted_at, desc: i.inserted_at, desc: i.id)
    |> limit(1)
  end

  def offset_page(queryable, offset, limit),
    do: queryable |> offset(^offset) |> limit(^limit)

  # Keyset-pagination cursor for `Repo.list/3` (the SCIM `GET /Users` probe).
  # Matches `ordered_by_recent/1` so the page order and the cursor agree.
  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:identities, :desc, :inserted_at}, {:identities, :desc, :id}]
end
