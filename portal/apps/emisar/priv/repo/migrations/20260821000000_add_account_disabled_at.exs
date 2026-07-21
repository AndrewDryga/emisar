defmodule Emisar.Repo.Migrations.AddAccountDisabledAt do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :disabled_at, :utc_datetime_usec
    end
  end
end
