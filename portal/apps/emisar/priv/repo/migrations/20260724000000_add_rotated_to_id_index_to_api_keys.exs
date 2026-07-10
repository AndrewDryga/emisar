defmodule Emisar.Repo.Migrations.AddRotatedToIdIndexToApiKeys do
  use Ecto.Migration

  def change do
    # Mirror the replaces_id index (20260717): quick-connect ring eviction
    # hard-DELETEs api_key rows, and each delete's ON DELETE :nilify_all FK
    # check on this self-referential column needs an index to avoid a
    # sequential scan of the all-tenant api_keys table.
    create index(:api_keys, [:rotated_to_id])
  end
end
