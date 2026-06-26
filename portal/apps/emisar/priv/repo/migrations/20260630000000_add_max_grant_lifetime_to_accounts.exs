defmodule Emisar.Repo.Migrations.AddMaxGrantLifetimeToAccounts do
  use Ecto.Migration

  # Corrective (not edit-original): the accounts table is already on prod.
  # Per-account cap on the maximum standing-grant DURATION an account may mint
  # (nil = no cap); enforced in Approvals.create_grant/4. Sits beside the other
  # account security settings (require_mfa / require_sso).
  def change do
    alter table(:accounts) do
      add :max_grant_lifetime_seconds, :integer, null: true
    end
  end
end
