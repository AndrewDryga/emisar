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
  alias Emisar.{Accounts, Analytics, Audit, Auth, Crypto, PublicUrl, Repo, Runners}
  alias Emisar.Auth.Subject
  alias Emisar.Billing.{Authorizer, Entitlements, PaddleClient, Subscription}
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
        # No support entry: "Community support" named a channel that does not
        # exist — no Discord, forum, or Discussions anywhere — while /support
        # offers email help with no plan qualifier. Free claims no distinct
        # support channel rather than an imaginary one; the comparison table
        # renders the em-dash it already renders for any absent feature, and
        # Team's "Email support" stays the real differentiator.
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
        support: "Dedicated Slack support channel",
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
      job_module("SyncPaddleCustomers"),
      job_module("SyncRunnerQuantities"),
      job_module("SyncSubscriptions")
    ]

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

  @doc """
  The account's effective plan name from the authoritative subscription
  lifecycle projection. Active, automatic-dunning, and not-yet-effective
  cancellation states retain the subscribed plan; expired or unresolved state
  uses Free. The raw subscribed plan remains on the subscription for billing
  history and provider reconciliation.
  """
  def account_plan(%Accounts.Account{} = account) do
    account.id |> peek_subscription_for_account() |> effective_plan() |> Map.fetch!(:plan_name)
  end

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
    action =
      subscription.scheduled_change_action ||
        if(subscription.cancel_at_period_end, do: "cancel")

    effective_at =
      subscription.scheduled_change_effective_at ||
        if(subscription.cancel_at_period_end, do: subscription.current_period_end)

    cond do
      is_nil(action) ->
        nil

      action in ["cancel", "pause"] and is_struct(effective_at, DateTime) ->
        if DateTime.compare(now, effective_at) == :lt, do: :ending, else: :expired

      true ->
        :unresolved
    end
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
    case peek_subscription_for_account(account.id) do
      %Subscription{paddle_subscription_id: id, status: status}
      when is_binary(id) and status != "canceled" ->
        case PaddleClient.cancel_subscription(id) do
          {:ok, _subscription} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
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
    writer = if Keyword.get(opts, :manual, false), do: :manual, else: :upsert
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
    paddle_id = attrs[:paddle_subscription_id] || attrs["paddle_subscription_id"]
    status = attrs[:status] || attrs["status"]
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
    Multi.new()
    |> Multi.run(:subscription, fn repo, _changes ->
      subscription =
        Subscription.Query.all()
        |> Subscription.Query.by_id(subscription_id)
        |> Subscription.Query.lock_for_update()
        |> repo.peek()

      {:ok, subscription}
    end)
    |> Multi.run(:quantity_sync, fn repo, %{subscription: subscription} ->
      reconcile_locked_runner_quantity(repo, subscription)
    end)
    # A converging update makes one GET and at most one PATCH. Paddle's update
    # response may wait on an immediate final-period charge, so leave headroom
    # above the two eight-second HTTP receive timeouts while holding the row.
    |> Repo.commit_multi(timeout: 25_000)
    |> case do
      {:ok, %{quantity_sync: result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_locked_runner_quantity(_repo, nil), do: {:ok, :missing}

  defp reconcile_locked_runner_quantity(_repo, %Subscription{paddle_subscription_id: nil}),
    do: {:ok, :not_paddle_managed}

  defp reconcile_locked_runner_quantity(repo, %Subscription{} = subscription) do
    with {:ok, _account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(subscription.account_id),
         {:ok, subscription_data} <-
           PaddleClient.retrieve_subscription(subscription.paddle_subscription_id),
         {:ok, action} <- runner_quantity_action(subscription_data) do
      apply_runner_quantity_action(repo, subscription, subscription_data, action)
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

  defp apply_runner_quantity_action(repo, subscription, subscription_data, :stop) do
    persist_runner_quantity_convergence(
      repo,
      subscription,
      subscription_data,
      subscription.quantity
    )
    |> then(fn
      {:ok, _subscription} -> {:ok, :stopped}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp apply_runner_quantity_action(repo, subscription, _subscription_data, :defer) do
    request_deferred_runner_quantity_sync(repo, subscription)
    {:ok, :deferred}
  end

  defp apply_runner_quantity_action(
         repo,
         %Subscription{} = subscription,
         subscription_data,
         {:update, proration_mode}
       ) do
    desired_quantity = max(Runners.count_billable_runners(subscription.account_id), 1)

    with {:ok, items, _target_price_id, remote_quantity} <-
           runner_quantity_items(subscription_data, desired_quantity) do
      if remote_quantity == desired_quantity do
        persist_runner_quantity_convergence(
          repo,
          subscription,
          subscription_data,
          desired_quantity
        )
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
               persist_runner_quantity_convergence(
                 repo,
                 subscription,
                 updated,
                 desired_quantity
               ) do
          {:ok, :updated}
        end
      end
    end
  end

  defp request_deferred_runner_quantity_sync(repo, subscription) do
    Subscription.Query.all()
    |> Subscription.Query.by_id(subscription.id)
    |> Subscription.Query.runner_quantity_sync_not_requested()
    |> repo.update_all(set: [runner_quantity_sync_requested_at: DateTime.utc_now()])
  end

  defp persist_runner_quantity_convergence(repo, subscription, subscription_data, quantity) do
    case extract_paddle_updated_at(subscription_data) do
      %DateTime{} = paddle_updated_at ->
        result =
          subscription
          |> Subscription.Changeset.upsert(%{
            quantity: quantity,
            paddle_updated_at: paddle_updated_at,
            runner_quantity_sync_requested_at: nil
          })
          |> repo.update()

        case result do
          {:ok,
           %Subscription{
             quantity: ^quantity,
             paddle_updated_at: ^paddle_updated_at,
             runner_quantity_sync_requested_at: nil
           } = updated} ->
            {:ok, updated}

          {:ok, %Subscription{}} ->
            {:error, :stale_subscription_snapshot}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :missing_subscription_updated_at}
    end
  end

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
         {:ok, requested} <- requested_price_quantities(requested_items),
         true <- actual == requested do
      :ok
    else
      _mismatch -> {:error, :quantity_update_not_applied}
    end
  end

  defp requested_price_quantities(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, %{}}, fn
      %{"price_id" => price_id, "quantity" => quantity}, {:ok, acc}
      when is_binary(price_id) and price_id != "" and is_integer(quantity) and quantity > 0 ->
        if Map.has_key?(acc, price_id) do
          {:halt, {:error, :ambiguous_subscription_items}}
        else
          {:cont, {:ok, Map.put(acc, price_id, quantity)}}
        end

      _item, _acc ->
        {:halt, {:error, :malformed_subscription_items}}
    end)
  end

  defp unique_price_ids?(items) do
    items
    |> Enum.map(& &1.price_id)
    |> then(&(Enum.uniq(&1) == &1))
  end

  defp entitlement_snapshot(subscription) do
    posture = effective_plan(subscription)

    %{
      plan: posture.plan_name,
      subscribed_plan: posture.stored_plan_name,
      entitlement_state: posture.entitlement_state,
      subscription_status: subscription && subscription.status,
      scheduled_change_action: subscription && subscription.scheduled_change_action,
      scheduled_change_effective_at: subscription && subscription.scheduled_change_effective_at
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
      subscribed_plan: new_snapshot.subscribed_plan,
      scheduled_change_action: new_snapshot.scheduled_change_action,
      scheduled_change_effective_at: new_snapshot.scheduled_change_effective_at
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
      # The returned URL is the account's DEFAULT PAYMENT LINK (our /checkout
      # page running Paddle.js) + ?_ptxn=<transaction> — Paddle has no hosted
      # checkout. Deliberately no per-transaction checkout.url override: that
      # requires its own domain approval, while the default link is the
      # canonical mechanism. The post-payment redirect is the page's
      # successUrl setting, not a transaction field.
      with {:ok, price_id} <- resolve_checkout_price_id(plan_name, cycle),
           {:ok, customer_id, _account} <- ensure_paddle_customer(account, subject),
           {:ok, %{"id" => transaction_id, "url" => url}} <-
             Emisar.Billing.PaddleClient.create_checkout_session(%{
               customer: customer_id,
               price_id: price_id,
               # Per-runner pricing floors at ONE seat: a zero-runner
               # account (fresh signup) must still be able to buy, and
               # Paddle rejects quantity 0.
               quantity: max(current_count(account, :runners), 1)
             }),
           binding = Crypto.paddle_account_binding(account.id, transaction_id),
           {:ok, _transaction} <-
             PaddleClient.bind_checkout_transaction(transaction_id, binding) do
        {:ok, url}
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
  # directly. An existing subscriber changes plans in the Paddle customer portal
  # ("Manage billing"), which is also what the downgrade branch already does.
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

  defp known_plan_from_name(name) when is_binary(name) do
    slug = name |> String.trim() |> String.downcase()
    if Map.has_key?(@plans, slug), do: slug
  end

  defp known_plan_from_name(_name), do: nil

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

    if Emisar.Config.get_env(:emisar, :paddle_api_key) do
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
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
      do_list_recent_invoices(account, opts)
    end
  end

  @doc """
  The signed, short-lived URL of one transaction's invoice PDF, so a billing
  manager can download an invoice inline instead of opening the portal. Gated on
  `view_invoices`, like the list it is reached from; the transaction is
  re-checked against the account's own recent invoices first, so a crafted id
  can't pull another account's PDF — `{:error, :not_found}` otherwise.
  """
  def invoice_pdf_url(%Accounts.Account{} = account, transaction_id, %Subject{} = subject)
      when is_binary(transaction_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_invoices_permission()),
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
    with {:ok, customer_id} <- create_or_adopt_paddle_customer(account, owner),
         {:ok, linked} <-
           Accounts.put_account_paddle_customer_sync(account, customer_id, owner.id) do
      sync_linked_paddle_customer(linked, customer_id, owner)
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

  defp create_or_adopt_paddle_customer(%Accounts.Account{} = account, owner) do
    case PaddleClient.create_customer(customer_attrs(account, owner)) do
      {:ok, %{"id" => customer_id}} ->
        {:ok, customer_id}

      {:ok, _data} ->
        {:error, :missing_customer_id}

      {:error, {:http, 409, _body}} = conflict ->
        adopt_conflicting_paddle_customer(conflict, owner)

      other ->
        other
    end
  end

  # Paddle enforces one customer per email across the seller account, so an
  # owner address it already knows — a re-created account, a customer the seller
  # made by hand, an earlier sync that linked nothing — makes create fail. The
  # local id stays nil, so the next sweep repeats the identical create and
  # conflicts again, forever. Adopt the customer already holding the address.
  defp adopt_conflicting_paddle_customer({:error, {:http, 409, body}} = conflict, owner) do
    case paddle_error_code(body) do
      "customer_already_exists" -> fetch_paddle_customer_id_by_email(owner.email)
      _other_conflict -> conflict
    end
  end

  defp fetch_paddle_customer_id_by_email(email) do
    # The filter is an exact match on a field Paddle keeps unique, so a
    # conflicting email resolves to exactly one customer; an empty list means
    # Paddle contradicted its own 409 and there is nothing to adopt.
    case PaddleClient.list_customers(%{email: email}) do
      {:ok, [%{"id" => customer_id}]} -> {:ok, customer_id}
      {:ok, _customers} -> {:error, :conflicting_customer_not_found}
      other -> other
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

  def apply_webhook_event(%{"event_type" => event_type, "data" => subscription_data} = event)
      when event_type in @subscription_lifecycle_events do
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
        upsert_from_subscription(subscription_data, extract_event_occurred_at(event),
          source: :webhook,
          transaction_id: subscription_data["transaction_id"]
        )

      _ ->
        {:error, :malformed_subscription}
    end
  end

  def apply_webhook_event(_event), do: :ok

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

  defp reconcile_unseen_subscription(subscription_data) do
    case resolve_subscription_account(subscription_data, source: :reconciliation) do
      {:error, :not_found} ->
        :ok

      {:error, :ambiguous} ->
        {:error, :ambiguous_paddle_customer}

      {:error, :invalid_binding} ->
        {:error, :invalid_subscription_account_binding}

      {:ok, %Accounts.Account{deleted_at: %DateTime{}}} ->
        retire_closed_account_subscription(subscription_data)

      {:ok, %Accounts.Account{id: account_id}} ->
        case peek_subscription_for_account(account_id) do
          nil ->
            reconcile_subscription_data(subscription_data, expected_subscription: :missing)

          %Subscription{status: "canceled"} = terminal ->
            reconcile_subscription_data(subscription_data, expected_subscription: terminal)

          %Subscription{} ->
            {:error, :different_live_subscription}
        end
    end
  end

  defp upsert_from_subscription(subscription_data, event_occurred_at, opts) do
    existing = peek_subscription_by_paddle_id(subscription_data["id"])

    case existing do
      %Subscription{account_id: account_id} ->
        mirror_subscription_for_account(account_id, subscription_data,
          event_occurred_at: event_occurred_at,
          expected_mirror: Keyword.get(opts, :expected_mirror, :unchecked)
        )

      nil ->
        upsert_first_seen_subscription(subscription_data, event_occurred_at, opts)
    end
  end

  defp upsert_first_seen_subscription(subscription_data, event_occurred_at, opts) do
    case resolve_subscription_account(subscription_data, opts) do
      {:error, :not_found} ->
        :ok

      {:error, :ambiguous} ->
        {:error, :ambiguous_paddle_customer}

      {:error, :invalid_binding} ->
        {:error, :invalid_subscription_account_binding}

      {:ok, %Accounts.Account{deleted_at: %DateTime{}}} ->
        retire_closed_account_subscription(subscription_data)

      {:ok, %Accounts.Account{id: account_id}} ->
        expected = first_seen_expected_mirror(account_id, opts)

        case expected do
          {:error, reason} ->
            {:error, reason}

          expected_mirror ->
            result =
              mirror_subscription_for_account(account_id, subscription_data,
                event_occurred_at: event_occurred_at,
                expected_mirror: expected_mirror,
                reject_deleted?: true
              )

            case result do
              {:error, :account_closed} -> retire_closed_account_subscription(subscription_data)
              other -> other
            end
        end
    end
  end

  # A checkout link can outlive its account. If payment completes after the
  # account was closed, never recreate paid access on the tombstone: retire the
  # provider subscription immediately. A successful cancel is enough; the
  # later canceled receipt may mirror history, but no active local row exists.
  defp retire_closed_account_subscription(%{"status" => status})
       when status in ["canceled", "paused"],
       do: :ok

  defp retire_closed_account_subscription(%{"id" => id}) when is_binary(id) do
    case PaddleClient.cancel_subscription(id) do
      {:ok, _subscription} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_seen_expected_mirror(account_id, opts) do
    case Keyword.fetch(opts, :expected_mirror) do
      {:ok, expected} ->
        expected

      :error ->
        case peek_subscription_for_account(account_id) do
          nil -> nil
          %Subscription{status: "canceled"} = terminal -> mirror_version(terminal)
          %Subscription{} -> {:error, :different_live_subscription}
        end
    end
  end

  defp mirror_subscription_for_account(account_id, subscription_data, opts) do
    existing = peek_subscription_for_account(account_id)

    plan =
      Entitlements.plan_slug(subscription_data) ||
        known_plan_from_name(Entitlements.product_name(subscription_data)) ||
        stored_plan_from_subscription(existing)

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

    upsert_subscription(account_id, attrs, upsert_opts)
  end

  defp resolve_subscription_account(subscription_data, opts) do
    customer_id = subscription_data["customer_id"]
    binding = get_in(subscription_data, ["custom_data", "emisar_account_binding"])

    case binding do
      nil ->
        Accounts.resolve_paddle_subscription_account(customer_id)

      token when is_binary(token) ->
        with {:ok, {account_id, transaction_id}} <-
               Crypto.verify_paddle_account_binding(token),
             :ok <- verify_bound_transaction(subscription_data, transaction_id, opts) do
          Accounts.resolve_paddle_subscription_account(customer_id, account_id)
        else
          {:error, _reason} -> {:error, :invalid_binding}
        end

      _invalid ->
        {:error, :invalid_binding}
    end
  end

  defp verify_bound_transaction(subscription_data, transaction_id, opts) do
    case Keyword.get(opts, :source) do
      :webhook ->
        if Keyword.get(opts, :transaction_id) == transaction_id,
          do: :ok,
          else: {:error, :transaction_mismatch}

      :reconciliation ->
        with {:ok, transaction} <- PaddleClient.retrieve_transaction(transaction_id),
             true <- transaction["subscription_id"] == subscription_data["id"] do
          :ok
        else
          _mismatch_or_failure -> {:error, :transaction_mismatch}
        end

      _unknown_source ->
        {:error, :transaction_mismatch}
    end
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
    if String.match?(value, ~r/^[A-Z]{3}$/), do: value
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
      entitled_subscription = if entitled_state?(posture.entitlement_state), do: subscription
      runner_count = current_count(account, :runners)
      member_count = current_count(account, :members)
      # nil pricing for a plan this build doesn't know (a slug minted in
      # Paddle) — the UI treats it like custom pricing, not free's $0.
      monthly_cents = posture.known_plan && posture.known_plan.monthly_price_cents
      # The mirrored cadence prices the period: an annual subscriber's summary
      # must read "$X/yr" at the annual per-runner rate, not the monthly one.
      cycle = subscription_cycle(entitled_subscription)

      {period_cents, currency_code} =
        period_total_cents(entitled_subscription, posture, cycle, runner_count)

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
         period_total_cents: period_cents,
         currency_code: currency_code,
         audit_retention_days: entitled_retention_days(posture),
         entitlement_state: posture.entitlement_state,
         subscribed_plan: posture.stored_plan_name,
         # Subscription state mirrored from Paddle webhooks. nil when
         # the account is on a free plan and has never subscribed.
         subscription_status: subscription && subscription.status,
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
