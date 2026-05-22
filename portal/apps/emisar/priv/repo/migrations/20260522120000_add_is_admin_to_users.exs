defmodule Emisar.Repo.Migrations.AddIsAdminToUsers do
  use Ecto.Migration

  @moduledoc """
  Adds a separate `is_admin` flag for emisar-staff operators who can
  reach /admin/live (LiveDashboard, infra surface). Distinct from the
  membership `role` (owner/admin/operator/viewer) which is per-account.
  """

  def change do
    alter table(:users) do
      add :is_admin, :boolean, null: false, default: false
    end
  end
end
