defmodule Emisar.Repo.Migrations.RetireScimUserResources do
  @moduledoc """
  Give the SCIM wire resource its own tombstone.

  A user identity is shared by OIDC login and SCIM lifecycle. Reusing the row's
  global `deleted_at` for `DELETE /Users` released the one-live-identity and
  externalId reservations, so an OIDC approval could occupy either slot before
  the directory recreated the resource. The directory tombstone must hide only
  SCIM addressability while the shared identity row remains reserved.
  """
  use Ecto.Migration

  def up do
    alter table(:sso_user_identities) do
      add :scim_deleted_at, :utc_datetime_usec
    end
  end

  def down do
    raise "retired SCIM resources cannot be restored safely by dropping their tombstone"
  end
end
