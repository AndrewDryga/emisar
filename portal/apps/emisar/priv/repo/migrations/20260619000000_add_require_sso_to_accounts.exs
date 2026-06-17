defmodule Emisar.Repo.Migrations.AddRequireSsoToAccounts do
  use Ecto.Migration

  # Corrective (not edit-original): the accounts table is already on prod.
  # Per-account "require SSO" — members must hold an SSO session for the
  # account to access it; sits beside require_mfa.
  def change do
    alter table(:accounts) do
      add :require_sso, :boolean, null: false, default: false
    end
  end
end
