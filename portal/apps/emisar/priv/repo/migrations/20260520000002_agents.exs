defmodule Emisar.Repo.Migrations.Agents do
  use Ecto.Migration

  def change do
    # An agent is one running emisar binary on a host. Agents belong to
    # exactly one account. Groups (free-form labels) are the cloud UI's
    # auto-grouping key.
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      # Identity. `name` is human-readable; `external_id` is the agent's
      # advertised agent_id (kept stable across re-registers).
      add :name, :string, null: false
      add :external_id, :string
      add :group, :string, null: false
      add :hostname, :string
      add :labels, :map, null: false, default: %{}

      # Build / status.
      add :agent_version, :string
      add :status, :string, null: false, default: "pending"
      add :last_connected_at, :utc_datetime_usec
      add :last_disconnected_at, :utc_datetime_usec
      add :last_disconnect_reason, :string
      add :last_heartbeat_at, :utc_datetime_usec
      add :action_load, :integer, null: false, default: 0

      # Most-recent advertised pack inventory (id -> %{version, hash}).
      add :packs, :map, null: false, default: %{}

      # Optional bootstrap auth-key reference; remains nil once the
      # agent has exchanged for a per-agent token.
      add :bootstrap_auth_key_id, :binary_id

      add :disabled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:account_id, :external_id])
    create index(:agents, [:account_id, :group])
    create index(:agents, [:account_id, :status])

    # Auth keys are reusable or single-use bootstrap secrets issued by
    # the cloud UI. The agent presents one on first connect and
    # exchanges it for a per-agent token (see `agent_tokens` below).
    # Modeled on Tailscale's auth keys.
    create table(:agent_auth_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :key_prefix, :string, null: false
      add :key_hash, :binary, null: false

      add :description, :string
      add :group, :string
      add :reusable, :boolean, null: false, default: false
      add :max_uses, :integer
      add :uses_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :revoked_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_auth_keys, [:key_prefix])
    create index(:agent_auth_keys, [:account_id])

    # Per-agent token: long-lived secret minted at first registration.
    # Presented on every reconnect. Rotatable; revoking deletes the
    # row and the agent has to re-bootstrap with an auth key.
    create table(:agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :token_prefix, :string, null: false
      add :token_hash, :binary, null: false

      add :issued_via_key_id, references(:agent_auth_keys, type: :binary_id, on_delete: :nilify_all)
      add :issued_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_tokens, [:token_prefix])
    create index(:agent_tokens, [:agent_id])
  end
end
