defmodule Emisar.Repo.Migrations.RenameUsersNameToFullName do
  use Ecto.Migration

  # Pre-launch rename. The UI calls this field `full_name` everywhere
  # (sign-up form, dashboard greeting, mailer); the schema used to call
  # it `name`. Aligning both.
  #
  # No-op in current state: the base accounts_and_users migration has
  # been updated to declare `full_name` directly. We keep this migration
  # in the history so deployments that already ran the original
  # `name`-column migration continue to apply this rename, but skip if
  # the column is already correctly named.
  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users' AND column_name = 'name'
      ) THEN
        ALTER TABLE users RENAME COLUMN name TO full_name;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users' AND column_name = 'full_name'
      ) THEN
        ALTER TABLE users RENAME COLUMN full_name TO name;
      END IF;
    END $$;
    """
  end
end
