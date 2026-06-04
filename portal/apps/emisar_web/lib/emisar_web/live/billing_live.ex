defmodule EmisarWeb.BillingLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Billing}
  alias EmisarWeb.Permissions

  @plan_order ["free", "team", "enterprise"]

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Billing", loading?: not connected?(socket))

    if connected?(socket) do
      account = socket.assigns.current_account

      {:ok,
       socket
       |> assign(:plans, ordered_plans())
       |> assign(:summary, fetch_summary(account, socket.assigns.current_subject))
       |> assign(:member_count, member_count(socket))}
    else
      {:ok, socket}
    end
  end

  defp fetch_summary(account, subject) do
    case Billing.billing_summary(account, subject) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  def handle_event("upgrade", %{"plan" => plan}, socket) do
    Permissions.gated(socket, :manage_billing, fn s ->
      if plan in @plan_order do
        case Billing.start_checkout(s.assigns.current_account, plan, s.assigns.current_subject) do
          {:ok, url} ->
            {:noreply, redirect(s, external: url)}

          {:error, reason} ->
            {:noreply,
             put_flash(s, :error, "Could not start checkout: #{humanize_reason(reason)}")}
        end
      else
        {:noreply, put_flash(s, :error, "Unknown plan.")}
      end
    end)
  end

  def handle_event("contact_sales", _params, socket) do
    {:noreply,
     put_flash(socket, :info, "We'll be in touch — email sales@emisar.dev to chat sooner.")}
  end

  def handle_event("manage_billing", _params, socket) do
    Permissions.gated(socket, :manage_billing, fn s ->
      case Billing.open_billing_portal(s.assigns.current_account, s.assigns.current_subject) do
        {:ok, url} ->
          {:noreply, redirect(s, external: url)}

        {:error, :no_customer} ->
          {:noreply,
           put_flash(
             s,
             :error,
             "No Paddle customer yet — upgrade to a paid plan first, then come back to manage billing."
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(s, :error, "Could not open billing portal: #{humanize_reason(reason)}")}
      end
    end)
  end

  defp ordered_plans do
    all = Billing.plans()

    Enum.map(@plan_order, fn key ->
      def_map = Map.fetch!(all, key)
      Map.put(def_map, :key, key)
    end)
  end

  defp member_count(socket) do
    case Accounts.list_memberships_for_account(socket.assigns.current_subject, page: [limit: 100]) do
      {:ok, _list, %{count: count}} when is_integer(count) -> count
      _ -> 0
    end
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

  # Formats a monthly total in cents as a clean dollar string. The
  # inline `:io_lib.format(...) |> IO.iodata_to_binary()` it replaces
  # buried the actual rendering logic inside a HEEx template.
  defp format_total(nil), do: "Custom"
  defp format_total(0), do: "$0"

  defp format_total(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    pennies = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(Integer.to_string(pennies), 2, "0")}"
  end

  # Returns 0..100 percent of `numerator / denominator`, capped at 100.
  # `nil` denominator means unlimited → return nil so the bar isn't
  # rendered.
  defp usage_pct(_n, nil), do: nil
  defp usage_pct(_n, :unlimited), do: nil
  defp usage_pct(0, _), do: 0

  defp usage_pct(n, limit) when is_integer(limit) and limit > 0,
    do: min(100, round(n * 100 / limit))

  defp usage_pct(_, _), do: nil

  defp usage_class(pct) when is_integer(pct) do
    cond do
      pct >= 100 -> "bg-rose-400"
      pct >= 80 -> "bg-amber-400"
      true -> "bg-indigo-400"
    end
  end

  defp usage_class(_), do: "bg-indigo-400"

  defp humanize_reason(reason) when is_binary(reason), do: reason

  defp humanize_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp humanize_reason(_), do: "unknown error"

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:billing}
    >
      <:title>Billing</:title>

      <.loading_state :if={@loading?} />

      <.page_container :if={not @loading?} max="6xl">
        <%!-- Current-plan strip across the top. Plan name + price on
             the left, three usage bars on the right. Replaces a tall
             narrow sidebar card that wasted the page real estate. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <div class="text-xs font-medium uppercase tracking-wider text-zinc-500">
                Current plan
              </div>
              <div class="mt-1 flex items-baseline gap-2">
                <span class="text-2xl font-semibold text-zinc-50">{@summary.plan_name}</span>
                <span class="text-sm text-zinc-500">·</span>
                <span class="text-sm text-zinc-400">
                  {format_total(@summary.monthly_total_cents)}/mo
                </span>
                <span class="text-sm text-zinc-500">·</span>
                <span class="text-sm text-zinc-400">
                  {@summary.audit_retention_days}d audit retention
                </span>
              </div>
              <%!-- Subscription cycle notes — only rendered when the
                   underlying Paddle subscription has the matching state.
                   Cancel-at-period-end is the loud case (you keep your
                   plan until the date, then revert to free); trial_end
                   shows during trial; current_period_end always shows
                   on a paid plan so the operator knows "next charge
                   on …". --%>
              <div class="mt-2 flex flex-wrap items-center gap-2 text-xs">
                <span
                  :if={@summary.cancel_at_period_end == true and @summary.current_period_end}
                  class="rounded bg-amber-500/15 px-2 py-0.5 font-medium text-amber-200 ring-1 ring-amber-500/30"
                >
                  Cancels on <.local_time value={@summary.current_period_end} class="inline" />
                </span>
                <span
                  :if={@summary.trial_end}
                  class="rounded bg-indigo-500/15 px-2 py-0.5 font-medium text-indigo-200 ring-1 ring-indigo-500/30"
                >
                  Trial ends <.local_time value={@summary.trial_end} class="inline" />
                </span>
                <span
                  :if={@summary.current_period_end && @summary.cancel_at_period_end != true}
                  class="text-zinc-500"
                >
                  Next charge <.local_time value={@summary.current_period_end} class="inline" />
                </span>
              </div>
            </div>

            <button
              :if={@summary.plan == "free" and Permissions.can?(assigns, :manage_billing)}
              phx-click="upgrade"
              phx-value-plan="team"
              class="rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
            >
              Upgrade to Team
            </button>
            <%!-- "Manage subscription" surfaces the Paddle Customer
                 Portal — invoices, payment method, plan change,
                 cancellation. Available once the account has a
                 Paddle customer attached (any paid plan or
                 previous paid plan). --%>
            <button
              :if={@current_account.paddle_customer_id && Permissions.can?(assigns, :manage_billing)}
              phx-click="manage_billing"
              class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-800 px-4 py-2 text-sm font-medium text-zinc-200 hover:bg-zinc-900"
            >
              <.icon name="hero-credit-card" class="h-4 w-4" /> Manage subscription
            </button>
          </div>

          {runner_limit = plan_limit(@plans, @summary.plan, :runners_limit)}
          {member_limit = plan_limit(@plans, @summary.plan, :members_limit)}

          <div class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.usage_meter
              label="Runners"
              count={@summary.runner_count}
              limit_label={limit_label(runner_limit)}
              pct={usage_pct(@summary.runner_count, runner_limit)}
            />
            <.usage_meter
              label="Team members"
              count={@member_count}
              limit_label={limit_label(member_limit)}
              pct={usage_pct(@member_count, member_limit)}
            />
          </div>
        </section>

        <%!-- Plan cards. Three across on desktop, single column on
             phones. Current plan visually pinned, popular plan
             highlighted with a ribbon. --%>
        <section>
          <h2 class="mb-3 text-sm font-semibold text-zinc-100">Plans</h2>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
            <article
              :for={plan <- @plans}
              class={[
                "relative flex flex-col rounded-xl border p-5",
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
                      Current
                    </span>
                  <% plan.key == "team" -> %>
                    <span class="rounded bg-amber-500/15 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-200 ring-1 ring-amber-500/30">
                      Most popular
                    </span>
                  <% true -> %>
                    <span></span>
                <% end %>
              </div>

              <p class="mt-2 text-sm text-zinc-400">{price_label(plan)}</p>

              <ul class="mt-4 flex-1 space-y-2 text-xs text-zinc-300">
                <li :for={f <- plan.features} class="flex items-start gap-2">
                  <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-indigo-400" />
                  <span class="leading-relaxed">{f}</span>
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
            </article>
          </div>
        </section>
      </.page_container>
    </.dashboard_shell>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :limit_label, :string, required: true
  attr :pct, :integer, default: nil

  defp usage_meter(assigns) do
    ~H"""
    <div>
      <div class="flex items-baseline justify-between text-xs">
        <span class="text-zinc-400">{@label}</span>
        <span class="font-medium text-zinc-200">
          {@count} <span class="text-zinc-500">/ {@limit_label}</span>
        </span>
      </div>
      <div :if={@pct} class="mt-2 h-1.5 overflow-hidden rounded-full bg-zinc-900">
        <div class={["h-full transition-all", usage_class(@pct)]} style={"width: #{@pct}%"}></div>
      </div>
      <div
        :if={is_nil(@pct)}
        class="mt-2 h-1.5 rounded-full bg-gradient-to-r from-indigo-900/30 via-indigo-500/40 to-indigo-900/30"
      >
      </div>
    </div>
    """
  end
end
