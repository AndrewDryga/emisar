defmodule Emisar.Repo.Migrations.AddReplacesIdToApiKeys do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      # The rotation back-link: a successor key carries the id of the key it
      # replaces (the inverse of rotated_to_id, which marks the SOURCE). First
      # use of the successor retires the replaced chain automatically.
      add :replaces_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
    end

    # Quick-connect ring eviction hard-DELETEs api_key rows — the FK check on
    # each delete needs this to avoid a sequential scan.
    create index(:api_keys, [:replaces_id])
  end
end
