defmodule Emisar.Repo.Migrations.RenameRunnerAuthKeysToEnrollmentKeys do
  use Ecto.Migration

  # The runner enrollment key: a bearer secret a fresh host presents to ENROLL
  # as a runner (single-use, spent on first registration; or reusable until it
  # expires / hits its max-uses cap). The host then trades it for its own token.
  # The docs already say "enrollment key"; the console + code drifted to "runner
  # key" / AuthKey. Align everything — keeping the `runner_` context prefix its
  # sibling tables use (runner_actions, runner_tokens). Table + its indexes +
  # the runners FK column. The EMISAR_AUTH_KEY env var and the `emkey-auth-`
  # key-string format are wire contracts with the Go runner and stay as-is.
  def change do
    rename table(:runner_auth_keys), to: table(:runner_enrollment_keys)

    # Postgres keeps index names across a table rename — realign them so the DB
    # matches the schema. Nothing maps these by name (the changeset has no
    # unique_constraint), so it's tidiness, not correctness.
    execute(
      "ALTER INDEX runner_auth_keys_pkey RENAME TO runner_enrollment_keys_pkey",
      "ALTER INDEX runner_enrollment_keys_pkey RENAME TO runner_auth_keys_pkey"
    )

    execute(
      "ALTER INDEX runner_auth_keys_account_id_index RENAME TO runner_enrollment_keys_account_id_index",
      "ALTER INDEX runner_enrollment_keys_account_id_index RENAME TO runner_auth_keys_account_id_index"
    )

    execute(
      "ALTER INDEX runner_auth_keys_auto_unused_idx RENAME TO runner_enrollment_keys_auto_unused_idx",
      "ALTER INDEX runner_enrollment_keys_auto_unused_idx RENAME TO runner_auth_keys_auto_unused_idx"
    )

    execute(
      "ALTER INDEX runner_auth_keys_deleted_at_index RENAME TO runner_enrollment_keys_deleted_at_index",
      "ALTER INDEX runner_enrollment_keys_deleted_at_index RENAME TO runner_auth_keys_deleted_at_index"
    )

    execute(
      "ALTER INDEX runner_auth_keys_key_prefix_index RENAME TO runner_enrollment_keys_key_prefix_index",
      "ALTER INDEX runner_enrollment_keys_key_prefix_index RENAME TO runner_auth_keys_key_prefix_index"
    )

    rename table(:runners), :bootstrap_auth_key_id, to: :bootstrap_enrollment_key_id
  end
end
