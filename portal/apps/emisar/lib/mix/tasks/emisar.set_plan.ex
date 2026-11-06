defmodule Mix.Tasks.Emisar.SetPlan do
  @shortdoc "Manually set an account's plan (support-managed enterprise / custom deals)"
  @moduledoc """
  Flip an account onto a plan WITHOUT a Paddle subscription — for a
  support-managed enterprise or custom deal that's invoiced outside self-serve.

  It writes a complimentary `subscriptions` row (no `paddle_subscription_id`)
  through `Billing.grant_complimentary_plan/2`, the path the
  `emisar.admin.plan.grant` support action uses, which is how the demo account is
  enterprise: the billing page then shows the
  "handled with our team" note, offers no self-serve portal, and the plan's
  entitlements (SCIM, limits, audit retention) apply. The change is audited
  (the grant records the entitlement change).

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

    case Emisar.Accounts.fetch_account_by_id_or_slug_including_disabled(id_or_slug) do
      {:ok, account} ->
        if Emisar.Billing.paddle_managed?(account.id) do
          Mix.raise(
            "#{account.slug} has a live Paddle subscription — a manual flip would be reverted " <>
              "within the hour by SyncSubscriptions. Change the plan in Paddle, or cancel it first."
          )
        end

        # The same complimentary-plan path the emisar.admin.plan.grant support action
        # uses, so a later staff grant or revoke can still change this row.
        result =
          if plan == "free",
            do: Emisar.Billing.revoke_complimentary_plan(account),
            else: Emisar.Billing.grant_complimentary_plan(account, plan)

        case result do
          {:ok, _} ->
            Mix.shell().info(
              "✓ #{account.name} (#{account.slug}) is now on the #{plan} plan " <>
                "— support-managed, no Paddle subscription."
            )

          {:error, reason} ->
            Mix.raise(
              "#{account.slug} kept its plan: #{inspect(reason)}. A Paddle or older " <>
                "support-managed row is in the way; convert it before granting."
            )
        end

      {:error, _} ->
        Mix.raise("No account matches #{inspect(id_or_slug)}")
    end
  end
end
