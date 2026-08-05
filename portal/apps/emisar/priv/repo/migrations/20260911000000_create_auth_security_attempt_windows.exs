defmodule Emisar.Repo.Migrations.CreateAuthSecurityAttemptWindows do
  use Ecto.Migration

  def change do
    create table(:auth_security_attempt_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :window_started_at, :utc_datetime_usec, null: false
      add :window_expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_security_attempt_windows, [:user_id, :scope])

    create constraint(:auth_security_attempt_windows, :auth_security_attempt_windows_scope_check,
             check:
               "scope IN ('mfa_challenge', 'inbox_step_up', 'email_change_issue', 'mfa_enrollment_issue')"
           )

    create constraint(
             :auth_security_attempt_windows,
             :auth_security_attempt_windows_attempt_count_check,
             check: "attempt_count >= 0"
           )

    create constraint(
             :auth_security_attempt_windows,
             :auth_security_attempt_windows_window_check,
             check: "window_expires_at >= window_started_at"
           )
  end
end
