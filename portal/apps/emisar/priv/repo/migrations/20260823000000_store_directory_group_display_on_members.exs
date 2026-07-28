defmodule Emisar.Repo.Migrations.StoreDirectoryGroupDisplayOnMembers do
  @moduledoc """
  A synced group's human name only ever lived on its role mapping, so a group
  nobody had mapped answered SCIM reads on its raw externalId. An IdP that
  matches groups by displayName (Entra does) therefore never found the group it
  had just pushed, and re-created it every cycle.

  Denormalised onto the membership rows because there is no group table — a
  synced group IS its member rows. Nullable: existing rows carry no display
  until their directory pushes the group again, and the read still falls back to
  the mapping's display meanwhile.
  """
  use Ecto.Migration

  def change do
    alter table(:sso_directory_group_members) do
      add :external_group_display, :string
    end
  end
end
