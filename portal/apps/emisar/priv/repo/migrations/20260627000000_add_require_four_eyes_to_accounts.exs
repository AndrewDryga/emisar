defmodule Emisar.Repo.Migrations.AddRequireFourEyesToAccounts do
  use Ecto.Migration

  # Corrective (not edit-original): the accounts table is already on prod.
  # Per-account "require four-eyes" — when on, a gated action can never be
  # approved by its own requester, regardless of the policy's self-approval
  # setting (an owner lock admins can't loosen per-ruleset). Sits beside
  # require_mfa / require_sso.
  def change do
    alter table(:accounts) do
      add :require_four_eyes, :boolean, null: false, default: false
    end
  end
end
