defmodule Emisar.Repo.Migrations.AddDisabledByToAccountMemberships do
  use Ecto.Migration

  def change do
    alter table(:account_memberships) do
      add :disabled_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:account_memberships, [:disabled_by_id])
  end
end
