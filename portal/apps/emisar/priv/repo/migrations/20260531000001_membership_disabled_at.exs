defmodule Emisar.Repo.Migrations.MembershipDisabledAt do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      add :disabled_at, :utc_datetime_usec, null: true
    end

    # Partial index — only suspended memberships sit in it, so the common
    # "active memberships" reads (`WHERE disabled_at IS NULL`) stay fast.
    create index(:memberships, [:disabled_at], where: "disabled_at IS NOT NULL")
  end
end
