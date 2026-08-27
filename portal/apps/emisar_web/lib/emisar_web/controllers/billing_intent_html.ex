defmodule EmisarWeb.BillingIntentHTML do
  use EmisarWeb, :html

  def show(assigns) do
    ~H"""
    <.auth_layout title="Choose a workspace">
      <.selected_plan cycle={@intent.cycle} class="mb-7">
        Choose the workspace to upgrade. Review the price before you pay.
      </.selected_plan>

      <div class="space-y-3">
        <form :for={account <- @accounts} action={~p"/app/billing/start"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="account_id" value={account.id} />
          <.button type="submit" variant={:secondary} class="w-full justify-between">
            <span class="min-w-0 text-left">
              <span class="block truncate">{account.name}</span>
              <span class="block truncate font-mono text-xs font-normal text-zinc-500">
                app/{account.slug}
              </span>
            </span>
            <span aria-hidden="true">→</span>
          </.button>
        </form>
      </div>

      <.empty_state
        :if={@accounts == []}
        variant={:hint}
        icon="product.billing"
        title="Create a workspace first"
      >
        Create a workspace on Free, then review the Team upgrade.
      </.empty_state>

      <div class="mt-6 space-y-3">
        <.button
          navigate={~p"/onboarding?billing_intent=#{@token}"}
          variant={:secondary}
          class="w-full"
        >
          Create a new workspace
        </.button>
        <form action={~p"/app/billing/start/cancel"} method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            class="w-full py-2 text-sm font-medium text-zinc-400 hover:text-zinc-200"
          >
            Keep my current plan
          </button>
        </form>
      </div>
    </.auth_layout>
    """
  end
end
