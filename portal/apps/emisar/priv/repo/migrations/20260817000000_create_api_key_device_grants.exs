defmodule Emisar.Repo.Migrations.CreateApiKeyDeviceGrants do
  use Ecto.Migration

  def change do
    # Device-authorization grants (RFC 8628 shape) for connecting local MCP
    # clients without copying the API key: the installer opens a grant and
    # polls with the device code, the operator approves by user code in the
    # portal, and the claim mints one api_keys row per requested client —
    # secrets delivered over the poll exactly once.
    create table(:api_key_device_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :status, :string, null: false, default: "pending"

      # Digests only — the raw device code (poll credential) and user code
      # (short human approval code) never persist.
      add :device_code_digest, :string, null: false
      add :user_code_digest, :string, null: false

      add :requested_clients, {:array, :string}, null: false, default: []
      add :requester_ip, :string

      add :expires_at, :utc_datetime_usec, null: false

      # Bound at approval — the approver's identity is what authorizes the
      # claim-time key mint, so all three stay nullable while pending.
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all)
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :approved_by_membership_id,
          references(:account_memberships, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_key_device_grants, [:device_code_digest])

    # One live pending grant per user code; terminal rows may recycle a code.
    create unique_index(:api_key_device_grants, [:user_code_digest],
             where: "status = 'pending'",
             name: :api_key_device_grants_pending_user_code_index
           )

    create index(:api_key_device_grants, [:status, :expires_at])

    create constraint(:api_key_device_grants, :api_key_device_grants_status_check,
             check: "status IN ('pending', 'approved', 'denied', 'claimed', 'expired')"
           )
  end
end
