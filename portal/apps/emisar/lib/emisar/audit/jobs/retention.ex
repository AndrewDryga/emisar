defmodule Emisar.Audit.Jobs.Retention do
  @moduledoc """
  Daily sweep that prunes audit events past their per-row retention horizon.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(4),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Audit, Jobs, Repo}
  require Logger

  @accounts_per_page 100
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    config
    |> Keyword.get(:limit, @accounts_per_page)
    |> Jobs.Sweep.each_row(&list_accounts/2, &sweep_account/1)
  end

  defp sweep_account(%Accounts.Account{} = account) do
    now = DateTime.utc_now()
    auditable_count = delete_in_batches(account.id, 0)

    if auditable_count > 0 do
      Logger.info("audit retention: pruned #{auditable_count} events from account #{account.id}")
      Audit.record(Audit.Events.audit_retention_swept(account.id, auditable_count, now))
    end
  end

  defp delete_in_batches(account_id, auditable_total) do
    ids = account_id |> Audit.Event.Query.prunable_ids(@batch_size) |> Repo.all()

    {_deleted_count, event_types} =
      ids
      |> Audit.Event.Query.by_ids()
      |> Audit.Event.Query.select_event_types()
      |> Repo.delete_all()

    # An expired retention marker is storage housekeeping, not a new operator
    # event. Counting it would replace it with a fresh marker forever on an
    # otherwise inactive account.
    housekeeping_event_type = "audit.retention_swept"
    auditable_count = Enum.count(event_types, &(&1 != housekeeping_event_type))
    auditable_total = auditable_total + auditable_count

    if length(ids) < @batch_size do
      auditable_total
    else
      delete_in_batches(account_id, auditable_total)
    end
  end

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
