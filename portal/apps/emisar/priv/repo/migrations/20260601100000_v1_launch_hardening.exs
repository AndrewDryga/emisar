defmodule Emisar.Repo.Migrations.V1LaunchHardening do
  use Ecto.Migration

  def change do
    # MFA recovery codes — 10 single-use codes hashed (sha256 over the
    # raw 32-byte token) so the DB leak doesn't reveal the codes. The
    # column is an array of binaries because the count is bounded and
    # checking inclusion is one query. `mfa_last_used_at` blocks TOTP
    # replay inside the 30s window.
    alter table(:users) do
      add :mfa_recovery_codes, {:array, :binary}, default: []
      add :mfa_last_used_at, :utc_datetime_usec
    end

    # MCP idempotency. The bridge / LLM client passes
    # `Idempotency-Key: <uuid>` on POST /tools; we attach it to the run
    # row and unique-index on (api_key_id, idempotency_key) so a retried
    # call returns the original run instead of double-dispatching.
    alter table(:action_runs) do
      add :idempotency_key, :string
    end

    create unique_index(:action_runs, [:api_key_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :action_runs_api_key_idempotency_key_index
           )

    # Per-user runner scope inheritance for API keys. Today MCP bypasses
    # the per-membership scope; with this FK every key carries the
    # creator's membership and the dispatch path applies whatever scope
    # the membership currently has (so revoking the user's scope shrinks
    # all their keys automatically).
    alter table(:api_keys) do
      add :created_by_membership_id,
          references(:memberships, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:api_keys, [:created_by_membership_id])
  end
end
