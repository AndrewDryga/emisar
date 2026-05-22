defmodule Emisar.Billing do
  @moduledoc """
  Billing scaffold. Stripe is the source of truth; we mirror just
  enough for plan enforcement without round-tripping per request.

  This module is intentionally a placeholder. The Stripe HTTP calls
  are stubbed via `Stripe` behaviour; real implementation lives
  behind `Application.fetch_env!(:emisar, :stripe_client)`.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Accounts.Account
  alias Emisar.Billing.Subscription

  @plans %{
    "free" => %{
      name: "Free",
      monthly_price_cents: 0,
      agents_limit: 3,
      members_limit: 1,
      audit_retention_days: 7,
      features: ["3 runners", "1 user", "7-day audit retention", "Community support"]
    },
    "team" => %{
      name: "Team",
      monthly_price_cents: 2000,
      agents_limit: 100,
      members_limit: 25,
      audit_retention_days: 90,
      features: [
        "Unlimited users",
        "90-day audit retention",
        "polkit / sudo recipes",
        "Email support",
        "Stripe billing"
      ]
    },
    "enterprise" => %{
      name: "Enterprise",
      monthly_price_cents: nil,
      agents_limit: :unlimited,
      members_limit: :unlimited,
      audit_retention_days: 365,
      features: [
        "Everything in Team",
        "SAML SSO",
        "On-prem control plane",
        "Custom retention",
        "Dedicated support / SLA"
      ]
    }
  }

  def plans, do: @plans
  def plan(name) when is_binary(name), do: Map.get(@plans, name)

  def get_subscription(account_id), do: Repo.get_by(Subscription, account_id: account_id)

  def upsert_subscription(account_id, attrs) do
    case get_subscription(account_id) do
      nil ->
        %Subscription{}
        |> Subscription.changeset(Map.put(attrs, :account_id, account_id))
        |> Repo.insert()

      %Subscription{} = existing ->
        existing |> Subscription.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Returns :ok if the account is within plan limits for `resource`.
  Returns `{:error, :over_limit, plan, limit}` otherwise.
  """
  def check_limit(%Account{plan: plan_name} = account, resource) do
    plan = plan(plan_name)
    limit = Map.get(plan, limit_key(resource))

    current = current_count(account, resource)

    cond do
      limit == :unlimited -> :ok
      current < limit -> :ok
      true -> {:error, :over_limit, plan_name, limit}
    end
  end

  defp limit_key(:runners), do: :agents_limit
  defp limit_key(:members), do: :members_limit

  defp current_count(%Account{id: account_id}, :runners) do
    from(a in Emisar.Runners.Runner,
      where: a.account_id == ^account_id and is_nil(a.disabled_at),
      select: count(a.id)
    )
    |> Repo.one()
  end

  defp current_count(%Account{id: account_id}, :members) do
    from(m in Emisar.Accounts.Membership,
      where: m.account_id == ^account_id,
      select: count(m.id)
    )
    |> Repo.one()
  end

  @doc """
  Creates a Stripe Checkout Session for the chosen plan and returns
  the URL the operator should be redirected to. Falls back to a stub
  URL when no Stripe price ID is configured (dev/test).
  """
  def start_checkout(%Account{} = account, plan_name) when is_binary(plan_name) do
    cond do
      not Map.has_key?(@plans, plan_name) ->
        {:error, :unknown_plan}

      is_nil(Application.get_env(:emisar, {:stripe_price_id, plan_name})) ->
        {:ok, "/stripe-checkout-stub?plan=" <> plan_name}

      true ->
        with {:ok, cid, _account} <- ensure_stripe_customer(account),
             price_id <- Application.fetch_env!(:emisar, {:stripe_price_id, plan_name}),
             {:ok, %{"url" => url}} <-
               Emisar.Billing.StripeClient.create_checkout_session(%{
                 customer: cid,
                 price_id: price_id,
                 quantity: current_count(account, :runners),
                 success_url: app_url("/app/settings/billing?status=success"),
                 cancel_url: app_url("/app/settings/billing?status=cancelled")
               }) do
          {:ok, url}
        end
    end
  end

  @doc """
  Ensures the account has a Stripe customer; returns the customer id.
  Idempotent — if the account already has one, just returns it.
  """
  def ensure_stripe_customer(%Account{stripe_customer_id: cid} = account) when is_binary(cid),
    do: {:ok, cid, account}

  def ensure_stripe_customer(%Account{} = account) do
    with {:ok, %{"id" => cid}} <-
           Emisar.Billing.StripeClient.create_customer(%{
             email: nil,
             name: account.name,
             account_id: account.id
           }),
         {:ok, account} <- update_account_stripe_id(account, cid) do
      {:ok, cid, account}
    end
  end

  @doc """
  Returns a URL to Stripe's customer portal so the operator can manage
  payment methods, see invoices, cancel.
  """
  def billing_portal_url(%Account{stripe_customer_id: cid}) when is_binary(cid) do
    case Emisar.Billing.StripeClient.create_billing_portal_session(%{
           customer: cid,
           return_url: app_url("/app/settings/billing")
         }) do
      {:ok, %{"url" => url}} -> {:ok, url}
      err -> err
    end
  end

  def billing_portal_url(_), do: {:error, :no_stripe_customer}

  @doc """
  Atomically:

    * inserts the Stripe event id into `stripe_processed_events` (unique
      primary key); if the row already exists, returns
      `{:duplicate, existing}` and does NOT re-apply,
    * calls `apply_webhook_event/1` inside the same transaction so we
      can never end up with the dedup row recorded but the side effects
      missing.
  """
  def record_and_apply_event(event_id, event_type, event)
      when is_binary(event_id) and is_binary(event_type) do
    Repo.transaction(fn ->
      attrs = %{
        id: event_id,
        event_type: event_type,
        received_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      changeset =
        Ecto.Changeset.cast(
          {%{}, %{id: :string, event_type: :string, received_at: :utc_datetime_usec}},
          attrs,
          [:id, :event_type, :received_at]
        )

      case Repo.insert(changeset, source: "stripe_processed_events", on_conflict: :nothing) do
        {:ok, %{id: nil}} ->
          # on_conflict: :nothing returns a struct with id=nil when the
          # row already existed; treat as duplicate.
          Repo.rollback({:duplicate, event_id})

        {:ok, _row} ->
          apply_webhook_event(event)

        {:error, _cs} ->
          Repo.rollback({:duplicate, event_id})
      end
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, {:duplicate, _} = dup} -> dup
      {:error, other} -> {:error, other}
    end
  end

  @doc """
  Apply an incoming Stripe webhook event. Idempotent on `event["id"]`
  (deduped via `record_and_apply_event/3`).
  """
  def apply_webhook_event(%{"type" => "customer.subscription.created", "data" => %{"object" => sub}}),
    do: upsert_from_subscription(sub)

  def apply_webhook_event(%{"type" => "customer.subscription.updated", "data" => %{"object" => sub}}),
    do: upsert_from_subscription(sub)

  def apply_webhook_event(%{"type" => "customer.subscription.deleted", "data" => %{"object" => sub}}) do
    case find_subscription_by_stripe_id(sub["id"]) do
      nil ->
        :ok

      %Subscription{} = s ->
        Repo.update(Subscription.changeset(s, %{status: "canceled"}))
    end
  end

  def apply_webhook_event(_event), do: :ok

  defp upsert_from_subscription(sub) do
    case find_account_by_stripe_customer(sub["customer"]) do
      nil ->
        :ok

      %Account{id: account_id} ->
        attrs = %{
          stripe_subscription_id: sub["id"],
          status: sub["status"],
          current_period_end: epoch_to_dt(sub["current_period_end"])
        }

        upsert_subscription(account_id, attrs)
    end
  end

  defp find_account_by_stripe_customer(cid) when is_binary(cid),
    do: Repo.get_by(Account, stripe_customer_id: cid)

  defp find_subscription_by_stripe_id(id),
    do: Repo.get_by(Subscription, stripe_subscription_id: id)

  defp update_account_stripe_id(account, cid) do
    account
    |> Ecto.Changeset.change(stripe_customer_id: cid)
    |> Repo.update()
  end

  defp app_url(path) do
    base =
      Application.get_env(:emisar_web, EmisarWeb.Endpoint, [])
      |> Keyword.get(:url, host: "localhost")
      |> case do
        [host: host, port: port] -> "https://#{host}:#{port}"
        [host: host] -> "https://#{host}"
        _ -> "http://localhost:4000"
      end

    base <> path
  end

  defp epoch_to_dt(nil), do: nil

  defp epoch_to_dt(secs) when is_integer(secs),
    do: DateTime.from_unix!(secs) |> DateTime.truncate(:second)

  @doc """
  Pricing summary for an account at the current period:
    %{plan: ..., runners: N, monthly_total_cents: ..., audit_retention_days: ...}
  """
  def billing_summary(%Account{} = account) do
    plan_def = plan(account.plan) || plan("free")
    agent_count = current_count(account, :runners)

    %{
      plan: account.plan,
      plan_name: plan_def.name,
      agent_count: agent_count,
      monthly_per_agent_cents: plan_def.monthly_price_cents,
      monthly_total_cents:
        case plan_def.monthly_price_cents do
          nil -> nil
          n -> n * agent_count
        end,
      audit_retention_days: plan_def.audit_retention_days
    }
  end
end
