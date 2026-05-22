defmodule EmisarWeb.BillingLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Billing}
  alias EmisarWeb.Permissions

  @plan_order ["free", "team", "enterprise"]

  def mount(_params, _session, socket) do
    account = socket.assigns.current_account

    {:ok,
     socket
     |> assign(:page_title, "Billing")
     |> assign(:plans, ordered_plans())
     |> assign(:summary, Billing.billing_summary(account))
     |> assign(:member_count, length(Accounts.list_memberships_for_account(account.id)))}
  end

  def handle_event("upgrade", %{"plan" => plan}, socket) do
    Permissions.gated(socket, :manage_billing, fn s ->
      if plan in @plan_order do
        case Billing.start_checkout(s.assigns.current_account, plan) do
          {:ok, url} ->
            {:noreply, redirect(s, external: url)}

          {:error, reason} ->
            {:noreply, put_flash(s, :error, "Could not start checkout: #{inspect(reason)}")}
        end
      else
        {:noreply, put_flash(s, :error, "Unknown plan.")}
      end
    end)
  end

  def handle_event("contact_sales", _params, socket) do
    {:noreply, put_flash(socket, :info, "We'll be in touch — email sales@emisar.com to chat sooner.")}
  end

  defp ordered_plans do
    all = Billing.plans()

    Enum.map(@plan_order, fn key ->
      def_map = Map.fetch!(all, key)
      Map.put(def_map, :key, key)
    end)
  end

  defp limit_label(:unlimited), do: "Unlimited"
  defp limit_label(n) when is_integer(n), do: Integer.to_string(n)
  defp limit_label(_), do: "—"

  defp price_label(%{monthly_price_cents: nil}), do: "Custom"
  defp price_label(%{monthly_price_cents: 0}), do: "Free"

  defp price_label(%{monthly_price_cents: cents}),
    do: "$#{div(cents, 100)} / runner / month"

  defp current_plan?(%{key: key}, %{plan: current}), do: key == current

  defp plan_limit(plans, plan_name, key) do
    case Enum.find(plans, &(&1.key == plan_name)) do
      nil -> nil
      plan -> Map.get(plan, key)
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:billing}
    >
      <:title>Billing</:title>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-1">
          <.section_header title="Current plan" />
          <div class="mt-4 flex items-baseline gap-2">
            <span class="text-3xl font-semibold text-zinc-50">{@summary.plan_name}</span>
            <span class="text-xs text-zinc-500">({@summary.plan})</span>
          </div>
          <p class="mt-1 text-xs text-zinc-500">
            {@summary.audit_retention_days}-day audit retention.
          </p>

          <dl class="mt-6 space-y-1 text-sm">
            <.kv label="Runners">
              {@summary.agent_count} / {limit_label(plan_limit(@plans, @summary.plan, :agents_limit))}
            </.kv>
            <.kv label="Members">
              {@member_count} / {limit_label(plan_limit(@plans, @summary.plan, :members_limit))}
            </.kv>
            <.kv label="Monthly total">
              <%= cond do %>
                <% is_nil(@summary.monthly_per_agent_cents) -> %>
                  Custom
                <% @summary.monthly_per_agent_cents == 0 -> %>
                  $0
                <% true -> %>
                  ${div(@summary.monthly_total_cents, 100)}.{:io_lib.format("~2..0B", [rem(@summary.monthly_total_cents, 100)]) |> IO.iodata_to_binary()}
              <% end %>
            </.kv>
          </dl>

          <%= if @summary.plan == "free" and Permissions.can?(assigns, :manage_billing) do %>
            <.button phx-click="upgrade" phx-value-plan="team" class="mt-6 w-full">
              Upgrade to Team
            </.button>
          <% end %>
        </.card>

        <.card class="lg:col-span-2">
          <.section_header title="Plans" />

          <div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-3">
            <div
              :for={plan <- @plans}
              class={[
                "relative flex flex-col rounded-lg border p-5",
                if(current_plan?(plan, @summary),
                  do: "border-indigo-500/40 bg-indigo-500/5",
                  else: "border-zinc-900 bg-zinc-950/40"
                )
              ]}
            >
              <div class="flex items-center justify-between gap-2">
                <h3 class="text-lg font-semibold text-zinc-100">{plan.name}</h3>
                <%= cond do %>
                  <% current_plan?(plan, @summary) -> %>
                    <span class="rounded bg-indigo-500/20 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-indigo-200 ring-1 ring-indigo-500/30">
                      Current plan
                    </span>
                  <% plan.key == "team" -> %>
                    <span class="rounded bg-amber-500/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-200 ring-1 ring-amber-500/30">
                      Most popular
                    </span>
                  <% true -> %>
                <% end %>
              </div>

              <p class="mt-2 text-sm text-zinc-400">{price_label(plan)}</p>

              <ul class="mt-4 flex-1 space-y-2 text-xs text-zinc-300">
                <li :for={f <- plan.features} class="flex items-start gap-2">
                  <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-indigo-400" />
                  <span>{f}</span>
                </li>
              </ul>

              <div class="mt-5">
                <%= cond do %>
                  <% current_plan?(plan, @summary) -> %>
                    <span class="block w-full rounded-lg bg-zinc-900 px-3 py-2 text-center text-xs font-medium text-zinc-400">
                      You're here
                    </span>
                  <% plan.key == "enterprise" -> %>
                    <button
                      phx-click="contact_sales"
                      class="block w-full rounded-lg border border-zinc-700 px-3 py-2 text-center text-xs font-semibold text-zinc-200 hover:bg-zinc-900"
                    >
                      Contact sales
                    </button>
                  <% Permissions.can?(assigns, :manage_billing) -> %>
                    <button
                      phx-click="upgrade"
                      phx-value-plan={plan.key}
                      class="block w-full rounded-lg bg-indigo-500 px-3 py-2 text-center text-xs font-semibold text-zinc-950 hover:bg-indigo-400"
                    >
                      Upgrade to {plan.name}
                    </button>
                  <% true -> %>
                    <span class="block w-full rounded-lg bg-zinc-900 px-3 py-2 text-center text-xs font-medium text-zinc-500">
                      Owners only
                    </span>
                <% end %>
              </div>
            </div>
          </div>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end
end
