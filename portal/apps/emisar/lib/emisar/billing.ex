defmodule Emisar.Billing do
  @moduledoc """
  Plan + subscription glue. Paddle is the source of truth for paid
  subscriptions; a subscription row without a Paddle id may carry a manually
  granted complimentary plan. We mirror the subset (plan + status + period end
  + entitlements) needed to enforce limits without round-tripping per request.
  Paid-plan limits live in the Paddle product's custom_data (see
  `Billing.Entitlements`) so pricing/limit changes need no deploy; the compiled
  `@plans` map is the free tier, per-field fallback, and display copy. The
  Paddle HTTP layer is swappable via
  `Emisar.Config.fetch_env!(:emisar, :paddle_client)` — production binds the live
  client, tests bind the in-process stub per test with `Emisar.Config.put_override/3`.
  """
  use Supervisor
  import Emisar.Maps, only: [put_present: 3]
  alias Ecto.Multi
  alias Emisar.{Accounts, Analytics, Audit, Auth, Crypto, Mailers, Repo, Runners, Throttle}
  alias Emisar.Auth.Subject
  alias Emisar.Billing.{Authorizer, Entitlements, PaddleClient, Subscription}
  alias Emisar.Billing.{CheckoutIntent, Checkouts, CustomerLinkCode, ProcessedEvent}
  alias Emisar.Billing.{SubscriptionRetirement, SubscriptionRetirements}
  require Logger

  # Feature IDs are the stable plan-membership contract; labels are the shared
  # copy rendered by both BillingLive and the public pricing page.
  @plans %{
    "free" => %{
      name: "Free",
      monthly_price_cents: 0,
      annual_price_cents: 0,
      runners_limit: 3,
      members_limit: 1,
      audit_retention_days: 7,
      features: [
        runners: "3 runners",
        members: "1 user",
        audit_retention: "7-day audit retention"
        # Free is self-serve; product support starts with Team. Billing,
        # account recovery and security reporting remain separate paths.
      ]
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
        members: "Unlimited users",
        sso: "Single sign-on (OIDC)",
        audit_retention: "90-day audit retention",
        audit_export: "Audit export (CSV + SIEM)",
        support: "Email support"
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
        team: "Everything in Team",
        scim: "SCIM directory sync",
        audit_retention: "365-day audit retention",
        security_review: "Security and procurement review",
        support: "Slack and email support",
        deployment_planning: "Design-partner deployment planning",
        rollout_support: "Rollout support"
      ]
    }
  }

  # The longest retention any plan defines. An unrecognized plan slug retains for
  # this long rather than the free floor, because the number drives destructive
  # sweeps — see plan_retention_days/1.
  @max_plan_retention_days @plans
                           |> Map.values()
                           |> Enum.map(& &1.audit_retention_days)
                           |> Enum.max()

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      job_module("ProcessedEventRetention"),
      job_module("SyncRunnerQuantities"),
      job_module("SyncSubscriptions")
    ]

    children =
      if Emisar.Config.fetch_env!(:emisar, :paddle_client) == PaddleClient.Stub,
        do: [PaddleClient.Stub.TransactionStore | children],
        else: children

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  def plans, do: @plans
  def plan(name) when is_binary(name), do: Map.get(@plans, name)

  @doc "True only for a plan and cadence sold through self-service checkout."
  def self_service_checkout?("team", cycle) when cycle in [:month, :year], do: true
  def self_service_checkout?(_plan, _cycle), do: false

  @doc "Display copy for an exact whole-month annual discount; nil when there is none."
  def annual_savings_label(%{
        monthly_price_cents: monthly,
        annual_price_cents: annual
      })
      when is_integer(monthly) and monthly > 0 and is_integer(annual) do
    savings = monthly * 12 - annual

    if savings > 0 and rem(savings, monthly) == 0 do
      months = div(savings, monthly)
      "#{months} #{if months == 1, do: "month", else: "months"} free"
    end
  end

  def annual_savings_label(_plan), do: nil

  defp stored_plan_from_subscription(%Subscription{plan: plan}) when is_binary(plan), do: plan
  defp stored_plan_from_subscription(_), do: "free"

  @doc """
  Billing's typed access projection over durable Paddle facts.

  Paddle owns automatic dunning duration. Scheduled cancellation or pause ends
  access at the exact effective timestamp even when the terminal webhook or
  hourly repair is late. A manually collected or malformed past-due state is
  unresolved because Paddle does not drive it to a terminal state for us.
  """
  def entitlement_state(subscription, now \\ DateTime.utc_now())

  def entitlement_state(nil, _now), do: :free

  def entitlement_state(%Subscription{status: "complimentary"}, _now), do: :active

  def entitlement_state(%Subscription{status: status} = subscription, now)
      when status in ["active", "trialing", "past_due"] do
    case base_entitlement_state(subscription) do
      :unresolved ->
        :unresolved

      base_state ->
        scheduled_entitlement_state(subscription, now) || base_state
    end
  end

  def entitlement_state(%Subscription{status: status}, _now)
      when status in ["paused", "canceled"],
      do: :expired

  def entitlement_state(%Subscription{}, _now), do: :unresolved

  defp scheduled_entitlement_state(%Subscription{} = subscription, now) do
    {action, effective_at} = scheduled_change(subscription)

    cond do
      is_nil(action) ->
        nil

      action in ["cancel", "pause"] and is_struct(effective_at, DateTime) ->
        if DateTime.compare(now, effective_at) == :lt, do: :ending, else: :expired

      true ->
        :unresolved
    end
  end

  defp scheduled_change(nil), do: {nil, nil}

  defp scheduled_change(%Subscription{} = subscription) do
    {
      subscription.scheduled_change_action ||
        if(subscription.cancel_at_period_end, do: "cancel"),
      subscription.scheduled_change_effective_at ||
        if(subscription.cancel_at_period_end, do: subscription.current_period_end)
    }
  end

  defp base_entitlement_state(%Subscription{status: status})
       when status in ["active", "trialing"],
       do: :active

  defp base_entitlement_state(%Subscription{status: "past_due", collection_mode: "automatic"}),
    do: :dunning

  defp base_entitlement_state(%Subscription{status: "past_due"}), do: :unresolved

  defp entitled_state?(state), do: state in [:active, :dunning, :ending]

  # One derivation for every plan-gated read: the plan slug from the mirrored
  # subscription, the compiled definition (free floor when the slug is unknown
  # and no entitlement covers a field), and the Paddle-sourced entitlements
  # that override the definition per field.
  defp effective_plan(subscription) do
    stored_plan_name = stored_plan_from_subscription(subscription)
    entitlement_state = entitlement_state(subscription)
    plan_name = if entitled_state?(entitlement_state), do: stored_plan_name, else: "free"
    known_plan = plan(plan_name)

    %{
      plan_name: plan_name,
      stored_plan_name: stored_plan_name,
      entitlement_state: entitlement_state,
      known_plan: known_plan,
      plan_def: known_plan || plan("free"),
      entitlements:
        if(entitled_state?(entitlement_state),
          do: (subscription && subscription.entitlements) || %{},
          else: %{}
        )
    }
  end

  # Entitlement first, compiled plan default second. `0` and `:unlimited` are
  # both truthy, so `||` only falls through on an absent entitlement.
  defp entitled_limit(%{entitlements: entitlements, plan_def: plan_def}, key),
    do: Entitlements.limit(entitlements, Atom.to_string(key)) || Map.get(plan_def, key)

  # Retention must stay a positive integer — an "unlimited" or 0-day
  # entitlement falls back rather than disabling (or instant-sweeping) audit.
  defp entitled_retention_days(%{entitlements: entitlements} = posture) do
    if posture.entitlement_state == :unresolved do
      @max_plan_retention_days
    else
      case Entitlements.limit(entitlements, "audit_retention_days") do
        days when is_integer(days) and days > 0 -> days
        _ -> plan_retention_days(posture)
      end
    end
  end

  # Read-tolerant degradation is right for DISPLAY, but this number also drives
  # two sweeps that Repo.delete_all run history. Collapsing an unrecognized plan
  # slug to the free floor meant one renamed Paddle price — or a mistyped
  # entitlement key, which Entitlements.parse drops silently — would prune a
  # paying account's runs to 7 days on the next daily tick, irreversibly.
  #
  # So an unknown plan fails OPEN to the longest window we define: keeping data
  # too long is a correctable mistake, deleting it is not. A KNOWN plan still
  # uses its own retention, which is what a deliberate downgrade should do.
  defp plan_retention_days(%{known_plan: nil, plan_name: plan_name}) do
    Logger.warning(
      "billing: unknown plan #{inspect(plan_name)}; retaining for the longest window"
    )

    @max_plan_retention_days
  end

  defp plan_retention_days(%{plan_def: plan_def}), do: plan_def.audit_retention_days

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

  # What Paddle actually charges this period, with the currency it charges in.
  #
  # A live subscription mirrors its own recurring price, so prefer that: the
  # compiled catalog is a USD LIST price, and the live runner count is not the
  # billed quantity (Paddle re-prices on its own cadence). Deriving the total
  # from those two showed a subscriber billed €60 for 3 seats a summary reading
  # "$200.00/mo" — wrong number AND wrong currency.
  #
  # The catalog stays the fallback for an account that has never subscribed, and
  # for a legacy row the reconciliation job has not backfilled yet.
  defp period_total_cents(subscription, posture, cycle, runner_count)

  defp period_total_cents(
         %Subscription{paddle_subscription_id: nil, status: "complimentary"},
         _posture,
         _cycle,
         _runner_count
       ),
       do: {0, "USD"}

  defp period_total_cents(
         %Subscription{unit_price_amount: amount, currency_code: code, quantity: quantity},
         _posture,
         _cycle,
         _runner_count
       )
       when is_integer(amount) and is_binary(code),
       do: {amount * (quantity || 1), code}

  defp period_total_cents(_subscription, posture, cycle, runner_count) do
    cents = per_runner_cents(posture, cycle)
    {cents && cents * runner_count, "USD"}
  end

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
    sso_available_for_account_id?(account.id)
  end

  @doc false
  def sso_available_for_account_id?(account_id, opts \\ []) when is_binary(account_id) do
    posture = account_id |> subscription_for_account(opts) |> effective_plan()

    entitled_feature(
      posture,
      "features_sso_enabled?",
      posture.plan_name in ["team", "enterprise"]
    )
  end

  @doc "True when the account's plan includes audit-log export — the CSV download AND the SIEM/NDJSON API (a `features_audit_export_enabled?` entitlement, else Team and Enterprise). Free keeps the in-console trail; taking the data OUT is the paid surface."
  def audit_export_available?(%Accounts.Account{} = account) do
    audit_export_available_for_account_id?(account.id)
  end

  @doc false
  def audit_export_available_for_account_id?(account_id, opts \\ []) when is_binary(account_id) do
    posture = account_id |> subscription_for_account(opts) |> effective_plan()

    entitled_feature(
      posture,
      "features_audit_export_enabled?",
      posture.plan_name in ["team", "enterprise"]
    )
  end

  @doc "True when the account's plan includes SCIM directory sync (a `features_scim_enabled?` entitlement, else Enterprise only)."
  def directory_sync_available?(%Accounts.Account{} = account) do
    directory_sync_available_for_account_id?(account.id)
  end

  @doc false
  def directory_sync_available_for_account_id?(account_id, opts \\ [])
      when is_binary(account_id) do
    posture = account_id |> subscription_for_account(opts) |> effective_plan()
    entitled_feature(posture, "features_scim_enabled?", posture.plan_name == "enterprise")
  end

  # Internal nil-or-struct helper. Used by `upsert_subscription/2` and
  # webhook event application. Not exposed to LiveView/MCP because
  # there's no Subject path here.
  defp peek_subscription_for_account(account_id), do: subscription_for_account(account_id, [])

  @doc """
  Whether the account's plan is governed by a live Paddle subscription — the
  case a manual plan flip cannot hold, because the hourly `SyncSubscriptions`
  re-mirrors the plan from Paddle within the hour.
  """
  def paddle_managed?(account_id) when is_binary(account_id) do
    match?(
      %Subscription{paddle_subscription_id: id} when is_binary(id),
      subscription_for_account(account_id, [])
    )
  end

  defp subscription_for_account(account_id, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    queryable =
      Subscription.Query.all()
      |> Subscription.Query.by_account_id(account_id)

    queryable =
      if Keyword.get(opts, :lock?, false),
        do: Subscription.Query.lock_for_update(queryable),
        else: queryable

    repo.peek(queryable)
  end

  @doc "Internal support read: return plan and its source without exposing Paddle secrets."
  def support_plan(%Accounts.Account{} = account) do
    subscription = peek_subscription_for_account(account.id)

    {:ok,
     %{
       plan: effective_plan(subscription).plan_name,
       subscribed_plan: stored_plan_from_subscription(subscription),
       entitlement_state: entitlement_state(subscription),
       source: plan_source(subscription),
       subscription_status: subscription && subscription.status,
       paddle_subscription_id: subscription && subscription.paddle_subscription_id
     }}
  end

  @doc "Internal support write: reconcile one Paddle-managed subscription now."
  def sync_subscription_for_support(%Accounts.Account{} = account) do
    case peek_subscription_for_account(account.id) do
      %Subscription{paddle_subscription_id: paddle_id} = subscription when is_binary(paddle_id) ->
        with {:ok, subscription_data} <- PaddleClient.retrieve_subscription(paddle_id) do
          reconcile_subscription_data(subscription_data, expected_subscription: subscription)
        end

      _ ->
        {:error, :not_paddle_managed}
    end
  end

  @doc """
  Internal — `Accounts.close_account/3`: cancel this account's Paddle
  subscription so a closed account stops being billed.

  `:ok` when there was nothing to cancel (never subscribed, complimentary, or
  already canceled) — closing an account that never paid is not an error. The
  subscription row is left in place: the account is tombstoned around it, and
  the row is the record of what was billed.
  """
  def cancel_subscription_for_close(%Accounts.Account{} = account) do
    with :ok <- Checkouts.cancel_for_close(account.id),
         :ok <- cancel_canonical_subscription(account) do
      SubscriptionRetirements.cancel_for_close(account.id)
    end
  end

  defp cancel_canonical_subscription(account) do
    case peek_subscription_for_account(account.id) do
      %Subscription{paddle_subscription_id: id, status: status} = captured
      when is_binary(id) and status != "canceled" ->
        with {:ok, canceled} <- confirm_canonical_cancellation(id, account.paddle_customer_id),
             {:ok, %Subscription{paddle_subscription_id: ^id, status: "canceled"}} <-
               reconcile_subscription_data(canceled, expected_subscription: captured) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          _unconfirmed -> {:error, :cancellation_not_confirmed}
        end

      _ ->
        :ok
    end
  end

  defp confirm_canonical_cancellation(id, customer_id) do
    with {:ok, %{"id" => ^id, "status" => status} = subscription} <-
           PaddleClient.retrieve_subscription(id),
         :ok <- ensure_canonical_customer(subscription, customer_id) do
      case status do
        "canceled" ->
          {:ok, subscription}

        status when status in ~w[active trialing past_due paused] ->
          with {:ok, %{"id" => ^id, "status" => "canceled"} = canceled} <-
                 PaddleClient.cancel_subscription(id),
               :ok <- ensure_canonical_customer(canceled, customer_id) do
            {:ok, canceled}
          else
            {:error, reason} -> {:error, reason}
            _unconfirmed -> {:error, :cancellation_not_confirmed}
          end

        _unknown ->
          {:error, :cancellation_not_confirmed}
      end
    else
      {:error, reason} -> {:error, reason}
      _unconfirmed -> {:error, :cancellation_not_confirmed}
    end
  end

  # Paddle always names the customer a subscription bills; it has to be this
  # account's before closure cancels anything.
  defp ensure_canonical_customer(%{"customer_id" => customer_id}, customer_id)
       when is_binary(customer_id),
       do: :ok

  defp ensure_canonical_customer(_data, _customer_id), do: {:error, :cancellation_not_confirmed}

  @doc "Internal: DB-only final closure check; Accounts holds the account row lock."
  def ensure_ready_to_close(%Accounts.Account{} = account, opts) do
    repo = Keyword.fetch!(opts, :repo)
    subscription = subscription_for_account(account.id, repo: repo, lock?: true)

    intent =
      CheckoutIntent.Query.by_account_id(account.id)
      |> CheckoutIntent.Query.pending()
      |> CheckoutIntent.Query.lock_for_update()
      |> repo.peek()

    retirement =
      SubscriptionRetirement.Query.by_account_id(account.id)
      |> SubscriptionRetirement.Query.pending()
      |> SubscriptionRetirement.Query.limit_to(1)
      |> SubscriptionRetirement.Query.lock_for_update()
      |> repo.peek()

    cond do
      match?(
        %Subscription{paddle_subscription_id: id, status: status}
        when is_binary(id) and status != "canceled",
        subscription
      ) ->
        {:error, :cancellation_not_confirmed}

      not is_nil(intent) ->
        {:error, :checkout_pending}

      not is_nil(retirement) ->
        {:error, :subscription_retirement_pending}

      true ->
        :ok
    end
  end

  @doc "Internal support write: grant or replace a non-Paddle complimentary plan."
  def grant_complimentary_plan(%Accounts.Account{} = account, plan)
      when plan in ["team", "enterprise"] do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account.id, repo: repo)
    end)
    |> Multi.run(:subscription_write, fn repo, _changes ->
      existing = subscription_for_account(account.id, repo: repo, lock?: true)
      old_snapshot = entitlement_snapshot(existing)

      result =
        case existing do
          nil ->
            write_subscription(
              repo,
              nil,
              account.id,
              %{plan: plan, status: "complimentary"},
              :manual
            )

          %Subscription{paddle_subscription_id: nil, status: "complimentary"} ->
            write_subscription(
              repo,
              existing,
              account.id,
              %{plan: plan, status: "complimentary"},
              :manual
            )

          %Subscription{} ->
            {:error, :paddle_or_legacy_subscription_present}
        end

      with {:ok, %Subscription{} = subscription} <- result do
        {:ok,
         %{
           subscription: subscription,
           old_snapshot: old_snapshot,
           new_snapshot: entitlement_snapshot(subscription)
         }}
      end
    end)
    |> Multi.run(:audit, fn repo, %{subscription_write: change} ->
      case entitlement_change_audit(account.id, change.old_snapshot, change.new_snapshot) do
        nil -> {:ok, nil}
        changeset -> repo.insert(changeset)
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{subscription_write: %{subscription: subscription}}} -> {:ok, subscription}
      {:error, reason} -> {:error, reason}
    end
  end

  def grant_complimentary_plan(%Accounts.Account{}, _plan),
    do: {:error, :invalid_complimentary_plan}

  @doc "Internal support write: revoke only a complimentary subscription row."
  def revoke_complimentary_plan(%Accounts.Account{} = account) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account.id, repo: repo)
    end)
    |> Multi.run(:subscription_write, fn repo, _changes ->
      existing = subscription_for_account(account.id, repo: repo, lock?: true)
      old_snapshot = entitlement_snapshot(existing)

      case existing do
        nil ->
          {:ok,
           %{
             result: :already_free,
             old_snapshot: old_snapshot,
             new_snapshot: old_snapshot
           }}

        %Subscription{paddle_subscription_id: nil, status: "complimentary"} = subscription ->
          with {:ok, deleted} <- repo.delete(subscription) do
            {:ok,
             %{
               result: deleted,
               old_snapshot: old_snapshot,
               new_snapshot: entitlement_snapshot(nil)
             }}
          end

        %Subscription{} ->
          {:error, :not_complimentary}
      end
    end)
    |> Multi.run(:audit, fn repo, %{subscription_write: change} ->
      case entitlement_change_audit(account.id, change.old_snapshot, change.new_snapshot) do
        nil -> {:ok, nil}
        changeset -> repo.insert(changeset)
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{subscription_write: %{result: result}}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plan_source(%Subscription{paddle_subscription_id: nil, status: "complimentary"}),
    do: "complimentary"

  defp plan_source(%Subscription{paddle_subscription_id: id}) when is_binary(id), do: "paddle"
  defp plan_source(%Subscription{}), do: "legacy_manual"
  defp plan_source(nil), do: "free"

  @doc false
  # Internal write — called from webhook handlers and the subscription sync job,
  # which run on already-trusted server contexts. Subject-less because the
  # webhook's signature gate ran first, in `ingest_paddle_webhook/2`.
  #
  # Deliberately lock-then-insert/update rather than an `on_conflict` true-upsert:
  # webhook payloads carry PARTIAL attr sets (e.g. cancel carries only `status`),
  # so a replace-set upsert would null fields the event didn't mention. The INSERT
  # race is closed by `unique_index(:billing_subscriptions, [:account_id])` (a concurrent
  # first-insert loses with a constraint error; Paddle's redelivery then takes the
  # update branch); the UPDATE race is closed by the LOCKED re-read below
  # (`fetch_and_update` → FOR NO KEY UPDATE), so a concurrent webhook + hourly
  # BillingSync (or two webhooks) serialize on the row and the loser recomputes
  # off the committed state, instead of last-write-winning a stale status over a
  # fresh one.
  def upsert_subscription(account_id, attrs, opts \\ []) do
    writer =
      cond do
        Keyword.get(opts, :manual, false) -> :manual
        Keyword.get(opts, :replace_provider?, false) -> :replace
        true -> :upsert
      end

    reject_deleted? = Keyword.get(opts, :reject_deleted?, false)

    Multi.new()
    # Lifecycle writers take the same account -> subscription order as SSO,
    # SCIM, capacity writes, and account closure. A callback that began before a
    # cancellation must therefore either commit first or observe the new state;
    # it can never pass a stale entitlement check while the cancellation lands.
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account_id,
        repo: repo,
        include_deleted?: true
      )
    end)
    |> Multi.run(:subscription_write, fn repo, %{account: account} ->
      existing = subscription_for_account(account_id, repo: repo, lock?: true)
      old_snapshot = entitlement_snapshot(existing)

      if reject_deleted? and match?(%Accounts.Account{deleted_at: %DateTime{}}, account) do
        {:ok,
         %{
           subscription: :account_closed,
           old_snapshot: old_snapshot,
           new_snapshot: old_snapshot
         }}
      else
        with :ok <- ensure_expected_mirror(existing, opts),
             {:ok, %Subscription{} = subscription} <-
               write_subscription(repo, existing, account_id, attrs, writer) do
          {:ok,
           %{
             subscription: subscription,
             old_snapshot: old_snapshot,
             new_snapshot: entitlement_snapshot(subscription)
           }}
        end
      end
    end)
    |> Multi.run(:audit, fn repo, %{subscription_write: change} ->
      case entitlement_change_audit(
             account_id,
             change.old_snapshot,
             change.new_snapshot
           ) do
        nil -> {:ok, nil}
        changeset -> repo.insert(changeset)
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{subscription_write: %{subscription: :account_closed}}} ->
        {:error, :account_closed}

      {:ok, %{subscription_write: %{subscription: subscription}}} ->
        {:ok, subscription}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_expected_mirror(existing, opts) do
    case Keyword.fetch(opts, :expected_mirror) do
      :error ->
        :ok

      {:ok, expected} ->
        if mirror_version(existing) == expected,
          do: :ok,
          else: {:error, :stale_reconciliation}
    end
  end

  defp mirror_version(nil), do: nil
  defp mirror_version(%Subscription{id: id, updated_at: updated_at}), do: {id, updated_at}

  defp write_subscription(repo, nil, account_id, attrs, writer) do
    attrs = request_initial_runner_quantity_sync(nil, attrs)

    apply(Subscription.Changeset, writer, [Map.put(attrs, :account_id, account_id)])
    |> repo.insert()
  end

  defp write_subscription(repo, %Subscription{} = subscription, _account_id, attrs, writer) do
    attrs = request_initial_runner_quantity_sync(subscription, attrs)

    apply(Subscription.Changeset, writer, [subscription, attrs])
    |> repo.update()
  end

  defp request_initial_runner_quantity_sync(existing, attrs) do
    paddle_id = attrs[:paddle_subscription_id]
    status = attrs[:status]
    existing_paddle_id = existing && existing.paddle_subscription_id

    if is_binary(paddle_id) and paddle_id != existing_paddle_id and
         status not in ["canceled", "paused"] do
      Map.put(attrs, :runner_quantity_sync_requested_at, DateTime.utc_now())
    else
      attrs
    end
  end

  @doc false
  def request_runner_quantity_sync(account_id, opts) when is_binary(account_id) do
    repo = Keyword.fetch!(opts, :repo)
    now = DateTime.utc_now()

    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Subscription.Query.paddle_managed()
    |> Subscription.Query.quantity_syncable()
    |> repo.update_all(set: [runner_quantity_sync_requested_at: now])

    {:ok, :requested}
  end

  @doc false
  def reconcile_runner_quantity(subscription_id) when is_binary(subscription_id) do
    Subscription.Query.all()
    |> Subscription.Query.by_id(subscription_id)
    |> Repo.peek()
    |> reconcile_unlocked_runner_quantity()
  end

  # The Paddle round-trips deliberately hold NO lock on the subscription row.
  # Every runner enrollment, enable, disable and delete ends by stamping
  # `runner_quantity_sync_requested_at` on exactly this row, and that UPDATE
  # takes the same `FOR NO KEY UPDATE` the reconciler used to hold — so an
  # installer enrolling while Paddle was slow waited past Ecto's 15s default and
  # failed with nothing actually wrong. The convergence is persisted afterwards,
  # under a short lock that compares against the row this pass read.
  defp reconcile_unlocked_runner_quantity(nil), do: {:ok, :missing}

  defp reconcile_unlocked_runner_quantity(%Subscription{paddle_subscription_id: nil}),
    do: {:ok, :not_paddle_managed}

  defp reconcile_unlocked_runner_quantity(%Subscription{} = subscription) do
    with {:ok, _account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(subscription.account_id),
         {:ok, subscription_data} <-
           PaddleClient.retrieve_subscription(subscription.paddle_subscription_id),
         {:ok, action} <- runner_quantity_action(subscription_data) do
      apply_runner_quantity_action(subscription, subscription_data, action)
    else
      {:error, :not_found} -> {:ok, :account_closed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runner_quantity_action(%{"status" => status} = subscription_data) do
    scheduled_change = subscription_data["scheduled_change"]
    scheduled_action = is_map(scheduled_change) && scheduled_change["action"]

    scheduled_effective_at =
      is_map(scheduled_change) && parse_optional_iso8601(scheduled_change["effective_at"])

    scheduled_final_period? =
      scheduled_action in ["cancel", "pause"] and
        match?(%DateTime{}, scheduled_effective_at) and
        DateTime.compare(scheduled_effective_at, DateTime.utc_now()) == :gt

    cond do
      status == "canceled" ->
        {:ok, :stop}

      status in ["past_due", "paused"] ->
        {:ok, :defer}

      status == "trialing" ->
        {:ok, {:update, "do_not_bill"}}

      status == "active" and scheduled_final_period? ->
        {:ok, {:update, "prorated_immediately"}}

      status == "active" and is_nil(scheduled_change) ->
        {:ok, {:update, "prorated_next_billing_period"}}

      true ->
        {:ok, :defer}
    end
  end

  defp runner_quantity_action(_subscription_data), do: {:error, :malformed_subscription}

  defp apply_runner_quantity_action(subscription, subscription_data, :stop) do
    persist_runner_quantity_convergence(subscription, subscription_data, subscription.quantity)
    |> then(fn
      {:ok, _subscription} -> {:ok, :stopped}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp apply_runner_quantity_action(subscription, _subscription_data, :defer) do
    request_deferred_runner_quantity_sync(subscription)
    {:ok, :deferred}
  end

  defp apply_runner_quantity_action(
         %Subscription{} = subscription,
         subscription_data,
         {:update, proration_mode}
       ) do
    desired_quantity = max(Runners.count_billable_runners(subscription.account_id), 1)

    with {:ok, items, _target_price_id, remote_quantity} <-
           runner_quantity_items(subscription_data, desired_quantity) do
      if remote_quantity == desired_quantity do
        persist_runner_quantity_convergence(subscription, subscription_data, desired_quantity)
        |> then(fn
          {:ok, _subscription} -> {:ok, :converged}
          {:error, reason} -> {:error, reason}
        end)
      else
        attrs = %{
          "items" => items,
          "proration_billing_mode" => proration_mode,
          "on_payment_failure" => "prevent_change"
        }

        with {:ok, updated} <-
               PaddleClient.update_subscription(subscription.paddle_subscription_id, attrs),
             :ok <- verify_runner_quantity_update(updated, items),
             {:ok, _subscription} <-
               persist_runner_quantity_convergence(subscription, updated, desired_quantity) do
          {:ok, :updated}
        end
      end
    end
  end

  defp request_deferred_runner_quantity_sync(subscription) do
    Subscription.Query.all()
    |> Subscription.Query.by_id(subscription.id)
    |> Subscription.Query.runner_quantity_sync_not_requested()
    |> Repo.update_all(set: [runner_quantity_sync_requested_at: DateTime.utc_now()])
  end

  defp persist_runner_quantity_convergence(subscription, subscription_data, quantity) do
    case extract_paddle_updated_at(subscription_data) do
      %DateTime{} = paddle_updated_at ->
        commit_runner_quantity_convergence(subscription, quantity, paddle_updated_at)

      nil ->
        {:error, :missing_subscription_updated_at}
    end
  end

  # The write goes to the row re-read under the lock, not the one this pass read
  # before calling Paddle. A webhook may have stored a NEWER `paddle_updated_at`
  # in between, which `Changeset.upsert/2` refuses to rewind — the row comes back
  # unchanged and the verification below reports a stale snapshot, leaving the
  # marker for the next tick.
  defp commit_runner_quantity_convergence(subscription, quantity, paddle_updated_at) do
    queryable = Subscription.Query.all() |> Subscription.Query.by_id(subscription.id)

    result =
      Repo.fetch_and_update(queryable, Subscription.Query,
        with: &converged_runner_quantity_changeset(&1, subscription, quantity, paddle_updated_at)
      )

    case result do
      {:ok, converged} ->
        verify_runner_quantity_convergence(converged, quantity, paddle_updated_at)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The outbox marker this pass read is still standing on the locked row, so
  # clear it: the work it asked for is exactly what just converged.
  defp converged_runner_quantity_changeset(
         %Subscription{runner_quantity_sync_requested_at: marker} = loaded_subscription,
         %Subscription{runner_quantity_sync_requested_at: marker},
         quantity,
         paddle_updated_at
       ) do
    Subscription.Changeset.upsert(loaded_subscription, %{
      quantity: quantity,
      paddle_updated_at: paddle_updated_at,
      runner_quantity_sync_requested_at: nil
    })
  end

  # A runner transition stamped a FRESH marker while this pass was out at
  # Paddle. Clearing it would lose that transition's quantity until the next
  # full sweep, so leave it standing for the next tick.
  defp converged_runner_quantity_changeset(
         %Subscription{} = loaded_subscription,
         %Subscription{},
         quantity,
         paddle_updated_at
       ) do
    Subscription.Changeset.upsert(loaded_subscription, %{
      quantity: quantity,
      paddle_updated_at: paddle_updated_at
    })
  end

  defp verify_runner_quantity_convergence(
         %Subscription{quantity: quantity, paddle_updated_at: paddle_updated_at} = subscription,
         quantity,
         paddle_updated_at
       ),
       do: {:ok, subscription}

  defp verify_runner_quantity_convergence(%Subscription{}, _quantity, _paddle_updated_at),
    do: {:error, :stale_subscription_snapshot}

  defp runner_quantity_items(%{"items" => items}, desired_quantity)
       when is_list(items) do
    with {:ok, normalized} <- normalize_subscription_items(items),
         {:ok, target_price_id, remote_quantity} <- select_runner_quantity_item(normalized) do
      patched =
        Enum.map(normalized, fn
          %{price_id: ^target_price_id} ->
            %{"price_id" => target_price_id, "quantity" => desired_quantity}

          %{price_id: price_id, quantity: quantity} ->
            %{"price_id" => price_id, "quantity" => quantity}
        end)

      {:ok, patched, target_price_id, remote_quantity}
    end
  end

  defp runner_quantity_items(_subscription_data, _desired_quantity),
    do: {:error, :malformed_subscription_items}

  defp normalize_subscription_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn
      %{
        "price" => %{"id" => price_id},
        "product" => product,
        "quantity" => quantity
      },
      {:ok, acc}
      when is_binary(price_id) and price_id != "" and is_map(product) and is_integer(quantity) and
             quantity > 0 ->
        item = %{
          price_id: price_id,
          quantity: quantity,
          plan: Entitlements.plan_identity_of_product(product)
        }

        {:cont, {:ok, [item | acc]}}

      _item, _acc ->
        {:halt, {:error, :malformed_subscription_items}}
    end)
    |> case do
      {:ok, []} ->
        {:error, :malformed_subscription_items}

      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)

        if unique_price_ids?(normalized) do
          {:ok, normalized}
        else
          {:error, :ambiguous_subscription_items}
        end

      error ->
        error
    end
  end

  defp select_runner_quantity_item(items) do
    case Enum.filter(items, &is_binary(&1.plan)) do
      [%{plan: "team", price_id: price_id, quantity: quantity}] ->
        {:ok, price_id, quantity}

      _ambiguous ->
        {:error, :ambiguous_subscription_items}
    end
  end

  defp verify_runner_quantity_update(subscription_data, requested_items) do
    with {:ok, normalized} <-
           normalize_subscription_items(Map.get(subscription_data, "items", [])),
         actual <- Map.new(normalized, &{&1.price_id, &1.quantity}),
         requested = Map.new(requested_items, &{&1["price_id"], &1["quantity"]}),
         true <- actual == requested do
      :ok
    else
      _mismatch -> {:error, :quantity_update_not_applied}
    end
  end

  defp unique_price_ids?(items) do
    items
    |> Enum.map(& &1.price_id)
    |> then(&(Enum.uniq(&1) == &1))
  end

  defp entitlement_snapshot(subscription) do
    posture = effective_plan(subscription)
    {scheduled_action, scheduled_at} = scheduled_change(subscription)

    %{
      plan: posture.plan_name,
      subscribed_plan: posture.stored_plan_name,
      entitlement_state: posture.entitlement_state,
      subscription_status: subscription && subscription.status,
      scheduled_change_action: scheduled_action,
      scheduled_change_effective_at: scheduled_at
    }
  end

  defp entitlement_change_audit(_account_id, snapshot, snapshot), do: nil

  defp entitlement_change_audit(account_id, old_snapshot, new_snapshot) do
    Audit.Events.subscription_changed(
      account_id,
      old_snapshot.plan,
      new_snapshot.plan,
      from_state: old_snapshot.entitlement_state,
      to_state: new_snapshot.entitlement_state,
      from_status: old_snapshot.subscription_status,
      to_status: new_snapshot.subscription_status,
      from_subscribed_plan: old_snapshot.subscribed_plan,
      to_subscribed_plan: new_snapshot.subscribed_plan,
      from_scheduled_change_action: old_snapshot.scheduled_change_action,
      to_scheduled_change_action: new_snapshot.scheduled_change_action,
      from_scheduled_change_effective_at: old_snapshot.scheduled_change_effective_at,
      to_scheduled_change_effective_at: new_snapshot.scheduled_change_effective_at
    )
  end

  @doc """
  Internal — returns :ok if the account is within plan limits for `resource`.
  Returns `{:error, :over_limit, plan, limit}` otherwise.

  Called by `Runners.register_via_enrollment_key/2` on the bootstrap path
  before any Subject exists, and by `Catalog`/admin flows that already
  authorized upstream. The check itself is account-scoped (the runner
  counting), not subject-scoped.
  """
  def check_limit(%Accounts.Account{} = account, resource) do
    posture =
      account.id
      |> subscription_for_account(lock?: Repo.in_transaction?())
      |> effective_plan()

    limit = entitled_limit(posture, limit_key(resource))
    current = current_count(account, resource)

    cond do
      limit == :unlimited -> :ok
      current < limit -> :ok
      true -> {:error, :over_limit, posture.plan_name, limit}
    end
  end

  defp limit_key(:runners), do: :runners_limit

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
  no product identifies as the plan or it has no active one-period price
  for the requested cycle.
  """
  def start_checkout(%Accounts.Account{} = account, plan_name, cycle, %Subject{} = subject)
      when is_binary(plan_name) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         :ok <- ensure_self_service_checkout(plan_name, cycle),
         :ok <- ensure_no_live_subscription(account.id) do
      with {:ok, price_id} <- resolve_checkout_price_id(plan_name, cycle),
           {:ok, customer_id, _account} <- ensure_paddle_customer(account, subject) do
        Checkouts.start(account.id, %{
          plan: :team,
          billing_interval: cycle,
          customer_id: customer_id,
          price_id: price_id,
          quantity: max(current_count(account, :runners), 1)
        })
      end
    end
  end

  defp ensure_self_service_checkout(plan_name, cycle) do
    cond do
      self_service_checkout?(plan_name, cycle) -> :ok
      plan_name == "team" -> {:error, :invalid_cycle}
      Map.has_key?(@plans, plan_name) -> {:error, :plan_not_self_service}
      true -> {:error, :unknown_plan}
    end
  end

  # Paddle enforces no one-subscription-per-customer rule, so a second checkout
  # mints a second transaction and bills BOTH — and the second
  # `subscription.created` overwrites `paddle_subscription_id`, losing the first
  # subscription's id, so we can no longer even see what to cancel. The console
  # only renders "Upgrade" when there is no live subscription, but that is a
  # RENDERING choice: a crafted `phx-click="upgrade"` reaches this function
  # directly. An existing subscriber cancels or keeps its own subscription on the
  # billing page and changes cadence through support.
  #
  # A canceled subscription is not live — the operator must be able to come back.
  defp ensure_no_live_subscription(account_id) do
    case peek_subscription_for_account(account_id) do
      %Subscription{paddle_subscription_id: id, status: status}
      when is_binary(id) and status != "canceled" ->
        {:error, :subscription_already_active}

      _ ->
        :ok
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
  defp product_plan_slug(product), do: Entitlements.plan_identity_of_product(product)

  # Select ONLY a one-period active price for the requested cycle. Falling back
  # to another cadence—or accepting "every 2 years" as annual—would change the
  # commercial contract rather than provide a catalog convenience.
  defp checkout_price_of_product(%{"prices" => prices}, cycle) when is_list(prices) do
    active = Enum.filter(prices, &(&1["status"] == "active"))

    requested =
      Enum.find(active, fn price ->
        get_in(price, ["billing_cycle", "interval"]) == cycle_interval(cycle) and
          get_in(price, ["billing_cycle", "frequency"]) == 1
      end)

    case requested do
      %{"id" => price_id} -> {:ok, price_id}
      _ -> {:error, :plan_not_in_catalog}
    end
  end

  defp checkout_price_of_product(_product, _cycle), do: {:error, :plan_not_in_catalog}

  defp cycle_interval(:month), do: "month"
  defp cycle_interval(:year), do: "year"

  # -- This workspace's own subscription ------------------------------------
  #
  # Every control here acts on the one Paddle subscription the local mirror holds
  # for the account, never on its customer. One customer can pay for several
  # workspaces and Paddle's portal sessions are customer-wide, so Emisar opens
  # none: the payer manages customer details through the link in any Paddle
  # receipt.

  @collected_statuses ~w[active trialing past_due]
  # Paddle refuses every change to a past-due subscription, so cancelling or
  # keeping one waits until its renewal is paid.
  @changeable_statuses ~w[active trialing]

  @doc """
  The URL where a billing manager replaces the payment method on this
  workspace's own subscription: a Paddle transaction for that subscription (the
  unpaid renewal when it is past due), opened on Emisar's checkout page.
  Requires `manage_billing`. Returns `{:ok, url}`, or `{:error,
  :no_subscription}` without an automatically collected Paddle subscription.
  """
  def payment_method_update_url(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id),
         {:ok, subscription} <- fetch_collected_subscription(account.id),
         {:ok, _data} <- fetch_owned_subscription_data(subscription, account, @collected_statuses),
         {:ok, transaction} <-
           PaddleClient.payment_method_transaction(subscription.paddle_subscription_id),
         :ok <- ensure_owned_transaction(transaction, subscription, account) do
      Checkouts.provider_checkout_url(transaction, account.id)
    end
  end

  @doc """
  Schedules this workspace's own subscription to end with its paid period.
  Paid features stay until then; `keep_subscription/2` withdraws it. The request
  is audited before Paddle is asked, and `subscription.changed` records what
  took effect. Requires `manage_billing`. Returns `:ok`, or `{:error,
  :no_subscription}` when there is no collected subscription, it is past due,
  or it already ends.
  """
  def cancel_subscription(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id),
         {:ok, %Subscription{scheduled_change_action: nil, status: status} = subscription}
         when status in @changeable_statuses <- fetch_collected_subscription(account.id),
         {:ok, %{"scheduled_change" => nil}} <-
           fetch_owned_subscription_data(subscription, account, @changeable_statuses),
         {:ok, _requested} <-
           Audit.record(Audit.Events.subscription_cancel_requested(subject, account)),
         {:ok, data} <-
           PaddleClient.schedule_subscription_cancel(subscription.paddle_subscription_id),
         :ok <- ensure_owned_change(data, subscription, account, &(&1["action"] == "cancel")) do
      mirror_subscription_change(data, subscription)
    else
      {:ok, %{}} -> {:error, :no_subscription}
      other -> other
    end
  end

  @doc """
  Withdraws the scheduled cancellation of this workspace's own subscription, so
  it renews as before. Audited before Paddle is asked, like
  `cancel_subscription/2`. Requires `manage_billing`. Returns `:ok`, or
  `{:error, :no_subscription}` when no cancellation is scheduled or it is past
  due.
  """
  def keep_subscription(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id),
         {:ok, %Subscription{scheduled_change_action: "cancel", status: status} = subscription}
         when status in @changeable_statuses <- fetch_collected_subscription(account.id),
         {:ok, %{"scheduled_change" => %{"action" => "cancel"}}} <-
           fetch_owned_subscription_data(subscription, account, @changeable_statuses),
         {:ok, _requested} <-
           Audit.record(Audit.Events.subscription_keep_requested(subject, account)),
         {:ok, data} <-
           PaddleClient.update_subscription(subscription.paddle_subscription_id, %{
             "scheduled_change" => nil
           }),
         :ok <- ensure_owned_change(data, subscription, account, &is_nil/1) do
      mirror_subscription_change(data, subscription)
    else
      {:ok, %{}} -> {:error, :no_subscription}
      other -> other
    end
  end

  defp ensure_can_manage_billing(%Subject{} = subject, %Accounts.Account{} = account) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_billing_permission()
           ) do
      Subject.ensure_in_account(subject, account.id, :unauthorized)
    end
  end

  defp fetch_collected_subscription(account_id) do
    subscription = peek_subscription_for_account(account_id)

    if collected_subscription?(subscription),
      do: {:ok, subscription},
      else: {:error, :no_subscription}
  end

  # Paddle collects this subscription itself, so its card and cancellation are
  # the workspace's to manage; manually invoiced ones go through support.
  defp collected_subscription?(%Subscription{
         paddle_subscription_id: id,
         collection_mode: "automatic",
         status: status
       })
       when is_binary(id) and status in @collected_statuses,
       do: true

  defp collected_subscription?(_subscription), do: false

  # The mirror only names the subscription. Before any change Paddle has to
  # confirm it is still this workspace customer's automatically collected one,
  # so a stale or wrong mirror row cannot reach another payer's subscription.
  defp fetch_owned_subscription_data(subscription, account, statuses) do
    case PaddleClient.retrieve_subscription(subscription.paddle_subscription_id) do
      {:ok, %{"collection_mode" => "automatic", "status" => status} = data} ->
        if status in statuses and owned_subscription_data?(data, subscription, account),
          do: {:ok, data},
          else: {:error, :no_subscription}

      {:ok, _data} ->
        {:error, :no_subscription}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owned_subscription_data?(data, %Subscription{} = subscription, account) do
    is_binary(account.paddle_customer_id) and
      data["id"] == subscription.paddle_subscription_id and
      data["customer_id"] == account.paddle_customer_id
  end

  # Paddle answers a change with the whole subscription: it must be the same
  # one, still this customer's and still collected, with the requested
  # scheduled change in place.
  defp ensure_owned_change(data, subscription, account, scheduled_change_ok?) do
    if owned_subscription_data?(data, subscription, account) and
         data["collection_mode"] == "automatic" and data["status"] in @changeable_statuses and
         scheduled_change_ok?.(data["scheduled_change"]),
       do: :ok,
       else: {:error, :change_not_confirmed}
  end

  defp ensure_owned_transaction(transaction, %Subscription{} = subscription, account) do
    if is_binary(account.paddle_customer_id) and
         transaction["subscription_id"] == subscription.paddle_subscription_id and
         transaction["customer_id"] == account.paddle_customer_id,
       do: :ok,
       else: {:error, :invalid_provider_data}
  end

  # Paddle already applied the change, so the caller succeeds whatever happens
  # here; a mirror that lost a race with a webhook converges on the next one.
  defp mirror_subscription_change(data, %Subscription{} = subscription) do
    case reconcile_subscription_data(data, expected_subscription: subscription) do
      {:error, reason} ->
        Logger.warning("billing.subscription_mirror_deferred",
          account_id: subscription.account_id,
          error: inspect(redacted_paddle_error(reason))
        )

        :ok

      _mirrored ->
        :ok
    end
  end

  @doc """
  Recent invoices (Paddle transactions) for the account's customer — number,
  date, amount, status — so the billing page shows this subscription's payment
  history inline (Paddle's receipt emails reach the payer's full ledger).
  `{:ok, []}` for an account that's never been billed (no `paddle_customer_id`).
  Gated on `view_invoices`, not view-billing: an invoice is a financial document
  naming what the company paid and when, which owners, admins and the billing
  manager read and an operator does not — the plan name, limits and usage every
  role needs live on `billing_summary/2`. Returns `{:ok, [invoice_map]}`.
  """
  def list_recent_invoices(%Accounts.Account{} = account, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_invoices_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id) do
      do_list_recent_invoices(account, opts)
    end
  end

  @doc """
  The signed, short-lived URL of one transaction's invoice PDF, so a billing
  manager can download an invoice inline. Gated on
  `view_invoices`, like the list it is reached from; the transaction is
  re-checked against the account's own recent invoices first, so a crafted id
  can't pull another account's PDF — `{:error, :not_found}` otherwise.
  """
  def invoice_pdf_url(%Accounts.Account{} = account, transaction_id, %Subject{} = subject)
      when is_binary(transaction_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_invoices_permission()),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id),
         {:ok, invoices} <- do_list_recent_invoices(account, limit: 24),
         true <- Enum.any?(invoices, &(&1.id == transaction_id)) do
      Emisar.Billing.PaddleClient.get_transaction_invoice(transaction_id)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp do_list_recent_invoices(%Accounts.Account{paddle_customer_id: nil}, _opts), do: {:ok, []}

  defp do_list_recent_invoices(
         %Accounts.Account{paddle_customer_id: customer_id, id: account_id},
         opts
       )
       when is_binary(customer_id) do
    limit = Keyword.get(opts, :limit, 6)

    # Several workspaces can share a Paddle customer (a proved link to an
    # existing customer), so a customer-scoped ledger would let a billing
    # manager of one read the other's invoices. Scope to THIS account's own
    # subscription; no subscription id means no invoices to show.
    case peek_subscription_for_account(account_id) do
      %Subscription{paddle_subscription_id: subscription_id} when is_binary(subscription_id) ->
        case Emisar.Billing.PaddleClient.list_transactions(%{
               customer: customer_id,
               subscription_id: subscription_id,
               limit: limit
             }) do
          {:ok, txns} -> {:ok, Enum.map(txns, &to_invoice/1)}
          {:error, reason} -> {:error, reason}
        end

      _no_subscription ->
        {:ok, []}
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

  # nil, not 0, for anything that isn't a whole minor-unit amount. `Integer.parse`
  # stops at the first non-digit, so "20.00" came back as 20 (twenty CENTS) and
  # anything unparseable became 0 — a real invoice rendered as "$0.00", which
  # reads as a fact about the charge rather than as a failure to read it.
  defp parse_invoice_amount(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_invoice_amount(_), do: nil

  defp parse_invoice_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_invoice_datetime(_), do: nil

  @doc """
  Ensures the account has a Paddle customer. Requires `manage` on billing and
  the subject's account. Returns `{:ok, customer_id, account}`.

  A new customer is created with the billing contact's email. When Paddle
  already has a customer for that email the account is NOT linked to it
  (`{:error, :billing_email_in_use}`): that customer may pay for other
  workspaces and the email is an unproved workspace contact, so linking takes
  the mailbox proof of `send_customer_link_code/2`. An existing link is kept as
  it is, and Emisar never rewrites the customer's own details.
  """
  def ensure_paddle_customer(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account),
         {:ok, %{account: account, owner: owner}} <- Accounts.fetch_billing_contact(account.id) do
      case account.paddle_customer_id do
        customer_id when is_binary(customer_id) -> {:ok, customer_id, account}
        nil -> create_paddle_customer(account, owner)
      end
    end
  end

  defp create_paddle_customer(account, owner) do
    attrs = %{email: owner.contact_email, name: account.name, account_id: account.id}

    case PaddleClient.create_customer(attrs) do
      {:ok, %{"id" => customer_id}} when is_binary(customer_id) ->
        with {:ok, linked} <- Accounts.link_account_paddle_customer(account, customer_id),
             do: {:ok, linked.paddle_customer_id, linked}

      {:ok, _data} ->
        {:error, :missing_customer_id}

      {:error, {:http, 409, body}} = conflict ->
        if paddle_error_code(body) == "customer_already_exists",
          do: linked_by_concurrent_checkout(account),
          else: conflict

      other ->
        other
    end
  end

  # A concurrent first checkout of this same account may have created the
  # customer a moment ago; any other owner of the email needs the mailbox proof.
  defp linked_by_concurrent_checkout(account) do
    case Accounts.fetch_account_by_id(account.id) do
      {:ok, %Accounts.Account{paddle_customer_id: customer_id} = linked}
      when is_binary(customer_id) ->
        {:ok, customer_id, linked}

      _unlinked ->
        {:error, :billing_email_in_use}
    end
  end

  @link_code_ttl_seconds 15 * 60
  @link_code_attempts 5
  @link_code_send_limit 5
  @link_code_send_window_ms 60 * 60 * 1000
  @link_code_verify_limit 20
  @link_code_verify_window_ms 15 * 60 * 1000

  @doc """
  Emails a code to the billing contact's address so that the Paddle customer it
  already has can be linked with `link_existing_customer/3`. Only for an account
  with no Paddle customer whose billing email Paddle already knows. Requires
  `manage_billing`. Returns `{:ok, email}` with the address the code went to,
  or `{:error, :already_linked | :no_existing_customer | :rate_limited}`.
  """
  def send_customer_link_code(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account),
         {:ok, %{account: account, owner: owner}} <- Accounts.fetch_billing_contact(account.id),
         :ok <- ensure_unlinked(account),
         :ok <-
           Throttle.check(
             :billing_customer_link_code,
             account.id,
             @link_code_send_limit,
             @link_code_send_window_ms
           ),
         # Per address too: many workspaces cannot pool guesses against one payer.
         :ok <-
           Throttle.check(
             :billing_customer_link_code_email,
             String.downcase(owner.contact_email),
             @link_code_send_limit,
             @link_code_send_window_ms
           ),
         {:ok, _customer_id} <- fetch_existing_customer_id(owner.contact_email),
         {code, digest} = Crypto.credential_step_up_code(),
         {:ok, _pending} <- issue_link_code(account, subject, owner.contact_email, digest) do
      _ =
        Audit.record(
          Audit.Events.billing_customer_link_requested(subject, account, owner.contact_email)
        )

      case Mailers.UserNotifier.deliver_billing_customer_link_code(
             owner,
             code,
             account,
             subject.context
           ) do
        {:ok, _sent} -> {:ok, owner.contact_email}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Links this workspace to the existing Paddle customer of its billing email once
  the code `send_customer_link_code/2` emailed there is entered. The Member who
  asked must enter it, the billing email must be unchanged, and the account must
  still have no customer; all three are rechecked under the account and contact
  locks that commit the link and its audit together. Requires `manage_billing`.
  Returns `{:ok, account}`, or `{:error, :invalid_code | :already_linked |
  :no_existing_customer | :archived_customer | :rate_limited}`.
  """
  def link_existing_customer(%Accounts.Account{} = account, code, %Subject{} = subject)
      when is_binary(code) do
    code = String.trim(code)

    with :ok <- ensure_can_manage_billing(subject, account),
         :ok <- ensure_link_code_shape(code),
         :ok <-
           Throttle.check(
             :billing_customer_link_verify,
             account.id,
             @link_code_verify_limit,
             @link_code_verify_window_ms
           ),
         {:ok, %{account: current, owner: owner}} <- Accounts.fetch_billing_contact(account.id),
         :ok <- ensure_unlinked(current),
         {:ok, customer_id} <- fetch_existing_customer_id(owner.contact_email) do
      commit_customer_link(current, owner, customer_id, code, subject)
    end
  end

  def link_existing_customer(%Accounts.Account{} = account, _code, %Subject{} = subject) do
    with :ok <- ensure_can_manage_billing(subject, account), do: {:error, :invalid_code}
  end

  defp ensure_link_code_shape(code) do
    if Regex.match?(~r/\A[0-9]{6}\z/, code), do: :ok, else: {:error, :invalid_code}
  end

  # One transaction: the account and the billing contact are locked, then the
  # proof is checked against what they say now. A spent attempt, the link, and
  # the audit row all commit or none do.
  defp commit_customer_link(account, owner, customer_id, code, subject) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account.id, repo: repo)
    end)
    # The actor's billing authority and the billing contact are read again
    # under the account lock: a demotion or a new contact during the Paddle
    # lookup refuses the link.
    |> Multi.run(:authority, fn _repo, _changes ->
      case ensure_can_manage_billing(subject, account) do
        :ok -> {:ok, :manage_billing}
        error -> error
      end
    end)
    |> Multi.run(:contact, fn repo, %{account: locked} ->
      with :ok <- ensure_unlinked(locked),
           {:ok, %{owner: %{id: owner_id}}} when owner_id == owner.id <-
             Accounts.fetch_billing_contact(locked.id),
           {:ok, %{role: :owner} = contact} <-
             Accounts.fetch_and_lock_membership(locked.id, owner.id, repo: repo) do
        {:ok, contact}
      else
        {:ok, _other_contact} -> {:error, :invalid_code}
        error -> error
      end
    end)
    # The customer was looked up by the address read before the lock, so the
    # locked contact, the proof, and that lookup must all name the same one.
    |> Multi.run(:proof, fn repo, %{contact: contact} ->
      pending =
        CustomerLinkCode.Query.by_account_id(account.id)
        |> CustomerLinkCode.Query.lock_for_update()
        |> repo.one()

      if contact.contact_email == owner.contact_email,
        do: verify_link_code(pending, repo, subject, owner.contact_email, code),
        else: {:ok, {:error, :invalid_code}}
    end)
    |> Multi.run(:linked, fn _repo, %{account: locked, proof: proof} ->
      case proof do
        {:ok, _email} -> Accounts.link_account_paddle_customer(locked, customer_id)
        {:error, :invalid_code} -> {:ok, :not_linked}
      end
    end)
    |> Multi.run(:audit, fn repo, %{linked: linked, contact: contact} ->
      case linked do
        %Accounts.Account{} ->
          repo.insert(
            Audit.Events.billing_customer_linked(subject, linked, contact.contact_email)
          )

        :not_linked ->
          repo.insert(Audit.Events.billing_customer_link_failed(subject, account))
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{linked: %Accounts.Account{} = linked}} -> {:ok, linked}
      {:ok, %{linked: :not_linked}} -> {:error, :invalid_code}
      {:error, :not_found} -> {:error, :invalid_code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_unlinked(%Accounts.Account{paddle_customer_id: nil}), do: :ok
  defp ensure_unlinked(%Accounts.Account{}), do: {:error, :already_linked}

  # Paddle keeps emails unique across a seller's customers, archived ones
  # included, so a known email resolves to exactly one. Only an active customer
  # with that exact address can bill; an archived one needs support.
  defp fetch_existing_customer_id(email) do
    case PaddleClient.list_customers(%{email: email}) do
      {:ok, [%{"id" => customer_id, "email" => customer_email} = customer]}
      when is_binary(customer_id) and is_binary(customer_email) ->
        cond do
          String.downcase(customer_email) != String.downcase(email) ->
            {:error, :no_existing_customer}

          customer["status"] == "active" ->
            {:ok, customer_id}

          true ->
            {:error, :archived_customer}
        end

      {:ok, _customers} ->
        {:error, :no_existing_customer}

      other ->
        other
    end
  end

  defp issue_link_code(account, subject, email, digest) do
    %{
      account_id: account.id,
      membership_id: Subject.human_membership_id(subject),
      email: email,
      code_digest: digest,
      remaining_attempts: @link_code_attempts,
      expires_at: DateTime.add(DateTime.utc_now(), @link_code_ttl_seconds, :second)
    }
    |> CustomerLinkCode.Changeset.issue()
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :account_id)
  end

  defp verify_link_code(nil, _repo, _subject, _email, _code), do: {:ok, {:error, :invalid_code}}

  defp verify_link_code(%CustomerLinkCode{} = pending, repo, subject, email, code) do
    cond do
      pending.remaining_attempts < 1 or
        DateTime.compare(pending.expires_at, DateTime.utc_now()) != :gt or
        pending.membership_id != Subject.human_membership_id(subject) or
          pending.email != email ->
        {:ok, {:error, :invalid_code}}

      Crypto.secure_compare(Crypto.hash(code), pending.code_digest) ->
        {:ok, _deleted} = repo.delete(pending)
        {:ok, {:ok, pending.email}}

      true ->
        {:ok, _spent} = repo.update(CustomerLinkCode.Changeset.spend_attempt(pending))
        {:ok, {:error, :invalid_code}}
    end
  end

  @doc """
  Internal — collapses a Paddle client / mirror-write failure into a loggable
  term that carries no payload values, so every Paddle-error log line in this
  context (customer creation + the hourly subscription reconciliation) shares one
  scrub. An HTTP failure keeps only its status (never the response body); an
  upsert changeset keeps only its failing field names (never `.changes`, which
  echo mirrored subscription values); any other reason passes through.
  """
  def redacted_paddle_error({:http, status, body}) do
    case paddle_error_code(body) do
      nil -> {:http, status}
      code -> {:http, status, code}
    end
  end

  def redacted_paddle_error(%Ecto.Changeset{errors: errors}) do
    {:invalid_changeset, errors |> Keyword.keys() |> Enum.uniq()}
  end

  def redacted_paddle_error(reason), do: reason

  # Paddle's error envelope carries a stable machine code —
  # `{"error": {"code": "customer_already_exists", ...}}` — which names WHICH
  # conflict occurred and contains no payload values, unlike `detail`, which
  # quotes the offending field back. Keeping just the code is what makes a
  # repeating 409 diagnosable: the status alone says a conflict happened, and
  # every conflict Paddle has looks identical in the log.
  #
  # Bounded and shape-checked because it is a remote value: anything that is not
  # a short snake_case token is dropped rather than logged.
  defp paddle_error_code(body) when is_binary(body) do
    with {:ok, %{"error" => %{"code" => code}}} <- Jason.decode(body),
         true <- is_binary(code) and byte_size(code) <= 64,
         true <- Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, code) do
      code
    else
      _ -> nil
    end
  end

  defp paddle_error_code(_body), do: nil

  @doc """
  Internal — the unauthenticated Paddle webhook ingress. `payload` is the RAW
  request body and `signature` the request's `paddle-signature` header; both
  are attacker-controlled. There is no Subject here because the CONFIGURED
  client's signature verification against `:paddle_webhook_secret` IS the auth
  gate — nothing in the payload is trusted until it verifies. Not exposed to
  LiveView/MCP.

  Returns:

    * `{:error, :billing_disabled}` — no webhook secret configured (the
      EMISAR_DISABLE_BILLING deployment); the client is never called,
    * `{:error, {:verification_failed, reason}}` — the signature or the
      payload decoding was rejected, so a caller can tell a hostile delivery
      from a post-verification failure,
    * `{:error, :malformed_event}` — verified, but carrying no binary
      `event_id`/`event_type`,
    * otherwise the `record_and_apply_event/3` outcome: `:ok`,
      `{:duplicate, event_id}`, or `{:error, reason}`.
  """
  def ingest_paddle_webhook(payload, signature)
      when is_binary(payload) and is_binary(signature) do
    with {:ok, secret} <- fetch_webhook_secret(),
         {:ok, event} <- verify_webhook_event(payload, signature, secret) do
      record_verified_event(event)
    end
  end

  defp fetch_webhook_secret do
    case Emisar.Config.get_env(:emisar, :paddle_webhook_secret) do
      nil -> {:error, :billing_disabled}
      secret -> {:ok, secret}
    end
  end

  defp verify_webhook_event(payload, signature, secret) do
    case PaddleClient.construct_webhook_event(payload, signature, secret) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:verification_failed, reason}}
    end
  end

  defp record_verified_event(%{"event_id" => event_id, "event_type" => event_type} = event)
       when is_binary(event_id) and is_binary(event_type),
       do: record_and_apply_event(event_id, event_type, event)

  defp record_verified_event(_event), do: {:error, :malformed_event}

  @doc """
  Internal — records and applies one already-VERIFIED Paddle event; the
  signature gate lives in `ingest_paddle_webhook/2`, so there's no Subject
  here. Not exposed to LiveView/MCP.

  Atomically:

    * inserts the Paddle event id into `paddle_processed_events` (unique
      primary key); if the row already exists, returns
      `{:duplicate, existing}` and does NOT re-apply,
    * commits the prepared account-scoped transition in that same transaction.
      Provider proof is fetched before the transaction; the captured mirror
      version and account identity are checked again under its row locks.
  """
  def record_and_apply_event(event_id, event_type, event)
      when is_binary(event_id) and is_binary(event_type) do
    recorded? = event_id |> List.wrap() |> ProcessedEvent.Query.by_ids() |> Repo.exists?()

    if recorded? do
      Emisar.Telemetry.billing_webhook(:duplicate)
      {:duplicate, event_id}
    else
      case prepare_webhook_event(event) do
        {:ok, prepared} ->
          commit_prepared_event(event_id, event_type, prepared)

        {:error, reason} ->
          Emisar.Telemetry.billing_webhook(:failed)
          {:error, {:apply_failed, reason}}
      end
    end
  end

  defp commit_prepared_event(event_id, event_type, prepared) do
    row = %{id: event_id, event_type: event_type, received_at: DateTime.utc_now()}

    Multi.new()
    # Dedup insert into the schemaless bookkeeping table. `on_conflict:
    # :nothing` → 0 rows means this Paddle event id was already processed
    # (Paddle re-delivers); 1 row means it's new. A duplicate aborts the
    # whole transaction so the side effects below never re-run.
    |> Multi.run(:dedup, fn repo, _changes ->
      case repo.insert_all("paddle_processed_events", [row], on_conflict: :nothing) do
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
      case apply_prepared_write(prepared) do
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

  @subscription_lifecycle_events ~w[
    subscription.activated
    subscription.canceled
    subscription.cancellation_scheduled
    subscription.created
    subscription.past_due
    subscription.pause_scheduled
    subscription.paused
    subscription.resumed
    subscription.resumption_scheduled
    subscription.trialing
    subscription.updated
  ]

  defp prepare_webhook_event(%{"event_type" => event_type, "data" => subscription_data} = event)
       when event_type in @subscription_lifecycle_events and is_map(subscription_data) do
    subscription_data =
      if event_type == "subscription.canceled" do
        subscription_data
        |> Map.put_new("status", "canceled")
        |> Map.put_new("scheduled_change", nil)
      else
        subscription_data
      end

    case subscription_data do
      %{"id" => id, "status" => status} when is_binary(id) and is_binary(status) ->
        prepare_subscription_write(subscription_data, extract_event_occurred_at(event),
          source: :webhook,
          transaction_id: subscription_data["transaction_id"]
        )

      _ ->
        {:error, :malformed_subscription}
    end
  end

  defp prepare_webhook_event(%{"event_type" => type}) when type in @subscription_lifecycle_events,
    do: {:error, :malformed_subscription}

  defp prepare_webhook_event(_event), do: {:ok, :ignored}

  @doc false
  def reconcile_subscription_data(subscription_data, opts \\ [])

  def reconcile_subscription_data(
        %{"id" => id, "status" => status} = subscription_data,
        opts
      )
      when is_binary(id) and is_binary(status) do
    expected =
      case Keyword.get(opts, :expected_subscription, :current) do
        :current -> mirror_version(peek_subscription_by_paddle_id(id))
        :missing -> nil
        %Subscription{} = subscription -> mirror_version(subscription)
      end

    upsert_from_subscription(subscription_data, nil,
      expected_mirror: expected,
      source: :reconciliation
    )
  end

  def reconcile_subscription_data(_subscription_data, _opts),
    do: {:error, :malformed_subscription}

  @doc false
  def reconcile_discovered_subscription_data(%{"id" => id} = subscription_data)
      when is_binary(id) do
    case peek_subscription_by_paddle_id(id) do
      %Subscription{} ->
        :ok

      nil ->
        reconcile_unseen_subscription(subscription_data)
    end
  end

  def reconcile_discovered_subscription_data(_subscription_data),
    do: {:error, :malformed_subscription}

  defp reconcile_unseen_subscription(subscription_data),
    do: upsert_from_subscription(subscription_data, nil, source: :reconciliation)

  defp upsert_from_subscription(data, event_occurred_at, opts) do
    with {:ok, prepared} <- prepare_subscription_write(data, event_occurred_at, opts),
         do: apply_prepared_write(prepared)
  end

  defp prepare_subscription_write(data, event_occurred_at, opts) do
    case SubscriptionRetirements.find(data["id"]) do
      nil ->
        case peek_subscription_by_paddle_id(data["id"]) do
          %Subscription{} = existing ->
            with :ok <- ensure_expected_mirror(existing, opts) do
              {:ok,
               {:known, existing.account_id, data, event_occurred_at, mirror_version(existing)}}
            end

          nil ->
            prepare_first_seen_subscription(data, event_occurred_at, opts)
        end

      retirement ->
        {:ok, {:retired, retirement}}
    end
  end

  defp prepare_first_seen_subscription(data, event_occurred_at, opts) do
    case subscription_candidate(data, opts) do
      {:ok, candidate} ->
        data = if candidate.proof, do: candidate.proof.subscription, else: data

        with :ok <-
               ensure_expected_mirror(peek_subscription_for_account(candidate.account_id), opts),
             {:ok, canonical} <- refresh_candidate_canonical(candidate, data) do
          {:ok, {:first_seen, candidate, canonical, data, event_occurred_at}}
        end

      {:error, :not_found} ->
        {:ok, :ignored}

      error ->
        error
    end
  end

  defp apply_prepared_write(:ignored), do: :ok
  defp apply_prepared_write({:retired, retirement}), do: {:ok, retirement}

  defp apply_prepared_write({:known, account_id, data, event_occurred_at, expected}) do
    mirror_subscription_for_account(account_id, data,
      event_occurred_at: event_occurred_at,
      expected_mirror: expected
    )
  end

  defp apply_prepared_write({:first_seen, candidate, canonical, data, event_occurred_at}),
    do: commit_candidate(candidate, canonical, data, event_occurred_at)

  defp subscription_candidate(data, opts) do
    case subscription_binding(data) do
      nil ->
        case Accounts.resolve_paddle_subscription_account(data["customer_id"]) do
          {:ok, account} ->
            {:ok,
             %{
               account_id: account.id,
               customer_id: data["customer_id"],
               account: account,
               proof: nil
             }}

          {:error, :ambiguous} ->
            {:error, :ambiguous_paddle_customer}

          error ->
            error
        end

      token when is_binary(token) ->
        with {:ok, proof} <- SubscriptionRetirements.verify_candidate(data, opts) do
          account =
            case Accounts.resolve_paddle_subscription_account(proof.customer_id, proof.account_id) do
              {:ok, account} -> account
              {:error, :not_found} -> nil
            end

          {:ok,
           %{
             account_id: proof.account_id,
             customer_id: proof.customer_id,
             account: account,
             proof: proof
           }}
        end

      _invalid ->
        {:error, :invalid_subscription_account_binding}
    end
  end

  defp subscription_binding(%{"custom_data" => custom_data}) when is_map(custom_data),
    do: custom_data["emisar_account_binding"]

  defp subscription_binding(%{"custom_data" => nil}), do: nil
  defp subscription_binding(%{"custom_data" => _invalid}), do: :invalid
  defp subscription_binding(_data), do: nil

  defp refresh_candidate_canonical(candidate, data) do
    canonical = peek_subscription_for_account(candidate.account_id)
    candidate_id = data["id"]
    closed? = is_nil(candidate.account) or not is_nil(candidate.account.deleted_at)

    case canonical do
      %Subscription{paddle_subscription_id: id, status: status}
      when not closed? and is_binary(id) and id != candidate_id and status != "canceled" ->
        with {:ok, %{"id" => ^id, "customer_id" => customer, "status" => status} = remote} <-
               PaddleClient.retrieve_subscription(id),
             true <-
               customer == candidate.customer_id and
                 status in ~w[active trialing past_due paused canceled],
             {:ok, %Subscription{} = refreshed} <-
               reconcile_subscription_data(remote, expected_subscription: canonical) do
          {:ok, refreshed}
        else
          {:error, reason} -> {:error, reason}
          _invalid -> {:error, :invalid_canonical_subscription}
        end

      _missing_or_terminal ->
        {:ok, canonical}
    end
  end

  defp commit_candidate(candidate, canonical, data, event_occurred_at) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(candidate.account_id,
             repo: repo,
             include_deleted?: true
           ) do
        {:ok, account} when account.paddle_customer_id == candidate.customer_id -> {:ok, account}
        {:ok, _wrong_customer} -> {:error, :invalid_subscription_account_binding}
        {:error, :not_found} when not is_nil(candidate.proof) -> {:ok, nil}
        error -> error
      end
    end)
    |> Multi.run(:disposition, fn repo, %{account: account} ->
      current = subscription_for_account(candidate.account_id, repo: repo, lock?: true)

      with :ok <- ensure_expected_mirror(current, expected_mirror: mirror_version(canonical)) do
        case SubscriptionRetirements.find(data["id"], repo: repo) do
          nil -> candidate_disposition(repo, account, current, candidate, data, event_occurred_at)
          retirement -> {:ok, retirement}
        end
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{disposition: disposition}} -> {:ok, disposition}
      error -> error
    end
  end

  defp candidate_disposition(repo, account, current, candidate, data, event_occurred_at) do
    candidate_id = data["id"]

    reason =
      cond do
        is_nil(account) ->
          :account_erased

        not is_nil(account.deleted_at) ->
          :account_closed

        match?(
          %Subscription{paddle_subscription_id: id, status: status}
          when is_binary(id) and id != candidate_id and status != "canceled",
          current
        ) ->
          :duplicate

        true ->
          nil
      end

    case {reason, candidate.proof} do
      {nil, _proof} ->
        mirror_subscription_for_account(candidate.account_id, data,
          event_occurred_at: event_occurred_at,
          expected_mirror: mirror_version(current),
          reject_deleted?: true
        )

      {_reason, nil} ->
        {:error, :invalid_subscription_account_binding}

      {reason, proof} ->
        SubscriptionRetirements.enqueue(proof, reason, current && current.paddle_subscription_id,
          repo: repo
        )
    end
  end

  defp mirror_subscription_for_account(account_id, subscription_data, opts) do
    existing = peek_subscription_for_account(account_id)

    replacement? =
      not is_nil(existing) and existing.paddle_subscription_id != subscription_data["id"]

    plan =
      Entitlements.plan_slug(subscription_data) ||
        Entitlements.known_plan_from_name(Entitlements.product_name(subscription_data)) ||
        if(not replacement?, do: stored_plan_from_subscription(existing))

    attrs =
      subscription_mirror_attrs(subscription_data,
        event_occurred_at: Keyword.get(opts, :event_occurred_at)
      )
      |> Map.put(:plan, plan)

    upsert_opts =
      case Keyword.get(opts, :expected_mirror, :unchecked) do
        :unchecked -> []
        expected -> [expected_mirror: expected]
      end

    upsert_opts =
      if Keyword.get(opts, :reject_deleted?, false),
        do: Keyword.put(upsert_opts, :reject_deleted?, true),
        else: upsert_opts

    upsert_opts = Keyword.put(upsert_opts, :replace_provider?, replacement?)
    upsert_subscription(account_id, attrs, upsert_opts)
  end

  @doc false
  def subscription_mirror_attrs(subscription_data, opts \\ []) when is_map(subscription_data) do
    %{}
    |> put_present(:paddle_subscription_id, present_binary(subscription_data["id"]))
    |> put_present(:status, present_binary(subscription_data["status"]))
    |> put_present(:collection_mode, present_binary(subscription_data["collection_mode"]))
    |> Map.merge(subscription_item_attrs(subscription_data))
    |> put_present(:entitlements, Entitlements.from_paddle_subscription(subscription_data))
    |> put_present(:current_period_end, extract_next_billed_at(subscription_data))
    |> put_present(:current_period_start, extract_current_period_start(subscription_data))
    |> put_present(:paddle_updated_at, extract_paddle_updated_at(subscription_data))
    |> put_present(:paddle_event_occurred_at, Keyword.get(opts, :event_occurred_at))
    |> put_scheduled_change(subscription_data)
    |> request_ambiguous_runner_quantity_sync(subscription_data)
    |> clear_canceled_runner_quantity_sync(subscription_data)
  end

  defp clear_canceled_runner_quantity_sync(attrs, %{"status" => "canceled"}),
    do: Map.put(attrs, :runner_quantity_sync_requested_at, nil)

  defp clear_canceled_runner_quantity_sync(attrs, _subscription_data), do: attrs

  defp request_ambiguous_runner_quantity_sync(attrs, %{"items" => items} = subscription_data)
       when is_list(items) do
    status = subscription_data["status"]

    if is_nil(Entitlements.plan_item(subscription_data)) and status not in ["canceled", "paused"] do
      Map.put(attrs, :runner_quantity_sync_requested_at, DateTime.utc_now())
    else
      attrs
    end
  end

  defp request_ambiguous_runner_quantity_sync(attrs, _subscription_data), do: attrs

  defp put_scheduled_change(attrs, subscription_data) do
    if Map.has_key?(subscription_data, "scheduled_change") do
      scheduled_change = map_or_empty(subscription_data["scheduled_change"])
      action = present_binary(scheduled_change["action"])
      effective_at = parse_optional_iso8601(scheduled_change["effective_at"])

      attrs
      |> Map.put(:scheduled_change_action, action)
      |> Map.put(:scheduled_change_effective_at, effective_at)
      |> Map.put(:cancel_at_period_end, action == "cancel")
    else
      attrs
    end
  end

  defp extract_current_period_start(%{"current_billing_period" => %{"starts_at" => iso}})
       when is_binary(iso),
       do: parse_iso8601(iso)

  defp extract_current_period_start(_), do: nil

  @doc false
  # Paddle bills one recurring line item. Keep all price-derived mirror fields
  # together so webhooks and the reconciliation sweep cannot drift. Invalid or
  # absent vendor values are omitted, preserving the last known-good mirror.
  def subscription_item_attrs(subscription_data) do
    case Entitlements.plan_item(subscription_data) do
      %{"price" => price} = item when is_map(price) -> subscription_item_attrs(price, item)
      _missing_or_ambiguous -> %{}
    end
  end

  defp subscription_item_attrs(price, item) do
    cycle = map_or_empty(price["billing_cycle"])
    unit_price = map_or_empty(price["unit_price"])

    %{}
    |> put_present(:paddle_price_id, present_binary(price["id"]))
    |> put_present(:billing_interval, present_binary(cycle["interval"]))
    |> put_present(:billing_frequency, positive_integer(cycle["frequency"]))
    |> put_present(:unit_price_amount, non_negative_integer(unit_price["amount"]))
    |> put_present(:currency_code, currency_code(unit_price["currency_code"]))
    |> put_present(:quantity, positive_integer(item["quantity"]))
    |> put_present(
      :trial_end,
      parse_optional_iso8601(map_or_empty(item["trial_dates"])["ends_at"])
    )
  end

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
    if String.match?(value, ~r/\A[A-Z]{3}\z/), do: value
  end

  defp currency_code(_value), do: nil

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

  defp extract_event_occurred_at(%{"occurred_at" => iso}) when is_binary(iso),
    do: parse_iso8601(iso)

  # Direct domain callers and older fixtures may carry only the subscription
  # object's monotonic timestamp. Verified Paddle envelopes carry occurred_at;
  # using updated_at as the fallback preserves ordering without inventing a
  # receipt-time timestamp that could make an old event outrank current state.
  defp extract_event_occurred_at(%{"data" => subscription_data}),
    do: extract_paddle_updated_at(subscription_data)

  defp extract_event_occurred_at(_), do: nil

  defp parse_optional_iso8601(iso) when is_binary(iso), do: parse_iso8601(iso)
  defp parse_optional_iso8601(_), do: nil

  defp parse_iso8601(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  @doc "Product-support channels for this account's effective plan, without usage or provider reads."
  def support_channels(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_billing_permission()),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id) do
      posture = account.id |> peek_subscription_for_account() |> effective_plan()
      {:ok, support_channels_for(account, posture)}
    end
  end

  defp support_channels_for(account, posture) do
    %{
      email?: posture.plan_name != "free",
      slack_url: if(posture.plan_name == "enterprise", do: account.settings.support_slack_url)
    }
  end

  @doc """
  Pricing + utilization summary for an account at the current period.

  Includes the plan's runner / member ceilings so dashboards can warn
  operators *before* they hit the wall (`X / 3` with a near-limit
  badge), not after the next runner install fails with a 402 buried
  in `journalctl`.

  Reads the current billing customer after authorizing the caller's account;
  a long-lived console session may predate the first checkout.
  """
  def billing_summary(%Accounts.Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_billing_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized),
         {:ok, account} <- Accounts.fetch_account_by_id(account.id) do
      subscription = peek_subscription_for_account(account.id)
      posture = effective_plan(subscription)
      entitled_subscription = if entitled_state?(posture.entitlement_state), do: subscription
      runner_count = current_count(account, :runners)
      member_count = current_count(account, :members)
      # nil pricing for a plan this build doesn't know (a slug minted in
      # Paddle) — the UI treats it like custom pricing, not free's $0.
      monthly_cents =
        if plan_source(subscription) == "complimentary",
          do: 0,
          else: posture.known_plan && posture.known_plan.monthly_price_cents

      # The mirrored cadence prices the period: an annual subscriber's summary
      # must read "$X/yr" at the annual per-runner rate, not the monthly one.
      cycle = subscription_cycle(entitled_subscription)

      {period_cents, currency_code} =
        period_total_cents(entitled_subscription, posture, cycle, runner_count)

      {:ok,
       %{
         plan: posture.plan_name,
         plan_name: plan_display_name(posture),
         support_channels: support_channels_for(account, posture),
         runner_count: runner_count,
         runner_limit: entitled_limit(posture, :runners_limit),
         member_count: member_count,
         member_limit: entitled_limit(posture, :members_limit),
         monthly_per_runner_cents: monthly_cents,
         monthly_total_cents: monthly_cents && monthly_cents * runner_count,
         billing_interval: cycle,
         period_total_cents: period_cents,
         currency_code: currency_code,
         audit_retention_days: entitled_retention_days(posture),
         entitlement_state: posture.entitlement_state,
         subscribed_plan: posture.stored_plan_name,
         # Subscription state mirrored from Paddle webhooks. nil when
         # the account is on a free plan and has never subscribed.
         subscription_status: subscription && subscription.status,
         subscription_source: plan_source(subscription),
         subscription_managed?:
           not is_nil(subscription) and is_binary(subscription.paddle_subscription_id) and
             subscription.status != "canceled",
         # Controls act on this account's own Paddle subscription, never on its
         # customer, which may pay for other workspaces too.
         invoices_available?:
           not is_nil(subscription) and is_binary(subscription.paddle_subscription_id),
         payment_method_updatable?: collected_subscription?(subscription),
         cancel_available?:
           collected_subscription?(subscription) and subscription.status in @changeable_statuses and
             is_nil(subscription.scheduled_change_action),
         keep_available?:
           collected_subscription?(subscription) and subscription.status in @changeable_statuses and
             subscription.scheduled_change_action == "cancel",
         features: %{
           sso:
             entitled_feature(
               posture,
               "features_sso_enabled?",
               posture.plan_name in ["team", "enterprise"]
             ),
           scim:
             entitled_feature(
               posture,
               "features_scim_enabled?",
               posture.plan_name == "enterprise"
             ),
           audit_export:
             entitled_feature(
               posture,
               "features_audit_export_enabled?",
               posture.plan_name in ["team", "enterprise"]
             )
         },
         current_period_end: subscription && subscription.current_period_end,
         cancel_at_period_end: subscription && subscription.cancel_at_period_end,
         scheduled_change_action: subscription && subscription.scheduled_change_action,
         scheduled_change_effective_at:
           subscription && subscription.scheduled_change_effective_at,
         trial_end: subscription && subscription.trial_end
       }}
    end
  end

  # -- Authorization ----------------------------------------------------

  @doc """
  Whether `subject` may manage billing and the subscription — the owner and the
  billing-manager seat. Also gates the plan catalogue, since choosing one is a
  checkout.
  """
  def subject_can_manage_billing?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_billing_permission())

  @doc "Whether `subject` may read the invoice ledger — owners, admins, and the billing manager."
  def subject_can_view_invoices?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_invoices_permission())

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
