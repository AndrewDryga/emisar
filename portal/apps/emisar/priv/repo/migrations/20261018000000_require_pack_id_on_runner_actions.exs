defmodule Emisar.Repo.Migrations.RequirePackIdOnRunnerActions do
  use Ecto.Migration

  # The pack-less dispatch path is removed: an action with no pack has no
  # trusted manifest to authorize dispatch from, so ingestion now rejects a
  # pack-less advertisement (RunnerAction.Changeset requires pack_id) and
  # dispatch fails closed. Require the column so the invariant also holds at
  # the DB, for any writer the changeset doesn't cover.
  #
  # catalog_runner_actions is a self-healing projection of what each connected
  # runner currently advertises — a runner re-advertises its (pack-backed)
  # actions on every state sync — so deleting the stale pack-less rows a prior
  # release's runners left behind loses nothing durable. SET NOT NULL then
  # validates a bounded table under /app/bin/migrate, before the instance serves.
  def up do
    execute("DELETE FROM catalog_runner_actions WHERE pack_id IS NULL")
    execute("ALTER TABLE catalog_runner_actions ALTER COLUMN pack_id SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE catalog_runner_actions ALTER COLUMN pack_id DROP NOT NULL")
  end
end
