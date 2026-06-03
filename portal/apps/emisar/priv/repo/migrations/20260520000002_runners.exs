defmodule Emisar.Repo.Migrations.Runners do
  use Ecto.Migration

  def change do
    # A runner is one emisar binary running on a host. Runners belong
    # to exactly one account. `group` is a free-form label the cloud UI
    # auto-groups by ("cassandra-us-east1", "db-primary", etc.).
    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # `name` is operator-facing and per-account unique (so MCP clients
      # and policies can address a runner by name). `external_id` is
      # the runner-advertised UUID, stable across reconnects.
      add :name, :string, null: false
      add :external_id, :string
      add :group, :string, null: false
      add :hostname, :string
      add :labels, :map, null: false, default: %{}

      # Build / liveness.
      add :runner_version, :string
      add :status, :string, null: false, default: "pending"
      add :last_connected_at, :utc_datetime_usec
      add :last_disconnected_at, :utc_datetime_usec
      add :last_disconnect_reason, :string
      add :last_heartbeat_at, :utc_datetime_usec
      add :action_load, :integer, null: false, default: 0

      # Most-recent advertised pack inventory (id -> %{version, hash}).
      add :packs, :map, null: false, default: %{}

      # Optional bootstrap auth-key reference; remains nil once the
      # runner has exchanged for a per-runner token.
      add :bootstrap_auth_key_id, :binary_id

      add :disabled_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # A runner's durable identity. The runner persists this and presents
    # it on every register, so reconnects map back to the same row.
    create unique_index(:runners, [:account_id, :external_id])
    # `name` (defaults to hostname) is the operator/LLM-facing address.
    # It's unique among LIVE runners — see 20260603030000, which swaps this
    # plain index for a partial unique one (`WHERE deleted_at IS NULL`).
    # Identity is still external_id; a re-registering host that can't claim
    # a taken name gets a clean 409 to resolve (delete/rename the other
    # runner), never a crash. Partial so deleting a runner frees its name.
    create index(:runners, [:account_id, :name])
    create index(:runners, [:account_id, :group])
    create index(:runners, [:account_id, :status])

    # Auth keys are reusable or single-use bootstrap secrets issued by
    # the cloud UI. The runner presents one on first connect and
    # exchanges it for a per-runner token (see `runner_tokens` below).
    # Modeled on Tailscale's auth keys.
    create table(:runner_auth_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

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

    create unique_index(:runner_auth_keys, [:key_prefix])
    create index(:runner_auth_keys, [:account_id])

    # Per-runner token: long-lived secret minted at first registration.
    # Presented on every reconnect. Rotatable; revoking deletes the
    # row and the runner has to re-bootstrap with an auth key.
    create table(:runner_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :token_prefix, :string, null: false
      add :token_hash, :binary, null: false

      add :issued_via_key_id,
          references(:runner_auth_keys, type: :binary_id, on_delete: :nilify_all)

      add :issued_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runner_tokens, [:token_prefix])
    create index(:runner_tokens, [:runner_id])
  end
end
