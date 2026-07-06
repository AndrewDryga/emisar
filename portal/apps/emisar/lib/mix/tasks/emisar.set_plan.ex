defmodule Mix.Tasks.Emisar.SetPlan do
  @shortdoc "Manually set an account's plan (support-managed enterprise / custom deals)"
  @moduledoc """
  Flip an account onto a plan WITHOUT a Paddle subscription — for a
  support-managed enterprise or custom deal that's invoiced outside self-serve.

  It writes a manual `subscriptions` row (no `paddle_subscription_id`), which is
  exactly how the demo account is enterprise: the billing page then shows the
  "handled with our team" note, offers no self-serve portal, and the plan's
  entitlements (SCIM, limits, audit retention) apply. The change is audited
  (`Billing.upsert_subscription` logs the plan transition).

      mix emisar.set_plan acme enterprise
      mix emisar.set_plan 019f3582-... team

  The plan must be one of the compiled plans (free / team / enterprise). To take
  an account back to free, pass `free`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [id_or_slug, plan] -> set_plan(id_or_slug, plan)
      _ -> Mix.raise("Usage: mix emisar.set_plan <account_id_or_slug> <plan>")
    end
  end

  defp set_plan(id_or_slug, plan) do
    plans = Map.keys(Emisar.Billing.plans())

    unless plan in plans do
      Mix.raise("Unknown plan #{inspect(plan)} — one of #{inspect(plans)}")
    end

    case Emisar.Accounts.fetch_account_by_id_or_slug(id_or_slug) do
      {:ok, account} ->
        {:ok, _sub} =
          Emisar.Billing.upsert_subscription(account.id, %{plan: plan, status: "active"})

        Mix.shell().info(
          "✓ #{account.name} (#{account.slug}) is now on the #{plan} plan " <>
            "— support-managed, no Paddle subscription."
        )

      {:error, _} ->
        Mix.raise("No account matches #{inspect(id_or_slug)}")
    end
  end
end
