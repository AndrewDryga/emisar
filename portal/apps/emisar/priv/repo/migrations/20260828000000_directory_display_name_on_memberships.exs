defmodule Emisar.Repo.Migrations.DirectoryDisplayNameOnMemberships do
  @moduledoc """
  A SCIM rename wrote `users.full_name`, which is the person's own attribute and
  deliberately cross-account: `Emisar.Users` owns identity, `Emisar.Accounts`
  owns tenancy. So one workspace's directory renamed the same person inside every
  other workspace they belong to — text of account A's choosing appearing in
  account B's roster, audit trail, and run attribution.

  The directory's name for a member becomes a property of the MEMBERSHIP, which
  is the thing that workspace actually owns. A rename still reaches
  `users.full_name` when the person belongs to this workspace and no other,
  because then the directory genuinely is the authority for who they are — which
  keeps the common single-workspace case showing one name everywhere.
  """
  use Ecto.Migration

  def change do
    alter table(:account_memberships) do
      add :directory_display_name, :string
    end
  end
end
