defmodule Emisar.Workers.AuditRetention do
  @moduledoc """
  Nightly job that prunes audit events older than the account's plan
  retention window. Each account is processed independently so a slow
  one can't starve the others.
  """
  use Oban.Worker, queue: :audit, max_attempts: 2

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Accounts.Account
  alias Emisar.Billing
  alias Emisar.Audit.Event

  @impl true
  def perform(%Oban.Job{}) do
    Account
    |> Repo.all()
    |> Enum.each(&prune_account/1)

    :ok
  end

  defp prune_account(%Account{} = account) do
    plan = Billing.plan(account.plan) || Billing.plan("free")
    days = plan.audit_retention_days
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    {n, _} =
      Repo.delete_all(
        from e in Event,
          where: e.account_id == ^account.id and e.occurred_at < ^cutoff
      )

    if n > 0 do
      require Logger
      Logger.info("audit retention: pruned #{n} events from account #{account.id}")
    end
  end
end
