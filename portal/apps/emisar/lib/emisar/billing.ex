defmodule Emisar.Billing do
  @moduledoc """
  Plan + subscription glue. Paddle is the source of truth; we mirror
  the subset (plan + status + period end + entitlements) needed to enforce
  limits without round-tripping per request. Paid-plan limits live in the
  Paddle product's custom_data (see `Billing.Entitlements`) so pricing/limit
  changes need no deploy; the compiled `@plans` map is the free tier, the
  per-field fallback, and display copy. The Paddle HTTP layer is swappable
  via `Application.fetch_env!(:emisar, :paddle_client)` — production
  binds the live client, tests use the in-process stub.
  """
  use Supervisor
  import Emisar.Maps, only: [put_present: 3]
  alias Ecto.Multi
  alias Emisar.{Accounts, Analytics, Audit, Auth, PublicUrl, Repo, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.Billing.{Authorizer, Entitlements, PaddleClient, Subscription}
  require Logger

  @plans %{
    "free" => %{
      name: "Free",
      monthly_price_cents: 0,
      annual_price_cents: 0,
      runners_limit: 3,
      members_limit: 1,
      audit_retention_days: 7,
      features: ["3 runners", "1 user", "7-day audit retention", "Community support"]
    },
    "team" => %{
      name: "Team",
      monthly_price_cents: 2000,
      # Two months free vs monthly ($240/runner/yr → $200) — the display
      # figure; the charged price still comes from the live catalog at click.
      annual_price_cents: 20_000,
      runners_limit: 100,
      members_limit: :unlimited,
      audit_retention_days: 90,
      features: [
        "Unlimited users",
        "Single sign-on (OIDC)",
        "90-day audit retention",
        "Audit export (CSV + SIEM)",
        "Email support"
      ]
    },
    "enterprise" => %{
      name: "Enterprise",
      monthly_price_cents: nil,
      annual_price_cents: nil,
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

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      job_module("SyncPaddleCustomers"),
      job_module("SyncSubscriptions")
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

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

  # One derivation for every plan-gated read: the plan slug from the mirrored
  # subscription, the compiled definition (free floor when the slug is unknown
  # and no entitlement covers a field), and the Paddle-sourced entitlements
  # that override the definition per field.
  defp effective_plan(subscription) do
    plan_name = plan_from_subscription(subscription)
    known_plan = plan(plan_name)

    %{
      plan_name: plan_name,
      known_plan: known_plan,
      plan_def: known_plan || plan("free"),
      entitlements: (subscription && subscription.entitlements) || %{}
    }
  end

  # Entitlement first, compiled plan default second. `0` and `:unlimited` are
  # both truthy, so `||` only falls through on an absent entitlement.
  defp entitled_limit(%{entitlements: entitlements, plan_def: plan_def}, key),
    do: Entitlements.limit(entitlements, Atom.to_string(key)) || Map.get(plan_def, key)

  # Retention must stay a positive integer — an "unlimited" or 0-day
  # entitlement falls back rather than disabling (or instant-sweeping) audit.
  defp entitled_retention_days(%{entitlements: entitlements, plan_def: plan_def}) do
    case Entitlements.limit(entitlements, "audit_retention_days") do
      days when is_integer(days) and days > 0 -> days
      _ -> plan_def.audit_retention_days
    end
  end

  defp entitled_feature(%{entitlements: entitlements}, key, default) do
    case Entitlements.feature(entitlements, key) do
      nil -> default
      enabled -> enabled
    end
  end

  # An unknown slug (a plan minted in Paddle this build doesn't know) shows as
  # its capitalized slug, never the free plan's display name.
  defp plan_display_name(%{known_plan: %{name: name}}), do: name
  defp plan_display_name(%{plan_name: plan_name}), do: String.capitalize(plan_name)

  # The subscription's billing cadence as an atom; a nil/monthly/unknown mirror
  # (incl. no subscription) reads as :month — only an explicit "year" is annual.
  defp subscription_cycle(%Subscription{billing_interval: "year"}), do: :year
  defp subscription_cycle(_), do: :month

  # Per-runner price for the cadence — the annual rate on :year, else monthly.
  # nil for a plan this build doesn't know (custom pricing → no self-serve $).
  defp per_runner_cents(%{known_plan: %{annual_price_cents: cents}}, :year), do: cents
  defp per_runner_cents(%{known_plan: %{monthly_price_cents: cents}}, :month), do: cents
  defp per_runner_cents(_posture, _cycle), do: nil

  @doc """
  Internal — Audit's per-row retention stamp: the account's audit-retention
  window, in days. An `audit_retention_days` entitlement mirrored from Paddle
  overrides the plan default; free floor (7d) for no or an unknown/renamed
  plan (same read-tolerant degradation as `plan/1`).
  """
  def account_audit_retention_days(account_id) when is_binary(account_id) do
    account_id
    |> peek_subscription_for_account()
    |> effective_plan()
    |> entitled_retention_days()
  end

  @doc "True when the account's plan includes OIDC single sign-on (a `features_sso_enabled?` entitlement, else Team and Enterprise)."
  def sso_available?(%Accounts.Account{} = account) do
    posture = account.id |> peek_subscription_for_account() |> effective_plan()

    entitled_feature(
      posture,
      "features_sso_enabled?",
      posture.plan_name in ["team", "enterprise"]
    )
  end

  @doc "True when the account's plan includes audit-log export — the CSV download AND the SIEM/NDJSON API (a `features_audit_export_enabled?` entitlement, else Team and Enterprise). Free keeps the in-console trail; taking the data OUT is the paid surface."
  def audit_export_available?(%Accounts.Account{} = account) do
    posture = account.id |> peek_subscription_for_account() |> effective_plan()

    entitled_feature(
      posture,
      "features_audit_export_enabled?",
      posture.plan_name in ["team", "enterprise"]
    )
  end

  @doc "True when the account's plan includes SCIM directory sync (a `features_scim_enabled?` entitlement, else Enterprise only)."
  def directory_sync_available?(%Accounts.Account{} = account) do
    posture = account.id |> peek_subscription_for_account() |> effective_plan()
    entitled_feature(posture, "features_scim_enabled?", posture.plan_name == "enterprise")
  end

  # Internal nil-or-struct helper. Used by `upsert_subscription/2` and
  # webhook event application. Not exposed to LiveView/MCP because
  # there's no Subject path here.
  defp peek_subscription_for_account(account_id) do
    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Repo.peek()
  end

  @doc false
  # Internal write — called from webhook handlers and the subscription sync job,
  # which run on already-trusted server contexts. Subject-less because
  # the Paddle webhook signature is the auth gate at the edge.
  #
  # Deliberately peek-then-insert/update rather than an `on_conflict` true-upsert:
  # webhook payloads carry PARTIAL attr sets (e.g. cancel carries only `status`),
  # so a replace-set upsert would null fields the event didn't mention. The INSERT
  # race is closed by `unique_index(:billing_subscriptions, [:account_id])` (a concurrent
  # first-insert loses with a constraint error; Paddle's redelivery then takes the
  # update branch); the UPDATE race is closed by the LOCKED re-read below
  # (`fetch_and_update` → FOR NO KEY UPDATE), so a concurrent webhook + hourly
  # BillingSync (or two webhooks) serialize on the row and the loser recomputes
  # off the committed state, instead of last-write-winning a stale status over a
  # fresh one.
  def upsert_subscription(account_id, attrs) do
    existing = peek_subscription_for_account(account_id)
    old_plan = plan_from_subscription(existing)

    with {:ok, %Subscription{plan: new_plan} = subscription} <-
           write_subscription(existing, account_id, attrs) do
      # The webhook calls this inside its Multi, so the audit row commits with the
      # subscription change (atomic there); the checkout/BillingSync paths get a
      # best-effort standalone insert.
      _ = maybe_audit_plan_change(account_id, old_plan, new_plan)
      {:ok, subscription}
    end
  end

  defp write_subscription(nil, account_id, attrs) do
    Subscription.Changeset.upsert(Map.put(attrs, :account_id, account_id)) |> Repo.insert()
  end

  defp write_subscription(%Subscription{}, account_id, attrs) do
    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Repo.fetch_and_update(Subscription.Query, with: &Subscription.Changeset.upsert(&1, attrs))
  end

  # The in-app AUDIT trail of a plan change (distinct from the Mixpanel
  # `subscription_changed`): only on an actual plan transition, so a status-only
  # webhook (cancel / past_due, same plan) writes nothing.
  defp maybe_audit_plan_change(_account_id, plan, plan), do: :ok

  defp maybe_audit_plan_change(account_id, old_plan, new_plan),
    do: Audit.record(Audit.Events.subscription_changed(account_id, old_plan, new_plan))

  @doc """
  Returns :ok if the account is within plan limits for `resource`.
  Returns `{:error, :over_limit, plan, limit}` otherwise.

  Internal — called by `Runners.register_via_enrollment_key/2` on the
  bootstrap path before any Subject exists, and by `Catalog`/admin
  flows that already authorized upstream. The check itself is
  account-scoped (the runner counting), not subject-scoped.
  """
  def check_limit(%Accounts.Account{} = account, resource) do
    posture = account.id |> peek_subscription_for_account() |> effective_plan()
    limit = entitled_limit(posture, limit_key(resource))
    current = current_count(account, resource)

    cond do
      limit == :unlimited -> :ok
      current < limit -> :ok
      true -> {:error, :over_limit, posture.plan_name, limit}
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
  Creates a Paddle Checkout (Transaction) for the chosen plan + billing
  `cycle` (`:month` | `:year`) and returns the URL the operator should be
  redirected to. The price comes from the live Paddle catalog, so a
  new/changed price needs no deploy; `{:error, :plan_not_in_catalog}` when
  no product identifies as the plan or it has no active price for the
  requested cycle (nor a recurring price to fall back to).
  """
  def start_checkout(%Accounts.Account{} = account, plan_name, cycle, %Subject{} = subject)
      when is_binary(plan_name) and cycle in [:month, :year] do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      if Map.has_key?(@plans, plan_name) do
        # The returned URL is the account's DEFAULT PAYMENT LINK (our /checkout
        # page running Paddle.js) + ?_ptxn=<transaction> — Paddle has no hosted
        # checkout. Deliberately no per-transaction checkout.url override: that
        # requires its own domain approval, while the default link is the
        # canonical mechanism. The post-payment redirect is the page's
        # successUrl setting, not a transaction field.
        with {:ok, price_id} <- resolve_checkout_price_id(plan_name, cycle),
             {:ok, customer_id, _account} <- ensure_paddle_customer(account, subject),
             {:ok, %{"url" => url}} <-
               Emisar.Billing.PaddleClient.create_checkout_session(%{
                 customer: customer_id,
                 price_id: price_id,
                 # Per-runner pricing floors at ONE seat: a zero-runner
                 # account (fresh signup) must still be able to buy, and
                 # Paddle rejects quantity 0.
                 quantity: max(current_count(account, :runners), 1)
               }) do
          {:ok, url}
        end
      else
        {:error, :unknown_plan}
      end
    end
  end

  # The live catalog is the checkout-price source — one extra API call per
  # human checkout click, deliberately uncached (always fresh, no staleness
  # machinery).
  defp resolve_checkout_price_id(plan_name, cycle) do
    with {:ok, products} <- Emisar.Billing.PaddleClient.list_products() do
      products
      |> Enum.find(&(product_plan_slug(&1) == plan_name))
      |> checkout_price_of_product(cycle)
    end
  end

  # A catalog product identifies its plan by the custom_data `plan` slug,
  # falling back to its normalized display name when that matches a plan we
  # sell (the dashboard products are literally named "team"/"enterprise").
  defp product_plan_slug(product),
    do: Entitlements.plan_slug_of_product(product) || known_plan_from_name(product["name"])

  defp known_plan_from_name(name) when is_binary(name) do
    slug = name |> String.trim() |> String.downcase()
    if Map.has_key?(@plans, slug), do: slug
  end

  defp known_plan_from_name(_name), do: nil

  # Prefer the requested cycle's active price; fall back to any active
  # recurring price so a catalog listing only one cycle still resolves
  # (an annual-only plan asked for monthly, say).
  defp checkout_price_of_product(%{"prices" => prices}, cycle) when is_list(prices) do
    active = Enum.filter(prices, &(&1["status"] == "active"))

    requested =
      Enum.find(active, &(get_in(&1, ["billing_cycle", "interval"]) == cycle_interval(cycle)))

    fallback =
      Enum.find(active, &(get_in(&1, ["billing_cycle", "interval"]) in ["month", "year"]))

    case requested || fallback do
      %{"id" => price_id} -> {:ok, price_id}
      _ -> {:error, :plan_not_in_catalog}
    end
  end

  defp checkout_price_of_product(_product, _cycle), do: {:error, :plan_not_in_catalog}

  defp cycle_interval(:month), do: "month"
  defp cycle_interval(:year), do: "year"

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
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      do_open_billing_portal(account)
    end
  end

  defp do_open_billing_portal(%Accounts.Account{paddle_customer_id: nil}),
    do: {:error, :no_customer}

  defp do_open_billing_portal(%Accounts.Account{paddle_customer_id: customer_id})
       when is_binary(customer_id) do
    # Bare /app — the slugless billing path doesn't resolve (every tenant page
    # nests under the account slug); /app redirects to the session's account.
    return_url = PublicUrl.url("/app")

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

  @doc """
  Recent invoices (Paddle transactions) for the account's customer — number,
  date, amount, status — so the billing page shows a payment history inline
  without a trip to the portal (the portal still owns the full ledger + PDFs).
  `{:ok, []}` for an account that's never been billed (no `paddle_customer_id`).
  Gated on view-billing, like the summary. Returns `{:ok, [invoice_map]}`.
  """
  def list_recent_invoices(%Accounts.Account{} = account, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_billing_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      do_list_recent_invoices(account, opts)
    end
  end

  @doc """
  The signed, short-lived URL of one transaction's invoice PDF, so a billing
  manager can download an invoice inline instead of opening the portal. Gated on
  view-billing; the transaction is re-checked against the account's own recent
  invoices first, so a crafted id can't pull another account's PDF —
  `{:error, :not_found}` otherwise.
  """
  def invoice_pdf_url(%Accounts.Account{} = account, transaction_id, %Subject{} = subject)
      when is_binary(transaction_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_billing_permission()),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         {:ok, invoices} <- do_list_recent_invoices(account, limit: 24),
         true <- Enum.any?(invoices, &(&1.id == transaction_id)) do
      Emisar.Billing.PaddleClient.get_transaction_invoice(transaction_id)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp do_list_recent_invoices(%Accounts.Account{paddle_customer_id: nil}, _opts), do: {:ok, []}

  defp do_list_recent_invoices(%Accounts.Account{paddle_customer_id: customer_id}, opts)
       when is_binary(customer_id) do
    limit = Keyword.get(opts, :limit, 6)

    case Emisar.Billing.PaddleClient.list_transactions(%{customer: customer_id, limit: limit}) do
      {:ok, txns} -> {:ok, Enum.map(txns, &to_invoice/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Paddle transaction → the flat shape the billing page renders. grand_total is
  # a minor-unit STRING ("2000" = $20.00); billed_at is ISO-8601.
  defp to_invoice(txn) do
    %{
      id: txn["id"],
      invoice_number: txn["invoice_number"],
      status: txn["status"],
      currency: txn["currency_code"] || "USD",
      amount_cents: parse_invoice_amount(get_in(txn, ["details", "totals", "grand_total"])),
      billed_at: parse_invoice_datetime(txn["billed_at"])
    }
  end

  defp parse_invoice_amount(v) when is_integer(v), do: v

  defp parse_invoice_amount(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_invoice_amount(_), do: 0

  defp parse_invoice_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_invoice_datetime(_), do: nil

  @doc """
  Ensures the account has a Paddle customer. Requires `manage` on billing and the subject's account.

  Returns `{:ok, customer_id, account}` or `{:error, term}`.

  The Paddle customer is owned by the account's stable active owner contact,
  not necessarily the actor who clicked checkout. Existing customers are
  updated so Paddle keeps the current account name + owner email.
  """
  def ensure_paddle_customer(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      sync_paddle_customer_for_account(account.id)
    end
  end

  @doc """
  Internal — sync one account's Paddle customer from the current account name
  and stable active owner contact. Called by checkout after its Subject gate and
  by `Billing.Jobs.SyncPaddleCustomers` as a trusted server sweep.
  """
  def sync_paddle_customer_for_account(account_id) when is_binary(account_id) do
    with {:ok, %{account: account, owner: owner}} <-
           Accounts.fetch_paddle_customer_sync_target(account_id) do
      sync_paddle_customer(account, owner)
    end
  end

  @doc """
  Internal — sync a bounded page of accounts whose Paddle customer mirror is
  missing or stale. Returns sweep metadata so the worker can enqueue the next
  page without owning the account query.
  """
  def sync_paddle_customers(opts \\ []) do
    opts = normalize_paddle_customer_sync_opts(opts)
    accounts = Accounts.list_paddle_customer_sync_accounts(opts)

    Enum.each(accounts, &sync_paddle_customer_safely/1)

    {:ok,
     %{
       processed: length(accounts),
       last_account_id: last_account_id(accounts),
       full?: length(accounts) == opts[:limit],
       limit: opts[:limit]
     }}
  end

  defp sync_paddle_customer_safely(%Accounts.Account{id: account_id}) do
    case sync_paddle_customer_for_account(account_id) do
      {:ok, _customer_id, _account} ->
        :ok

      {:error, reason} when reason in [:no_billing_contact, :not_found] ->
        :ok

      {:error, reason} ->
        Logger.warning("paddle_customer_sync.failed",
          account_id: account_id,
          error: inspect(redacted_paddle_error(reason))
        )
    end
  end

  defp sync_paddle_customer(%Accounts.Account{paddle_customer_id: nil} = account, owner) do
    with {:ok, %{"id" => customer_id}} <-
           PaddleClient.create_customer(customer_attrs(account, owner)),
         {:ok, linked} <-
           Accounts.put_account_paddle_customer_sync(account, customer_id, owner.id) do
      sync_linked_paddle_customer(linked, customer_id, owner)
    else
      {:ok, _data} -> {:error, :missing_customer_id}
      other -> other
    end
  end

  defp sync_paddle_customer(
         %Accounts.Account{paddle_customer_id: customer_id} = account,
         owner
       )
       when is_binary(customer_id) do
    with {:ok, _customer} <- update_paddle_customer(account, owner),
         {:ok, synced} <-
           Accounts.put_account_paddle_customer_sync(account, customer_id, owner.id) do
      {:ok, synced.paddle_customer_id, synced}
    end
  end

  defp sync_linked_paddle_customer(%Accounts.Account{} = account, customer_id, owner) do
    if account.paddle_customer_id == customer_id do
      {:ok, customer_id, account}
    else
      with {:ok, _customer} <- update_paddle_customer(account, owner),
           {:ok, synced} <-
             Accounts.put_account_paddle_customer_sync(
               account,
               account.paddle_customer_id,
               owner.id
             ) do
        {:ok, synced.paddle_customer_id, synced}
      end
    end
  end

  defp update_paddle_customer(%Accounts.Account{paddle_customer_id: customer_id} = account, owner)
       when is_binary(customer_id) do
    account
    |> customer_attrs(owner)
    |> Map.put(:customer, customer_id)
    |> PaddleClient.update_customer()
  end

  defp customer_attrs(%Accounts.Account{} = account, owner) do
    %{email: owner.email, name: account.name, account_id: account.id}
  end

  defp normalize_paddle_customer_sync_opts(opts) when is_map(opts) do
    [
      limit:
        normalize_paddle_customer_sync_limit(Map.get(opts, "limit") || Map.get(opts, :limit)),
      after_account_id: Map.get(opts, "after_account_id") || Map.get(opts, :after_account_id)
    ]
  end

  defp normalize_paddle_customer_sync_opts(opts) when is_list(opts) do
    [
      limit: normalize_paddle_customer_sync_limit(Keyword.get(opts, :limit)),
      after_account_id: Keyword.get(opts, :after_account_id)
    ]
  end

  defp normalize_paddle_customer_sync_limit(n) when is_integer(n) and n > 0,
    do: min(n, 500)

  defp normalize_paddle_customer_sync_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} -> normalize_paddle_customer_sync_limit(parsed)
      _ -> 100
    end
  end

  defp normalize_paddle_customer_sync_limit(_), do: 100

  defp last_account_id([]), do: nil
  defp last_account_id(accounts), do: List.last(accounts).id

  @doc """
  Internal — collapses a Paddle client / mirror-write failure into a loggable
  term that carries no payload values, so every Paddle-error log line in this
  context (customer sync + the hourly subscription reconciliation) shares one
  scrub. An HTTP failure keeps only its status (never the response body); an
  upsert changeset keeps only its failing field names (never `.changes`, which
  echo mirrored subscription values); any other reason passes through.
  """
  def redacted_paddle_error({:http, status, _body}), do: {:http, status}

  def redacted_paddle_error(%Ecto.Changeset{errors: errors}) do
    {:invalid_changeset, errors |> Keyword.keys() |> Enum.uniq()}
  end

  def redacted_paddle_error(reason), do: reason

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
        cancel_scheduled? = scheduled_cancel?(subscription_data)

        # Plan identity: the product custom_data's own slug wins, then the
        # embedded product's name when it matches a plan we sell, then the
        # account's current plan — so the subscription can always persist
        # rather than failing validate_required([:plan]) and stranding the
        # account's entitlement.
        plan =
          Entitlements.plan_slug(subscription_data) ||
            known_plan_from_name(Entitlements.product_name(subscription_data)) ||
            account_plan(account)

        # A partial subscription.updated (status-only, no items / next_billed_at)
        # must not null price/period/entitlements — omit those keys via
        # put_present so the peek-then-update preserves the stored values rather
        # than casting them to nil. `cancel_at_period_end` IS always set:
        # Paddle's payload carries the full object, so it reflects the current
        # scheduled state, and the billing dashboard's "cancels on …" banner
        # must CLEAR when a scheduled cancel is removed — not just appear when
        # one is added.
        attrs =
          %{
            paddle_subscription_id: subscription_data["id"],
            plan: plan,
            status: subscription_data["status"],
            cancel_at_period_end: cancel_scheduled?
          }
          |> Map.merge(subscription_item_attrs(subscription_data))
          |> put_present(:entitlements, Entitlements.from_paddle_subscription(subscription_data))
          |> put_present(:current_period_end, period_end(subscription_data, cancel_scheduled?))
          |> put_present(:current_period_start, extract_current_period_start(subscription_data))
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

  @doc false
  # Paddle bills one recurring line item. Keep all price-derived mirror fields
  # together so webhooks and the reconciliation sweep cannot drift. Invalid or
  # absent vendor values are omitted, preserving the last known-good mirror.
  def subscription_item_attrs(%{"items" => [%{"price" => price} = item | _]})
      when is_map(price) do
    cycle = map_or_empty(price["billing_cycle"])
    unit_price = map_or_empty(price["unit_price"])

    %{}
    |> put_present(:paddle_price_id, present_binary(price["id"]))
    |> put_present(:billing_interval, present_binary(cycle["interval"]))
    |> put_present(:billing_frequency, positive_integer(cycle["frequency"]))
    |> put_present(:unit_price_amount, non_negative_integer(unit_price["amount"]))
    |> put_present(:currency_code, currency_code(unit_price["currency_code"]))
    |> put_present(:quantity, positive_integer(item["quantity"]))
  end

  def subscription_item_attrs(_subscription_data), do: %{}

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp present_binary(value) when is_binary(value) and value != "", do: value
  defp present_binary(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp currency_code(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Z]{3}$/), do: value
  end

  defp currency_code(_value), do: nil

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
  payload (used by the webhook upsert + subscription sync job, no Subject).
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
  upsert + subscription sync job, no Subject). A monotonic per-subscription
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
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      subscription = peek_subscription_for_account(account.id)
      posture = effective_plan(subscription)
      runner_count = current_count(account, :runners)
      member_count = current_count(account, :members)
      # nil pricing for a plan this build doesn't know (a slug minted in
      # Paddle) — the UI treats it like custom pricing, not free's $0.
      monthly_cents = posture.known_plan && posture.known_plan.monthly_price_cents
      # The mirrored cadence prices the period: an annual subscriber's summary
      # must read "$X/yr" at the annual per-runner rate, not the monthly one.
      cycle = subscription_cycle(subscription)
      period_cents = per_runner_cents(posture, cycle)

      {:ok,
       %{
         plan: posture.plan_name,
         plan_name: plan_display_name(posture),
         runner_count: runner_count,
         runner_limit: entitled_limit(posture, :runners_limit),
         member_count: member_count,
         member_limit: entitled_limit(posture, :members_limit),
         monthly_per_runner_cents: monthly_cents,
         monthly_total_cents: monthly_cents && monthly_cents * runner_count,
         billing_interval: cycle,
         period_total_cents: period_cents && period_cents * runner_count,
         audit_retention_days: entitled_retention_days(posture),
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
