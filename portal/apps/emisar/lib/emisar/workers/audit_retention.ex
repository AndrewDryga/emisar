defmodule Emisar.Workers.AuditRetention do
  @moduledoc """
  Nightly job that prunes audit events older than the account's plan
  retention window. Each account is processed independently so a slow
  one can't starve the others.
  """
  use Oban.Worker, queue: :audit, max_attempts: 2
  alias Emisar.{Accounts, Audit, Billing, Repo}
  require Logger

  @impl true
  def perform(%Oban.Job{}) do
    # Deliberately `all()`, not `not_deleted()`: a tombstoned account's
    # audit rows still occupy space and age past retention all the same.
    Accounts.Account.Query.all()
    |> Repo.all()
    |> Enum.each(&prune_account/1)

    :ok
  end

  defp prune_account(%Accounts.Account{} = account) do
    plan = Billing.plan(Billing.account_plan(account)) || Billing.plan("free")
    days = plan.audit_retention_days
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    {n, _} =
      Audit.Event.Query.all()
      |> Audit.Event.Query.by_account_id(account.id)
      |> Audit.Event.Query.occurred_before(cutoff)
      |> Repo.delete_all()

    if n > 0 do
      Logger.info("audit retention: pruned #{n} events from account #{account.id}")
    end
  end
end
