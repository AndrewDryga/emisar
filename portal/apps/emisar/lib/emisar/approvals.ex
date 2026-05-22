defmodule Emisar.Approvals do
  @moduledoc """
  Approval requests for runs that policy gated. An operator approves
  or denies in the UI; on approve the run transitions to :sent and
  Transport dispatches it.
  """

  import Ecto.Query
  alias Emisar.{Audit, PubSub, Repo, Runs}
  alias Emisar.Approvals.Request

  def list_pending(account_id) do
    from(r in Request,
      where: r.account_id == ^account_id and r.status == "pending",
      order_by: [asc: r.requested_at]
    )
    |> Repo.all()
  end

  def list_for_account(account_id, opts \\ []) do
    query =
      from r in Request,
        where: r.account_id == ^account_id,
        order_by: [desc: r.requested_at],
        limit: ^(opts[:limit] || 100)

    query =
      if status = opts[:status] do
        where(query, [r], r.status == ^status)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists approved + denied + expired requests, newest first. Used by
  the "decided" / history pane on the approvals page so a workspace
  with > limit pending requests can still see decided ones — avoiding
  the bug where you'd have to client-side-filter `list_for_account`
  and lose decided rows past the 100-row cap.
  """
  def list_decided(account_id, opts \\ []) do
    from(r in Request,
      where: r.account_id == ^account_id and r.status in ["approved", "denied", "expired"],
      order_by: [desc: r.decided_at, desc: r.requested_at],
      limit: ^(opts[:limit] || 100)
    )
    |> Repo.all()
  end

  def get_request(account_id, id) do
    from(r in Request, where: r.account_id == ^account_id and r.id == ^id)
    |> Repo.one()
  end

  @doc """
  Looks up the (single) approval request for a run, or nil. There is a
  unique-by-design relationship: one run produces at most one approval
  request, since policy is evaluated once at dispatch time.
  """
  def get_request_by_run(account_id, run_id) do
    from(r in Request, where: r.account_id == ^account_id and r.run_id == ^run_id)
    |> Repo.one()
  end

  def create_request(run, requested_by_id, reason \\ nil) do
    result =
      %Request{}
      |> Request.create_changeset(%{
        account_id: run.account_id,
        run_id: run.id,
        requested_by_id: requested_by_id,
        requested_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        reason: reason,
        context: %{
          runner_id: run.runner_id,
          action_id: run.action_id,
          args_sha256: run.args_sha256
        }
      })
      |> Repo.insert()
      |> tap_broadcast()

    # Fan out emails to every member with :decide_approval. Done in a
    # detached Task so a slow SMTP/Mailgun call never blocks the
    # caller's `Runs.dispatch` path. A failed delivery is logged but
    # doesn't roll back the request — the approval is still visible
    # in the dashboard.
    with {:ok, req} <- result do
      Task.start(fn -> notify_approvers(req, run, requested_by_id) end)
      {:ok, req}
    end
  end

  defp notify_approvers(%Request{} = req, run, requested_by_id) do
    Emisar.Accounts.list_memberships_for_account(req.account_id)
    |> Enum.filter(fn m ->
      # User has no `disabled_at`; account-level disable is separate
      # (Emisar.Accounts.Account.disabled_at). Membership-level disable
      # is also captured by filtering on role here — viewers can't
      # decide, so don't get pinged.
      m.role in ~w(owner admin operator) and m.user_id != requested_by_id
    end)
    |> Enum.each(fn m ->
      require Logger

      try do
        # Mailer.deliver returns {:ok, _} on success and {:error, reason}
        # on transport failure (Mailgun 5xx, SMTP timeout). It DOES NOT
        # raise on non-success — a bare `try` would silently drop
        # delivery errors. Pattern-match and log non-success explicitly.
        case Emisar.Mailers.UserNotifier.deliver_approval_request(m.user, req, run) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("approval_email_failed",
              user_id: m.user_id,
              req_id: req.id,
              error: inspect(reason)
            )
        end
      rescue
        err ->
          Logger.warning("approval_email_crashed",
            user_id: m.user_id,
            req_id: req.id,
            error: inspect(err)
          )
      end
    end)
  end

  def approve(%Request{} = req, by_user_id, reason \\ nil) do
    case claim_pending(req, :approved, by_user_id, reason) do
      {:ok, decided} ->
        result =
          Repo.transaction(fn ->
            run = Repo.get!(Emisar.Runs.ActionRun, req.run_id)

            Audit.log(req.account_id, "approval.approved",
              actor_kind: "user",
              actor_id: by_user_id,
              subject_kind: "approval_request",
              subject_id: req.id,
              payload: %{run_id: req.run_id, reason: reason}
            )

            {decided, run}
          end)
          |> tap_broadcast_tuple()

        # Deliver to the runner AFTER the transaction commits so the PubSub
        # broadcast can't fire before the DB state is durable. The transition
        # to :sent happens inside Runs.dispatch_to_runner/1 → Runs.mark_sent/1.
        with {:ok, {decided, run}} <- result,
             :ok <- Runs.dispatch_to_runner(run) do
          run = Repo.reload!(run)
          {:ok, {decided, run}}
        end

      {:error, :already_decided} ->
        {:error, :already_decided}
    end
  end

  def deny(%Request{} = req, by_user_id, reason \\ nil) do
    case claim_pending(req, :denied, by_user_id, reason) do
      {:ok, decided} ->
        Repo.transaction(fn ->
          run = Repo.get!(Emisar.Runs.ActionRun, req.run_id)
          {:ok, run} = Runs.mark_cancelled(run, "approval denied" <> if(reason, do: ": " <> reason, else: ""))

          Audit.log(req.account_id, "approval.denied",
            actor_kind: "user",
            actor_id: by_user_id,
            subject_kind: "approval_request",
            subject_id: req.id,
            payload: %{run_id: req.run_id, reason: reason}
          )

          {decided, run}
        end)
        |> tap_broadcast_tuple()

      {:error, :already_decided} ->
        {:error, :already_decided}
    end
  end

  # Atomically claim a pending approval request as decided. Two operators
  # clicking Approve at the same moment would both pass the LiveView's
  # `status == "pending"` precondition; only one's SQL update will see
  # `WHERE status = 'pending'` evaluate true. The loser gets 0 rows
  # affected and we return `{:error, :already_decided}` so the caller
  # can flash a useful message rather than double-dispatching.
  defp claim_pending(%Request{} = req, status, by_user_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    status_str = to_string(status)

    {affected, _} =
      from(r in Request,
        where: r.id == ^req.id and r.status == "pending",
        update: [
          set: [
            status: ^status_str,
            decided_by_id: ^by_user_id,
            decided_at: ^now,
            decision_reason: ^reason
          ]
        ]
      )
      |> Repo.update_all([])

    case affected do
      1 -> {:ok, Repo.get!(Request, req.id)}
      0 -> {:error, :already_decided}
    end
  end

  defp tap_broadcast({:ok, %Request{} = r} = result) do
    PubSub.broadcast_approval(r)
    result
  end

  defp tap_broadcast(other), do: other

  defp tap_broadcast_tuple({:ok, {req, _run}} = result) do
    PubSub.broadcast_approval(req)
    result
  end

  defp tap_broadcast_tuple(other), do: other
end
