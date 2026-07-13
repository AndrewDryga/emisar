defmodule Emisar.Repo.Migrations.DropActionRunsApprovalRequestIdAfterRollout do
  use Ecto.Migration

  # The compatibility column can leave only after every old application image
  # has drained. Production completed that rollout before this migration landed.
  def change do
    alter table(:action_runs) do
      remove :approval_request_id, :binary_id
    end
  end
end
