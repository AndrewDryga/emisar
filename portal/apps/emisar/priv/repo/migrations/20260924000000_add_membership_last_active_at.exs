defmodule Emisar.Repo.Migrations.AddMembershipLastActiveAt do
  use Ecto.Migration

  def change do
    alter table(:account_memberships) do
      add :last_active_at, :utc_datetime_usec
    end
  end
end
