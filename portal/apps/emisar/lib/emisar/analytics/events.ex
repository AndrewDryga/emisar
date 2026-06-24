defmodule Emisar.Analytics.Events do
  @moduledoc """
  Per-event product-analytics builders. Deliberately narrow: emisar sends
  Mixpanel only marketing + growth signals, never operational telemetry it can
  read from the database (runs, runners, approvals, policies, packs). The
  marketing/auth events live in `EmisarWeb.Analytics`; this module carries the
  one domain growth signal — a plan change.
  """

  alias Emisar.Analytics
  alias Emisar.Billing

  @doc "Expansion — a Paddle subscription was created, updated, or canceled."
  def subscription_changed(%Billing.Subscription{} = subscription) do
    Analytics.track("subscription_changed", account_distinct_id(subscription.account_id), %{
      "plan" => subscription.plan,
      "status" => subscription.status,
      "account_id" => subscription.account_id
    })

    # Stamp the plan on the account's Group profile so retention/expansion can be
    # segmented by plan (no-op without the Group Analytics add-on).
    Analytics.set_group("account_id", subscription.account_id, %{
      "plan" => subscription.plan,
      "status" => subscription.status
    })
  end

  defp account_distinct_id(account_id), do: "account:" <> account_id
end
