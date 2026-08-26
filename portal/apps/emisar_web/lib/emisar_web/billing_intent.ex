defmodule EmisarWeb.BillingIntent do
  @moduledoc """
  Purpose-bound, short-lived preselection for self-serve billing.

  The token carries only the compiled plan key and billing cadence. It grants no
  account access and names no price, Paddle resource, URL, or amount; the
  authenticated Billing boundary still resolves the live catalog and authorizes
  the selected account before checkout.
  """
  alias Emisar.Billing

  @salt "billing plan-cycle intent v1"
  @max_age_seconds 24 * 60 * 60

  @doc "Signs the exact self-serve Team plan and billing cadence."
  def sign("team", cycle) when cycle in [:month, :year] do
    Phoenix.Token.sign(
      EmisarWeb.Endpoint,
      @salt,
      {:v1, "team", Atom.to_string(cycle)}
    )
  end

  @doc "Verifies a live self-serve intent -> `{:ok, %{plan: plan, cycle: cycle}} | {:error, :invalid}`."
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, {:v1, "team", "month"}} -> verified("team", :month)
      {:ok, {:v1, "team", "year"}} -> verified("team", :year)
      _other -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp verified(plan, cycle) do
    if Billing.self_service_checkout?(plan, cycle),
      do: {:ok, %{plan: plan, cycle: cycle}},
      else: {:error, :invalid}
  end
end
