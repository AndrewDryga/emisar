defmodule Emisar.Workers.AccountRetention do
  @moduledoc """
  Shared engine for the nightly, account-paged retention sweeps
  (`Workers.AuditRetention`, `Workers.ActionRunEventRetention`). It pages the
  account set by an id cursor, prunes each account's expired rows in bounded
  batches (never one long-locking DELETE), and enqueues a follow-up for the next
  page so a growing tenant base never piles into one unbounded run. The calling
  worker supplies WHAT to prune via a `Spec`; the plan cutoff, paging, batching,
  and cursor continuation live here.
  """
  alias Emisar.{Accounts, Billing, Repo}
  require Logger

  # Accounts handled per job before handing the rest to a follow-up; an account
  # carries its own bounded per-statement delete batch.
  @accounts_per_run 100
  @batch_size 5_000

  defmodule Spec do
    @moduledoc """
    What a retention sweep prunes, supplied by the calling worker:

      * `:worker` — the Oban worker module; used to enqueue the page follow-up,
        so it inherits that worker's `unique`/queue config.
      * `:prunable_ids` — `(account_id, cutoff, limit) -> queryable` of the ids
        eligible for deletion (a Query-module fn).
      * `:delete_by_ids` — `(ids) -> queryable` to `Repo.delete_all`.
      * `:label` — the log prefix for a non-empty prune.
      * `:on_swept` — OPTIONAL `(account_id, count, swept_at) -> any`, called once
        per account that had rows pruned (`count > 0`). Lets a worker record a
        summary (e.g. an `audit.retention_swept` audit row); nil = no callback.
    """
    @enforce_keys [:worker, :prunable_ids, :delete_by_ids, :label]
    defstruct [:worker, :prunable_ids, :delete_by_ids, :label, :on_swept]
  end

  @doc """
  Internal — runs one page of `spec`'s sweep for the Oban job `args`
  (`"limit"`, `"after_account_id"`), enqueuing the next page when this one comes
  back full. Worker-only: the workers `use Oban.Worker` and delegate `perform/1`.
  """
  def run(args, %Spec{} = spec) do
    limit = args["limit"] || @accounts_per_run

    # Deliberately `all()`, not `not_deleted()`: a tombstoned account's rows
    # still occupy space and age past retention all the same.
    accounts =
      Accounts.Account.Query.all()
      |> after_account(args["after_account_id"])
      |> Accounts.Account.Query.ordered_by_id()
      |> Accounts.Account.Query.limit_to(limit)
      |> Repo.all()

    Enum.each(accounts, &prune_account(&1, spec))
    maybe_continue(accounts, limit, spec)
  end

  defp after_account(queryable, nil), do: queryable
  defp after_account(queryable, id), do: Accounts.Account.Query.after_id(queryable, id)

  # A full page may have more behind it → hand off from the last id; a short
  # page means the account set is drained.
  defp maybe_continue(accounts, limit, _spec) when length(accounts) < limit, do: :ok

  defp maybe_continue(accounts, limit, spec) do
    args = %{"after_account_id" => List.last(accounts).id, "limit" => limit}
    {:ok, _job} = args |> spec.worker.new() |> Oban.insert()
    :ok
  end

  defp prune_account(%Accounts.Account{} = account, spec) do
    now = DateTime.utc_now()
    retention_days = Billing.account_audit_retention_days(account.id)
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)

    pruned = delete_in_batches(account.id, cutoff, 0, spec)

    if pruned > 0 do
      Logger.info("#{spec.label}: pruned #{pruned} events from account #{account.id}")
      maybe_on_swept(spec.on_swept, account.id, pruned, now)
    end
  end

  defp maybe_on_swept(nil, _account_id, _count, _swept_at), do: :ok

  defp maybe_on_swept(on_swept, account_id, count, swept_at) when is_function(on_swept, 3),
    do: on_swept.(account_id, count, swept_at)

  # Delete ≤ @batch_size prunable rows by id, looping until a batch comes back
  # short (the prunable set is drained — it only ever shrinks across iterations).
  defp delete_in_batches(account_id, cutoff, total, spec) do
    ids = spec.prunable_ids.(account_id, cutoff, @batch_size) |> Repo.all()
    {n, _} = spec.delete_by_ids.(ids) |> Repo.delete_all()

    if length(ids) < @batch_size do
      total + n
    else
      delete_in_batches(account_id, cutoff, total + n, spec)
    end
  end
end
