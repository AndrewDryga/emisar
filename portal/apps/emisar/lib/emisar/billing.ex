defmodule Emisar.Billing do
  @moduledoc """
  Plan + subscription glue. Paddle is the source of truth; we mirror
  the subset (plan + status + period end) needed to enforce limits
  without round-tripping per request. The Paddle HTTP layer is swappable
  via `Application.fetch_env!(:emisar, :paddle_client)` — production
  binds the live client, tests use the in-process stub.
  """
  import Emisar.Maps, only: [put_present: 3]
  alias Ecto.Multi
  alias Emisar.{Accounts, Analytics, Auth, PublicUrl, Repo, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.Billing.{Authorizer, Subscription}

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
        "Single sign-on (OIDC)",
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
        "SCIM directory sync",
        "365-day audit retention",
        "Security and procurement review",
        "Design-partner deployment planning",
        "Rollout support"
      ]
    }
  }

  def plans, do: @plans
  def plan(name) when is_binary(name), do: Map.get(@plans, name)

  @doc """
  The account's current plan name — derived from its mirrored Paddle
  subscription (the source of truth), falling back to "free" when the
  account has never subscribed. This is the ONE source for plan gating;
  there is no `plan` column on `accounts`.

  Status-agnostic by design: a past_due/canceled subscription still
  resolves to its plan — billing status is advisory today (see the
  billing-status enforcement decision), so this derivation must not start
  restricting on status. An unknown/renamed plan name is returned as
  stored; callers degrade it through `plan/1` (nil → free-tier limits),
  matching the read-tolerant posture the dropped column had.
  """
  def account_plan(%Accounts.Account{} = account),
    do: plan_from_subscription(peek_subscription_for_account(account.id))

  defp plan_from_subscription(%Subscription{plan: plan}) when is_binary(plan), do: plan
  defp plan_from_subscription(_), do: "free"

  @doc "True when the account's plan includes OIDC single sign-on (Team and Enterprise)."
  def sso_available?(%Accounts.Account{} = account),
    do: account_plan(account) in ["team", "enterprise"]

  @doc "True when the account's plan includes SCIM directory sync (Enterprise only)."
  def directory_sync_available?(%Accounts.Account{} = account),
    do: account_plan(account) == "enterprise"

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
  #
  # Deliberately peek-then-insert/update rather than an `on_conflict` true-upsert:
  # webhook payloads carry PARTIAL attr sets (e.g. cancel carries only `status`),
  # so a replace-set upsert would null fields the event didn't mention. The INSERT
  # race is closed by `unique_index(:subscriptions, [:account_id])` (a concurrent
  # first-insert loses with a constraint error; Paddle's redelivery then takes the
  # update branch); the UPDATE race is closed by the LOCKED re-read below
  # (`fetch_and_update` → FOR NO KEY UPDATE), so a concurrent webhook + hourly
  # BillingSync (or two webhooks) serialize on the row and the loser recomputes
  # off the committed state, instead of last-write-winning a stale status over a
  # fresh one.
  def upsert_subscription(account_id, attrs) do
    case peek_subscription_for_account(account_id) do
      nil ->
        Subscription.Changeset.upsert(Map.put(attrs, :account_id, account_id))
        |> Repo.insert()

      %Subscription{} ->
        Subscription.Query.all()
        |> Subscription.Query.by_account_id(account_id)
        |> Repo.fetch_and_update(Subscription.Query,
          with: &Subscription.Changeset.upsert(&1, attrs)
        )
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
  def check_limit(%Accounts.Account{} = account, resource) do
    # Resolve the plan from the account's subscription; fall back to the
    # free plan when the name isn't a current plan (legacy/renamed) — the
    # same guard billing_summary and audit_retention use, and it avoids
    # Map.get on a nil plan.
    plan_name = account_plan(account)
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

  # The owning contexts count their own rows — billing only owns the
  # limit semantics.
  defp current_count(%Accounts.Account{id: account_id}, :runners),
    do: Runners.count_billable_runners(account_id)

  defp current_count(%Accounts.Account{id: account_id}, :members),
    do: Accounts.count_memberships(account_id)

  @doc """
  Creates a Paddle Checkout (Transaction) for the chosen plan and returns
  the URL the operator should be redirected to. Falls back to a stub
  URL when no Paddle price ID is configured (dev/test).
  """
  def start_checkout(%Accounts.Account{} = account, plan_name, %Subject{} = subject)
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
          with {:ok, customer_id, _account} <- ensure_paddle_customer(account, subject),
               price_id <-
                 Map.fetch!(Application.get_env(:emisar, :paddle_price_ids, %{}), plan_name),
               {:ok, %{"url" => url}} <-
                 Emisar.Billing.PaddleClient.create_checkout_session(%{
                   customer: customer_id,
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
  def open_billing_portal(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- ensure_subject_owns_account(account, subject) do
      do_open_billing_portal(account)
    end
  end

  defp do_open_billing_portal(%Accounts.Account{paddle_customer_id: nil}),
    do: {:error, :no_customer}

  defp do_open_billing_portal(%Accounts.Account{paddle_customer_id: customer_id})
       when is_binary(customer_id) do
    return_url = PublicUrl.url("/app/settings/billing")

    if Application.get_env(:emisar, :paddle_api_key) do
      case Emisar.Billing.PaddleClient.create_billing_portal_session(%{
             customer: customer_id,
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

  defp ensure_subject_owns_account(%Accounts.Account{id: id}, %Subject{} = subject),
    do: Subject.ensure_in_account(subject, id, :unauthorized)

  @doc """
  Ensures the account has a Paddle customer; returns the customer id.
  Idempotent — if the account already has one, just returns it.

  On first creation the acting user's email is attached to the Paddle
  customer so invoices and receipts reach a real inbox.
  """
  def ensure_paddle_customer(
        %Accounts.Account{paddle_customer_id: customer_id} = account,
        %Subject{}
      )
      when is_binary(customer_id),
      do: {:ok, customer_id, account}

  def ensure_paddle_customer(%Accounts.Account{} = account, %Subject{} = subject) do
    with {:ok, %{"id" => customer_id}} <-
           Emisar.Billing.PaddleClient.create_customer(%{
             email: Subject.actor_email(subject),
             name: account.name,
             account_id: account.id
           }),
         {:ok, account} <- Accounts.put_account_paddle_customer_id(account, customer_id) do
      # The write is first-wins under the row lock: a concurrent first
      # checkout may have linked its customer between our stale-struct
      # check and here, so the id of record is whatever the locked row
      # carries — our freshly-minted customer is then a harmless orphan
      # at Paddle (it bills nothing).
      {:ok, account.paddle_customer_id, account}
    end
  end

  @doc """
  Internal — the Paddle webhook controller's entry point; the request's
  signature is the auth gate at the edge, so there's no Subject here. Not
  exposed to LiveView/MCP.

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
    row = %{id: event_id, event_type: event_type, received_at: DateTime.utc_now()}

    Multi.new()
    # Dedup insert into the schemaless bookkeeping table. `on_conflict:
    # :nothing` → 0 rows means this Paddle event id was already processed
    # (Paddle re-delivers); 1 row means it's new. A duplicate aborts the
    # whole transaction so the side effects below never re-run.
    |> Multi.run(:dedup, fn _repo, _changes ->
      case Repo.insert_all("paddle_processed_events", [row], on_conflict: :nothing) do
        {1, _} -> {:ok, :new}
        {0, _} -> {:error, {:duplicate, event_id}}
      end
    end)
    # A failed apply aborts too, so the dedup row is NOT committed —
    # otherwise Paddle's redelivery is swallowed as already-processed and
    # the account never gets its plan/entitlement.
    |> Multi.run(:apply, fn _repo, _changes ->
      # Carry the upserted subscription through so the POST-commit branch can
      # emit `subscription_changed` — firing inside the txn would risk a
      # phantom event if a later step rolls it back.
      case apply_webhook_event(event) do
        {:ok, %Subscription{} = subscription} -> {:ok, subscription}
        {:ok, _other} -> {:ok, :applied}
        :ok -> {:ok, :applied}
        {:error, reason} -> {:error, {:apply_failed, reason}}
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, changes} ->
        Emisar.Telemetry.billing_webhook(:applied)
        track_subscription_change(changes.apply)
        :ok

      {:error, {:duplicate, _} = dup} ->
        Emisar.Telemetry.billing_webhook(:duplicate)
        dup

      {:error, other} ->
        Emisar.Telemetry.billing_webhook(:failed)
        {:error, other}
    end
  end

  # Post-commit: only an actual upsert (created/updated/canceled) carries a
  # subscription — a no-op apply (unknown event, cancel of an unknown id) is
  # `:applied` and tracks nothing.
  defp track_subscription_change(%Subscription{} = subscription),
    do: Analytics.Events.subscription_changed(subscription)

  defp track_subscription_change(_applied), do: :ok

  @doc """
  Internal — applies an incoming Paddle webhook event (account-scoped via
  the customer/subscription id in the payload, no Subject). Idempotent on
  `event["id"]` (deduped via `record_and_apply_event/3`). Webhook/worker
  only; not exposed to LiveView/MCP.
  """
  def apply_webhook_event(%{"event_type" => "subscription.created", "data" => subscription_data}),
    do: upsert_from_subscription(subscription_data)

  def apply_webhook_event(%{"event_type" => "subscription.updated", "data" => subscription_data}),
    do: upsert_from_subscription(subscription_data)

  def apply_webhook_event(%{"event_type" => "subscription.canceled", "data" => subscription_data}) do
    case peek_subscription_by_paddle_id(subscription_data["id"]) do
      nil ->
        :ok

      %Subscription{account_id: account_id} ->
        # Route through the LOCKED upsert (not a bare peek-then-update) so a
        # concurrent webhook serializes on the row, and carry `updated_at` so a
        # late cancel that predates a fresher event is dropped by the
        # stale-update guard rather than clobbering the row to canceled.
        upsert_subscription(account_id, %{
          status: "canceled",
          paddle_updated_at: extract_paddle_updated_at(subscription_data)
        })
    end
  end

  def apply_webhook_event(_event), do: :ok

  defp upsert_from_subscription(subscription_data) do
    case peek_account_by_paddle_customer(subscription_data["customer_id"]) do
      nil ->
        :ok

      %Accounts.Account{} = account ->
        price_id = extract_price_id(subscription_data)
        cancel_scheduled? = scheduled_cancel?(subscription_data)

        # A partial subscription.updated (status-only, no items / next_billed_at)
        # must not null price/period — omit those keys via put_present so the
        # peek-then-update preserves the stored values rather than casting them to
        # nil. `plan` stays put: plan_for_subscription/2 falls back to account_plan/1.
        # `cancel_at_period_end` IS always set: Paddle's payload carries the full
        # object, so it reflects the current scheduled state, and the billing
        # dashboard's "cancels on …" banner must CLEAR when a scheduled cancel is
        # removed — not just appear when one is added.
        attrs =
          %{
            paddle_subscription_id: subscription_data["id"],
            plan: plan_for_subscription(account, price_id),
            status: subscription_data["status"],
            cancel_at_period_end: cancel_scheduled?
          }
          |> put_present(:paddle_price_id, price_id)
          |> put_present(:current_period_end, period_end(subscription_data, cancel_scheduled?))
          |> put_present(:current_period_start, extract_current_period_start(subscription_data))
          |> put_present(:quantity, extract_quantity(subscription_data))
          |> put_present(:paddle_updated_at, extract_paddle_updated_at(subscription_data))

        upsert_subscription(account.id, attrs)
    end
  end

  # A Paddle `scheduled_change` with action "cancel" means the subscription ends at
  # period end (the operator scheduled a cancel in the portal) — drives the billing
  # dashboard's cancel banner. Paddle sends the full object, so an absent/null
  # scheduled_change means "no scheduled cancel".
  defp scheduled_cancel?(%{"scheduled_change" => %{"action" => "cancel"}}), do: true
  defp scheduled_cancel?(_), do: false

  # Access-until date: a scheduled cancel ends access at its `effective_at` (a
  # non-renewing sub has no next_billed_at), otherwise the next charge date.
  defp period_end(%{"scheduled_change" => %{"effective_at" => iso}}, true) when is_binary(iso),
    do: parse_iso8601(iso)

  defp period_end(subscription_data, _cancel_scheduled?),
    do: extract_next_billed_at(subscription_data)

  defp extract_current_period_start(%{"current_billing_period" => %{"starts_at" => iso}})
       when is_binary(iso),
       do: parse_iso8601(iso)

  defp extract_current_period_start(_), do: nil

  # Paddle bills a single line item; its quantity is the seat/runner count.
  defp extract_quantity(%{"items" => [%{"quantity" => quantity} | _]}) when is_integer(quantity),
    do: quantity

  defp extract_quantity(_), do: nil

  # Paddle subscription payloads nest the price under `items[].price.id`.
  # We bill a single line item, so the first item's price id is the plan.
  defp extract_price_id(%{"items" => [%{"price" => %{"id" => id}} | _]}) when is_binary(id),
    do: id

  defp extract_price_id(_), do: nil

  # `:paddle_price_ids` is configured as `%{plan_name => price_id}` (the
  # same map `start_checkout/3` reads). Invert it to map the webhook's
  # price id back to a plan. If it can't be resolved (price id absent or
  # not configured — e.g. the sales-led enterprise tier), fall back to the
  # account's current plan (its existing subscription, via `account_plan/1`),
  # else "free", so the subscription can persist rather than failing
  # `validate_required([:plan])` and stranding the account's entitlement.
  defp plan_for_subscription(%Accounts.Account{} = account, price_id) do
    price_to_plan =
      Application.get_env(:emisar, :paddle_price_ids, %{})
      |> Map.new(fn {plan, pid} -> {pid, plan} end)

    price_to_plan[price_id] || account_plan(account)
  end

  # nil-tolerant adapter: Paddle payloads may omit the customer id.
  defp peek_account_by_paddle_customer(customer_id) when is_binary(customer_id),
    do: Accounts.peek_account_by_paddle_customer_id(customer_id)

  defp peek_account_by_paddle_customer(_), do: nil

  defp peek_subscription_by_paddle_id(id) do
    Subscription.Query.all()
    |> Subscription.Query.by_paddle_subscription_id(id)
    |> Repo.peek()
  end

  @doc """
  Internal — extracts the next billing time from a Paddle subscription
  payload (used by the webhook upsert + `Workers.BillingSync`, no Subject).
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

  @doc """
  Internal — the subscription's Paddle `updated_at` (used by the webhook
  upsert + `Workers.BillingSync`, no Subject). A monotonic per-subscription
  timestamp the stale-update guard compares to drop an out-of-order delivery;
  present on both the webhook payload and the live `retrieve_subscription`.
  """
  def extract_paddle_updated_at(%{"updated_at" => iso}) when is_binary(iso),
    do: parse_iso8601(iso)

  def extract_paddle_updated_at(_), do: nil

  defp parse_iso8601(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
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
  def billing_summary(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_billing_permission()
           ),
         :ok <- ensure_subject_owns_account(account, subject) do
      subscription = peek_subscription_for_account(account.id)
      plan_name = plan_from_subscription(subscription)
      plan_def = plan(plan_name) || plan("free")
      runner_count = current_count(account, :runners)
      member_count = current_count(account, :members)

      {:ok,
       %{
         plan: plan_name,
         plan_name: plan_def.name,
         runner_count: runner_count,
         runner_limit: plan_def.runners_limit,
         member_count: member_count,
         member_limit: plan_def.members_limit,
         monthly_per_runner_cents: plan_def.monthly_price_cents,
         monthly_total_cents:
           case plan_def.monthly_price_cents do
             nil -> nil
             cents -> cents * runner_count
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

  # -- Authorization ----------------------------------------------------

  @doc "Whether `subject` may manage billing and the subscription (owner-only)."
  def subject_can_manage_billing?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_billing_permission())

  # -- Plan headroom (UI) -----------------------------------------------

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
