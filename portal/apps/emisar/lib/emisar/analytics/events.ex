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
  end

  defp account_distinct_id(account_id), do: "account:" <> account_id
end
