defmodule Emisar.Billing do
  @moduledoc """
  Plan + subscription glue. Paddle is the source of truth; we mirror
  the subset (plan + status + period end) needed to enforce limits
  without round-tripping per request. The Paddle HTTP layer is swappable
  via `Application.fetch_env!(:emisar, :paddle_client)` — production
  binds the live client, tests use the in-process stub.
  """

  alias Emisar.{Auth, PublicUrl, Repo}
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.Auth.Subject
  alias Emisar.Billing.{Authorizer, Subscription}
  alias Emisar.Runners.Runner

  @doc "Whether `subject` may manage billing and the subscription (owner-only)."
  def subject_can_manage_billing?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_billing_permission())

  @plans %{
    "free" => %{
      name: "Free",
      monthly_price_cents: 0,
      runners_limit: 3,
      members_limit: 1,
      audit_retention_days: 7,
      features: ["3 runners", "1 user", "7-day audit retention", "Community support"]
    },
    "team" => %{
      name: "Team",
      monthly_price_cents: 2000,
      runners_limit: 100,
      members_limit: :unlimited,
      audit_retention_days: 90,
      features: [
        "Unlimited users",
        "90-day audit retention",
        "Email support"
      ]
    },
    "enterprise" => %{
      name: "Enterprise",
      monthly_price_cents: nil,
      runners_limit: :unlimited,
      members_limit: :unlimited,
      audit_retention_days: 365,
      features: [
        "Everything in Team",
        "365-day audit retention",
        "Security and procurement review",
        "Design-partner deployment planning",
        "Rollout support"
      ]
    }
  }

  def plans, do: @plans
  def plan(name) when is_binary(name), do: Map.get(@plans, name)

  # Internal nil-or-struct helper. Used by `upsert_subscription/2` and
  # webhook event application. Not exposed to LiveView/MCP because
  # there's no Subject path here.
  defp peek_subscription_for_account(account_id) do
    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Repo.peek()
  end

  @doc false
  # Internal write — called from webhook handlers + `Workers.BillingSync`
  # which run on already-trusted server contexts. Subject-less because
  # the Paddle webhook signature is the auth gate at the edge.
  def upsert_subscription(account_id, attrs) do
    case peek_subscription_for_account(account_id) do
      nil ->
        Subscription.Changeset.upsert(Map.put(attrs, :account_id, account_id))
        |> Repo.insert()

      %Subscription{} = existing ->
        existing |> Subscription.Changeset.upsert(attrs) |> Repo.update()
    end
  end

  @doc """
  Returns :ok if the account is within plan limits for `resource`.
  Returns `{:error, :over_limit, plan, limit}` otherwise.

  Internal — called by `Runners.register_via_auth_key/2` on the
  bootstrap path before any Subject exists, and by `Catalog`/admin
  flows that already authorized upstream. The check itself is
  account-scoped (the runner counting), not subject-scoped.
  """
  def check_limit(%Account{plan: plan_name} = account, resource) do
    # Fall back to the free plan when the account's plan name isn't a
    # current plan (legacy/renamed) — the same guard billing_summary and
    # audit_retention use, and it avoids Map.get on a nil plan.
    plan = plan(plan_name) || plan("free")
    limit = Map.get(plan, limit_key(resource))

    current = current_count(account, resource)

    cond do
      limit == :unlimited -> :ok
      current < limit -> :ok
      true -> {:error, :over_limit, plan_name, limit}
    end
  end

  defp limit_key(:runners), do: :runners_limit
  defp limit_key(:members), do: :members_limit

  defp current_count(%Account{id: account_id}, :runners) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Repo.aggregate(:count, :id)
  end

  defp current_count(%Account{id: account_id}, :members) do
    Membership.Query.all()
    |> Membership.Query.by_account_id(account_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Creates a Paddle Checkout (Transaction) for the chosen plan and returns
  the URL the operator should be redirected to. Falls back to a stub
  URL when no Paddle price ID is configured (dev/test).
  """
  def start_checkout(%Account{} = account, plan_name, %Subject{} = subject)
      when is_binary(plan_name) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- ensure_subject_owns_account(account, subject) do
      cond do
        not Map.has_key?(@plans, plan_name) ->
          {:error, :unknown_plan}

        is_nil(Application.get_env(:emisar, :paddle_price_ids, %{})[plan_name]) ->
          {:ok, "/paddle-checkout-stub?plan=" <> plan_name}

        true ->
          with {:ok, cid, _account} <- ensure_paddle_customer(account, subject),
               price_id <-
                 Map.fetch!(Application.get_env(:emisar, :paddle_price_ids, %{}), plan_name),
               {:ok, %{"url" => url}} <-
                 Emisar.Billing.PaddleClient.create_checkout_session(%{
                   customer: cid,
                   price_id: price_id,
                   quantity: current_count(account, :runners),
                   success_url: PublicUrl.url("/app/settings/billing?status=success"),
                   cancel_url: PublicUrl.url("/app/settings/billing?status=cancelled")
                 }) do
            {:ok, url}
          end
      end
    end
  end

  @doc """
  Creates a Paddle Customer Portal session for the account's customer and
  returns the hosted-portal URL. Operators land there to update their
  payment method, download invoices, change plan, or cancel — no email
  to support required.

  Returns `{:error, :no_customer}` if the account has never been on a
  paid plan (no `paddle_customer_id`). Returns a stub URL when no
  Paddle key is configured (dev/test).
  """
  def open_billing_portal(%Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- ensure_subject_owns_account(account, subject) do
      do_open_billing_portal(account)
    end
  end

  defp do_open_billing_portal(%Account{paddle_customer_id: nil}), do: {:error, :no_customer}

  defp do_open_billing_portal(%Account{paddle_customer_id: cid}) when is_binary(cid) do
    return_url = PublicUrl.url("/app/settings/billing")

    if Application.get_env(:emisar, :paddle_api_key) do
      case Emisar.Billing.PaddleClient.create_billing_portal_session(%{
             customer: cid,
             return_url: return_url
           }) do
        {:ok, %{"url" => url}} -> {:ok, url}
        other -> other
      end
    else
      # Stub path — no real Paddle configured. Send the operator back
      # to billing with a query param so the LV can show a flash.
      {:ok, return_url <> "?status=stub-portal"}
    end
  end

  defp ensure_subject_owns_account(%Account{id: id}, %Subject{} = subject),
    do: Subject.ensure_in_account(subject, id, :unauthorized)

  @doc """
  Ensures the account has a Paddle customer; returns the customer id.
  Idempotent — if the account already has one, just returns it.

  On first creation the acting user's email is attached to the Paddle
  customer so invoices and receipts reach a real inbox.
  """
  def ensure_paddle_customer(%Account{paddle_customer_id: cid} = account, %Subject{})
      when is_binary(cid),
      do: {:ok, cid, account}

  def ensure_paddle_customer(%Account{} = account, %Subject{} = subject) do
    with {:ok, %{"id" => cid}} <-
           Emisar.Billing.PaddleClient.create_customer(%{
             email: Subject.actor_email(subject),
             name: account.name,
             account_id: account.id
           }),
         {:ok, account} <- update_account_paddle_id(account, cid) do
      {:ok, cid, account}
    end
  end

  @doc """
  Atomically:

    * inserts the Paddle event id into `paddle_processed_events` (unique
      primary key); if the row already exists, returns
      `{:duplicate, existing}` and does NOT re-apply,
    * calls `apply_webhook_event/1` inside the same transaction so we
      can never end up with the dedup row recorded but the side effects
      missing.
  """
  def record_and_apply_event(event_id, event_type, event)
      when is_binary(event_id) and is_binary(event_type) do
    Repo.transaction(fn ->
      row = %{
        id: event_id,
        event_type: event_type,
        received_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      # Dedup insert into the schemaless bookkeeping table. `on_conflict:
      # :nothing` → 0 rows means this Paddle event id was already processed
      # (it re-delivers); 1 row means it's new. A genuine DB error raises and
      # rolls the transaction back, so it's never mistaken for a duplicate.
      case Repo.insert_all("paddle_processed_events", [row], on_conflict: :nothing) do
        {0, _} ->
          Repo.rollback({:duplicate, event_id})

        {1, _} ->
          # Roll back when applying the event fails so the dedup row is NOT
          # committed — otherwise Paddle's redelivery is swallowed as
          # already-processed and the account never gets its plan/entitlement.
          case apply_webhook_event(event) do
            :ok -> :ok
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback({:apply_failed, reason})
          end
      end
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, {:duplicate, _} = dup} -> dup
      {:error, other} -> {:error, other}
    end
  end

  @doc """
  Apply an incoming Paddle webhook event. Idempotent on `event["id"]`
  (deduped via `record_and_apply_event/3`).
  """
  def apply_webhook_event(%{"event_type" => "subscription.created", "data" => sub}),
    do: upsert_from_subscription(sub)

  def apply_webhook_event(%{"event_type" => "subscription.updated", "data" => sub}),
    do: upsert_from_subscription(sub)

  def apply_webhook_event(%{"event_type" => "subscription.canceled", "data" => sub}) do
    case peek_subscription_by_paddle_id(sub["id"]) do
      nil ->
        :ok

      %Subscription{} = s ->
        Repo.update(Subscription.Changeset.upsert(s, %{status: "canceled"}))
    end
  end

  def apply_webhook_event(_event), do: :ok

  defp upsert_from_subscription(sub) do
    case peek_account_by_paddle_customer(sub["customer_id"]) do
      nil ->
        :ok

      %Account{} = account ->
        price_id = extract_price_id(sub)

        attrs = %{
          paddle_subscription_id: sub["id"],
          paddle_price_id: price_id,
          plan: plan_for_subscription(account, price_id),
          status: sub["status"],
          current_period_end: extract_next_billed_at(sub)
        }

        upsert_subscription(account.id, attrs)
    end
  end

  # Paddle subscription payloads nest the price under `items[].price.id`.
  # We bill a single line item, so the first item's price id is the plan.
  defp extract_price_id(%{"items" => [%{"price" => %{"id" => id}} | _]}) when is_binary(id),
    do: id

  defp extract_price_id(_), do: nil

  # `:paddle_price_ids` is configured as `%{plan_name => price_id}` (the
  # same map `start_checkout/3` reads). Invert it to map the webhook's
  # price id back to a plan. If it can't be resolved (price id absent or
  # not configured — e.g. the sales-led enterprise tier), fall back to the
  # account's current plan, then "free", so the subscription can persist
  # rather than failing `validate_required([:plan])` and stranding the account.
  defp plan_for_subscription(%Account{} = account, price_id) do
    price_to_plan =
      Application.get_env(:emisar, :paddle_price_ids, %{})
      |> Map.new(fn {plan, pid} -> {pid, plan} end)

    price_to_plan[price_id] || account.plan || "free"
  end

  defp peek_account_by_paddle_customer(cid) when is_binary(cid) do
    Account.Query.all()
    |> Account.Query.by_paddle_customer_id(cid)
    |> Repo.peek()
  end

  defp peek_account_by_paddle_customer(_), do: nil

  defp peek_subscription_by_paddle_id(id) do
    Subscription.Query.all()
    |> Subscription.Query.by_paddle_subscription_id(id)
    |> Repo.peek()
  end

  defp update_account_paddle_id(account, cid) do
    account
    |> Ecto.Changeset.change(paddle_customer_id: cid)
    |> Repo.update()
  end

  @doc """
  Extracts the next billing time from a Paddle subscription payload.
  Paddle returns ISO8601 strings (not epoch ints). The top-level field
  is `next_billed_at`; some payloads put it under
  `current_billing_period.ends_at` — handle both.
  """
  def extract_next_billed_at(%{"next_billed_at" => iso}) when is_binary(iso),
    do: parse_iso8601(iso)

  def extract_next_billed_at(%{"current_billing_period" => %{"ends_at" => iso}})
      when is_binary(iso),
      do: parse_iso8601(iso)

  def extract_next_billed_at(_), do: nil

  defp parse_iso8601(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  @doc """
  Pricing + utilization summary for an account at the current period.

  Includes the plan's runner / member ceilings so dashboards can warn
  operators *before* they hit the wall (`X / 3` with a near-limit
  badge), not after the next runner install fails with a 402 buried
  in `journalctl`.
  """
  def billing_summary(%Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_billing_permission()
           ),
         :ok <- ensure_subject_owns_account(account, subject) do
      plan_def = plan(account.plan) || plan("free")
      runner_count = current_count(account, :runners)
      member_count = current_count(account, :members)
      subscription = peek_subscription_for_account(account.id)

      {:ok,
       %{
         plan: account.plan,
         plan_name: plan_def.name,
         runner_count: runner_count,
         runner_limit: plan_def.runners_limit,
         member_count: member_count,
         member_limit: plan_def.members_limit,
         monthly_per_runner_cents: plan_def.monthly_price_cents,
         monthly_total_cents:
           case plan_def.monthly_price_cents do
             nil -> nil
             n -> n * runner_count
           end,
         audit_retention_days: plan_def.audit_retention_days,
         # Subscription state mirrored from Paddle webhooks. nil when
         # the account is on a free plan and has never subscribed.
         subscription_status: subscription && subscription.status,
         current_period_end: subscription && subscription.current_period_end,
         cancel_at_period_end: subscription && subscription.cancel_at_period_end,
         trial_end: subscription && subscription.trial_end
       }}
    end
  end

  @doc """
  Headroom on a `summary` resource: `:ok` (>1 slot free),
  `:warning` (1 slot free), `:at_limit` (0 free), `:unlimited`.
  Used by the UI to colour the runner/members usage tile.
  """
  def headroom(%{} = summary, :runners) do
    headroom_for(summary.runner_count, summary.runner_limit)
  end

  def headroom(%{} = summary, :members) do
    headroom_for(summary.member_count, summary.member_limit)
  end

  defp headroom_for(_used, :unlimited), do: :unlimited

  defp headroom_for(used, limit) when is_integer(limit) do
    cond do
      used >= limit -> :at_limit
      limit - used <= 1 -> :warning
      true -> :ok
    end
  end

  defp headroom_for(_used, _limit), do: :ok
end
