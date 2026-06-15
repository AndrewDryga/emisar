defmodule Emisar.Repo.Migrations.AddPackVersionTrustedManifest do
  @moduledoc """
  Snapshot of a trusted pack version's action set, so a later re-advertised
  hash can be diffed against what was trusted (an added `critical` action is
  the change an operator must see before re-trusting). Captured by
  `Catalog.trust_pack_version/2`; null until the first Trust, and null also
  means "no diff" in the pending-trust UI.

  Corrective (NOT edit-the-original): the trust columns' home migration
  `20260602000000_pack_version_trust` has already shipped to the persistent
  Fly/MPG database, so this additive column ships as its own migration — it
  runs on a fresh DB and the deployed one alike.
  """
  use Ecto.Migration

  def change do
    alter table(:pack_versions) do
      add :trusted_manifest, :map
    end
  end
end
