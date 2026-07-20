defmodule Emisar.Repo.Migrations.BindApprovalGrantsToPackRef do
  use Ecto.Migration

  def up do
    alter table(:approval_grants) do
      add :pack_ref, :string
    end

    execute("""
    UPDATE approval_grants AS grants
    SET pack_ref = run.pack_ref
    FROM approval_requests AS request
    JOIN action_runs AS run ON run.id = request.run_id
    WHERE grants.approval_request_id = request.id
      AND run.pack_ref IS NOT NULL
    """)

    execute("""
    UPDATE approval_grants
    SET revoked_at = COALESCE(revoked_at, NOW()), updated_at = NOW()
    WHERE pack_ref IS NULL
    """)

    create constraint(:approval_grants, :approval_grants_contract_or_revoked,
             check: "pack_ref IS NOT NULL OR revoked_at IS NOT NULL"
           )

    create index(:approval_grants, [:api_key_id, :action_id, :pack_ref])
  end

  def down do
    drop index(:approval_grants, [:api_key_id, :action_id, :pack_ref])
    drop constraint(:approval_grants, :approval_grants_contract_or_revoked)

    alter table(:approval_grants) do
      remove :pack_ref
    end
  end
end
