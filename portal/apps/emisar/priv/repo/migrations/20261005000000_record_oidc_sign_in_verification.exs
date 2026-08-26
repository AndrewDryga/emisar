defmodule Emisar.Repo.Migrations.RecordOidcSignInVerification do
  use Ecto.Migration

  def change do
    alter table(:sso_identity_providers) do
      add :sign_in_verified_at, :utc_datetime_usec

      add :sign_in_verified_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :sign_in_verified_identity_id,
          references(:sso_user_identities, type: :binary_id, on_delete: :nilify_all)

      add :sign_in_verified_configuration_digest, :binary
    end
  end
end
