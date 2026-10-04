defmodule Emisar.Repo.Migrations.AddServiceAccounts do
  use Ecto.Migration

  # A service account is a Member an app connects as. It never holds an address,
  # an invitation or a factor, so no emailed code, invitation or SSO match can
  # sign anyone in as it. It holds the operator role: the least role whose keys
  # authenticate, and never one that administers the workspace.
  def change do
    alter table(:account_memberships) do
      add :kind, :string, null: false, default: "human"
    end

    create constraint(:account_memberships, :account_memberships_kind_check,
             check: "kind IN ('human', 'service_account')"
           )

    create constraint(:account_memberships, :account_memberships_service_account_check,
             check: """
             kind <> 'service_account' OR (
               role = 'operator' AND display_name IS NOT NULL
               AND email IS NULL AND email_verified_at IS NULL
               AND invitation_token_digest IS NULL
               AND mfa_secret IS NULL AND mfa_enabled_at IS NULL
             )
             """
           )

    # The person who received a key acting as another member — a service
    # account's key, or a successor someone rotated for a teammate. It outlives
    # the audit row of the mint, so a long-lived connection keeps naming a human
    # until staff erase that person.
    alter table(:api_keys) do
      add :issued_by_membership_id,
          references(:account_memberships,
            type: :binary_id,
            with: [account_id: :account_id],
            on_delete: {:nilify, [:issued_by_membership_id]}
          )
    end

    create index(:api_keys, [:issued_by_membership_id])
  end
end
