defmodule Emisar.Repo.Migrations.TrackDegradedPacks do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      # Packs the runner's loader skipped at boot (unparseable/invalid on
      # disk), advertised on runner_state so the console and MCP diagnostics
      # can say "pack X failed to load on runner Y". List of
      # %{"pack" => name, "reason" => text}, bounded at ingest.
      add :degraded_packs, {:array, :map}, default: [], null: false
    end
  end
end
