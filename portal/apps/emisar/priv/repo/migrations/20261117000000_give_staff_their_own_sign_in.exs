defmodule Emisar.Repo.Migrations.GiveStaffTheirOwnSignIn do
  use Ecto.Migration

  # Staff stop being a flag on the shared personal login. A staff login is its own
  # row with a mandatory authenticator secret, created and reset only by a command
  # on the production node, with its own sign-in codes and sessions. Nothing a
  # workspace, an identity provider or configuration controls can create one, so
  # the old flag is dropped rather than migrated: staff create a new login after
  # deploy.
  def up do
    create table(:admin_staff, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :mfa_secret, :binary, null: false
      add :mfa_last_used_at, :utc_datetime_usec
      add :failed_mfa_attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:admin_staff, [:email])

    create constraint(:admin_staff, :admin_staff_failed_mfa_attempts_check,
             check: "failed_mfa_attempts >= 0"
           )

    create table(:admin_staff_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :staff_id, references(:admin_staff, type: :binary_id, on_delete: :delete_all),
        null: false

      add :context, :string, null: false
      add :token, :binary, null: false
      add :remaining_attempts, :integer
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:admin_staff_tokens, [:token])
    create index(:admin_staff_tokens, [:staff_id, :context])

    create constraint(:admin_staff_tokens, :admin_staff_tokens_context_check,
             check: "context IN ('sign_in', 'session')"
           )

    # A sign-in code carries its own guess budget; a session carries none.
    create constraint(:admin_staff_tokens, :admin_staff_tokens_remaining_attempts_check,
             check: """
             (context = 'sign_in' AND remaining_attempts IS NOT NULL AND remaining_attempts >= 0)
             OR (context = 'session' AND remaining_attempts IS NULL)
             """
           )

    alter table(:users) do
      remove :is_admin
    end
  end

  def down do
    alter table(:users) do
      add :is_admin, :boolean, null: false, default: false
    end

    drop table(:admin_staff_tokens)
    drop table(:admin_staff)
  end
end
