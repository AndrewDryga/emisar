defmodule Emisar.Repo.Migrations.AddDispatcherIpUaToActionRuns do
  use Ecto.Migration

  # Source-IP attribution for api_key/LLM-dispatched infra actions ("which host
  # is wielding this key?"). Persist the dispatcher's ip/ua on the run at create
  # time so every run-lifecycle audit event can carry it — including the terminal
  # `action_run.success` row, which is written from the runner-socket process
  # where there is no inbound request. Nullable (`:string` = varchar(255), matching
  # the audit changeset's request-meta truncation); nil for a system-origin dispatch.
  def change do
    alter table(:action_runs) do
      add :ip_address, :string
      add :user_agent, :string
    end
  end
end
