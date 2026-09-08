defmodule Emisar.Repo.Migrations.ExpireConsoleInstallKeys do
  use Ecto.Migration

  def up do
    # Older code cleared the origin on first use. Recover it only from the
    # recorded auto-key binding, never from a user-editable description.
    execute("""
    UPDATE runner_enrollment_keys AS key
    SET auto_generated_at = key.inserted_at
    WHERE key.auto_generated_at IS NULL
      AND EXISTS (
        SELECT 1 FROM audit_events AS event
        WHERE event.account_id = key.account_id
          AND event.target_id = key.id
          AND event.target_kind = 'enrollment_key'
          AND event.event_type = 'enrollment_key.bound'
          AND event.payload @> '{"auto": true}'::jsonb
      )
    """)

    # Existing unused setup commands get the same lifetime as new ones.
    # Used keys and manually created keys retain their original expiry.
    execute("""
    UPDATE runner_enrollment_keys
    SET expires_at = LEAST(expires_at, auto_generated_at + interval '24 hours')
    WHERE auto_generated_at IS NOT NULL
      AND last_used_at IS NULL
      AND uses_count = 0
      AND deleted_at IS NULL
    """)
  end

  # Rolling back code must not make expired credentials valid again or erase
  # recovered provenance. No schema change needs reversing.
  def down, do: :ok
end
