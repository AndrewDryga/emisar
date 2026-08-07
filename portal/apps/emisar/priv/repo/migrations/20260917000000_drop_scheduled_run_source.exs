defmodule Emisar.Repo.Migrations.DropScheduledRunSource do
  use Ecto.Migration

  # Re-timestamped from 20260807055343 before this ever left the machine: the
  # constraint it drops is created by 20260816000002, so at a wall-clock
  # timestamp this ran BEFORE the thing it edits and aborted every fresh
  # database. Migrations here are sequential, not wall-clock.

  # `:scheduled` was declared in the ActionRun source enum at MVP and no code
  # path ever produced it — the runbook scheduler writes `source: :runbook`.
  # It survived as an operator filter option that always returned zero rows,
  # six render branches, and this slot in the backstop CHECK.
  #
  # The UPDATE is defensive rather than expected: nothing could have written the
  # value, so it matches no rows. It runs first anyway, because an Ecto.Enum that
  # no longer lists a value raises on LOAD, and a straggler would take the runs
  # page down rather than degrade.
  def up do
    execute("UPDATE action_runs SET source = 'operator' WHERE source = 'scheduled'")

    execute("ALTER TABLE action_runs DROP CONSTRAINT action_runs_source_check")

    execute("""
    ALTER TABLE action_runs ADD CONSTRAINT action_runs_source_check
      CHECK (source = ANY (ARRAY['operator', 'runbook', 'mcp']))
    """)
  end

  def down do
    execute("ALTER TABLE action_runs DROP CONSTRAINT action_runs_source_check")

    execute("""
    ALTER TABLE action_runs ADD CONSTRAINT action_runs_source_check
      CHECK (source = ANY (ARRAY['operator', 'runbook', 'mcp', 'scheduled']))
    """)
  end
end
