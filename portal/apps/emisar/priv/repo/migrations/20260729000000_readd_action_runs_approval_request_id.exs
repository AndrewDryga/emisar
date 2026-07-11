defmodule Emisar.Repo.Migrations.ReaddActionRunsApprovalRequestId do
  use Ecto.Migration

  # Rollout-safety correction for 20260725 (frozen, can't be edited). That
  # migration dropped `action_runs.approval_request_id` in the SAME release that
  # removed the schema field — but Fly runs `release_command` (migrate) BEFORE
  # swapping machines, so the still-running old release keeps SELECTing the
  # column (Ecto emits it in the full-struct load) against a DB where it's
  # already gone → `undefined_column` 500s on a hot read path for the whole
  # rollout window. Re-adding it here (empty, no FK — its original shape) keeps
  # the column present once migrate finishes, so old machines read it fine while
  # they drain. The schema field stays removed; the column is now dead and a
  # LATER release can drop it once every machine runs the new schema.
  def change do
    alter table(:action_runs) do
      add :approval_request_id, :binary_id
    end
  end
end
