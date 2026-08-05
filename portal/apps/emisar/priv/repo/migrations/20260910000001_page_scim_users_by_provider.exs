defmodule Emisar.Repo.Migrations.PageScimUsersByProvider do
  @moduledoc """
  SCIM collection reconciliation walks a provider's live identities in stable
  `(inserted_at, id)` order. The provider-only index filters the tenant but
  still leaves PostgreSQL to sort the whole directory for every offset page.

  This partial index matches the collection's scope and order, so the database
  can walk pages directly while omitting retired identities.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX sso_user_identities_scim_page_index
    ON sso_user_identities (account_id, provider_id, inserted_at DESC, id DESC)
    WHERE deleted_at IS NULL
    """
  end

  def down do
    execute "DROP INDEX sso_user_identities_scim_page_index"
  end
end
