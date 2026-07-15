defmodule Emisar.Repo.Migrations.NameEmittedOutputAndTrackDelivery do
  use Ecto.Migration

  def change do
    rename table(:action_runs), :stdout_sha256, to: :emitted_stdout_sha256
    rename table(:action_runs), :stderr_sha256, to: :emitted_stderr_sha256
    rename table(:action_runs), :stdout_bytes, to: :emitted_stdout_bytes
    rename table(:action_runs), :stderr_bytes, to: :emitted_stderr_bytes

    alter table(:action_runs) do
      add :output_complete, :boolean, null: false, default: false
    end
  end
end
