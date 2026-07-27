defmodule Emisar.Repo.Migrations.StoreRunnerRetentionInHours do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET settings =
      CASE
        WHEN jsonb_typeof(settings->'runner_inactive_retention_days') = 'number' THEN
          (settings - 'runner_inactive_retention_days') ||
            jsonb_build_object(
              'runner_inactive_retention_hours',
              (settings->>'runner_inactive_retention_days')::integer * 24
            )
        ELSE settings - 'runner_inactive_retention_days'
      END
    WHERE jsonb_typeof(settings) = 'object'
      AND settings ? 'runner_inactive_retention_days'
    """)
  end

  def down do
    raise "runner retention values below one day cannot be represented by the old setting"
  end
end
