defmodule Emisar.SSO.UserIdentity.Query do
  use Emisar, :query
  alias Emisar.SSO.UserIdentity

  def all,
    do: from(identities in UserIdentity, as: :identities)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [identities: i], is_nil(i.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [identities: i], i.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [identities: i], i.account_id == ^account_id)

  # The (provider, sub) binding lookup — the only way an OIDC login resolves
  # to an identity. Never matched by email.
  def by_provider_and_identifier(queryable, provider_id, identifier),
    do:
      where(
        queryable,
        [identities: i],
        i.provider_id == ^provider_id and i.provider_identifier == ^identifier
      )

  def by_user_id(queryable, user_id),
    do: where(queryable, [identities: i], i.user_id == ^user_id)

  def by_ids(queryable, ids),
    do: where(queryable, [identities: i], i.id in ^ids)

  def by_provider_id(queryable, provider_id),
    do: where(queryable, [identities: i], i.provider_id == ^provider_id)

  # The SCIM reconciliation lookup — `(provider, externalId)`. Distinct from
  # `by_provider_and_identifier/3` so a deactivate/fetch by the IdP's
  # externalId stays explicit, even though the two ids coincide today
  # (decision 4).
  def by_provider_and_scim_external_id(queryable, provider_id, scim_external_id),
    do:
      where(
        queryable,
        [identities: i],
        i.provider_id == ^provider_id and i.scim_external_id == ^scim_external_id
      )

  # Resolve a group's SCIM member ids (decision 4: an externalId may arrive as
  # either side of the binding) to this provider's identities — the union of a
  # `scim_external_id` or a `provider_identifier` match. Unknown ids match
  # nothing (the member may not be provisioned yet).
  def by_provider_and_external_ids(queryable, provider_id, external_ids),
    do:
      where(
        queryable,
        [identities: i],
        i.provider_id == ^provider_id and
          (i.scim_external_id in ^external_ids or i.provider_identifier in ^external_ids)
      )

  # The SCIM `GET /Users?filter=userName eq "x"` existence probe, matched in
  # the QUERY so it finds a user anywhere in the directory — not just the page
  # the IdP happened to fetch. `userName` is the rendered handle
  # (`claims.email` → `scim_external_id` → `provider_identifier`, per
  # `SCIM.Resource`), compared case-insensitively.
  def by_user_name(queryable, user_name),
    do:
      where(
        queryable,
        [identities: i],
        fragment(
          "lower(coalesce(?->>'email', ?, ?)) = lower(?)",
          i.claims,
          i.scim_external_id,
          i.provider_identifier,
          ^user_name
        )
      )

  # The SCIM `filter=externalId eq "x"` probe — the rendered externalId is
  # `scim_external_id` falling back to `provider_identifier` (decision 4).
  def by_external_id(queryable, external_id),
    do:
      where(
        queryable,
        [identities: i],
        coalesce(i.scim_external_id, i.provider_identifier) == ^external_id
      )

  def ordered_by_recent(queryable),
    do: order_by(queryable, [identities: i], desc: i.inserted_at, desc: i.id)

  # Keyset-pagination cursor for `Repo.list/3` (the SCIM `GET /Users` probe).
  # Matches `ordered_by_recent/1` so the page order and the cursor agree.
  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:identities, :desc, :inserted_at}, {:identities, :desc, :id}]
end
