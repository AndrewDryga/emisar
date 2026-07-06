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
       |> assign(:invoices, fetch_invoices(account, socket.assigns.current_subject))
       |> assign(:member_count, member_count(socket))
       |> assign(:features, feature_states(account))}
    else
      {:ok, socket}
    end
  end

  # The plan's gated feature entitlements (Paddle custom_data overrides, else the
  # plan-tier default) — rendered as an enabled/disabled list beside usage.
  defp feature_states(account) do
    %{
      sso: Billing.sso_available?(account),
      scim: Billing.directory_sync_available?(account),
      audit_export: Billing.audit_export_available?(account)
    }
  end

  defp fetch_summary(account, subject) do
    case Billing.billing_summary(account, subject) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  # Recent invoices for the payment-history list — [] on any error (a Paddle
  # hiccup shouldn't take the page down; the portal link still works).
  defp fetch_invoices(account, subject) do
    case Billing.list_recent_invoices(account, subject) do
      {:ok, invoices} -> invoices
      {:error, _} -> []
    end
  end

  def handle_event("upgrade", %{"plan" => plan}, socket) do
    Permissions.gated(
      socket,
      Billing.subject_can_manage_billing?(socket.assigns.current_subject),
      fn socket ->
        if plan in @plan_order do
          case Billing.start_checkout(
                 socket.assigns.current_account,
                 plan,
                 socket.assigns.current_subject
               ) do
            {:ok, url} ->
              {:noreply, redirect(socket, external: url)}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Could not start checkout: #{humanize_reason(reason)}")}
          end
        else
          {:noreply, put_flash(socket, :error, "Unknown plan.")}
        end
      end
    )
  end

  def handle_event("contact_sales", _params, socket) do
    {:noreply,
     put_flash(socket, :info, "We'll be in touch — email sales@emisar.dev to chat sooner.")}
  end

  def handle_event("manage_billing", _params, socket) do
    Permissions.gated(
      socket,
      Billing.subject_can_manage_billing?(socket.assigns.current_subject),
      fn socket ->
        case Billing.open_billing_portal(
               socket.assigns.current_account,
               socket.assigns.current_subject
             ) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, :no_customer} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "No Paddle customer yet — upgrade to a paid plan first, then come back to manage billing."
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not open billing portal: #{humanize_reason(reason)}"
             )}
        end
      end
    )
  end

  defp ordered_plans do
    all = Billing.plans()

    Enum.map(@plan_order, fn key ->
      def_map = Map.fetch!(all, key)
      Map.put(def_map, :key, key)
    end)
  end

  defp member_count(socket) do
    case Accounts.list_memberships_for_account(
           socket.assigns.current_account,
           socket.assigns.current_subject,
           page: [limit: 100]
         ) do
      {:ok, _list, %{count: count}} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp limit_label(:unlimited), do: "Unlimited"
  defp limit_label(n) when is_integer(n), do: Integer.to_string(n)
  defp limit_label(_), do: "—"

  defp price_label(%{monthly_price_cents: nil}), do: "Custom pricing"
  defp price_label(%{monthly_price_cents: 0}), do: "$0"

  defp price_label(%{monthly_price_cents: cents}),
    do: "$#{div(cents, 100)} / runner / month"

  defp current_plan?(%{key: key}, %{plan: current}), do: key == current

  # Tier position in @plan_order so a card can tell an upgrade from a downgrade
  # (an unknown/legacy plan ranks last so a card never mislabels it an "upgrade").
  defp plan_rank(key) when is_binary(key), do: Enum.find_index(@plan_order, &(&1 == key)) || -1

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

  # Only the non-paid statuses earn a label chip (a completed row stays silent).
  defp invoice_status_label("billed"), do: "Billed"
  defp invoice_status_label("past_due"), do: "Past due"
  defp invoice_status_label(status), do: String.capitalize(status)

  # Returns 0..100 percent of `numerator / denominator`, capped at 100.
  # `nil` denominator means unlimited → return nil so the bar isn't
  # rendered.
  defp usage_pct(_n, nil), do: nil
  defp usage_pct(_n, :unlimited), do: nil
  defp usage_pct(0, _), do: 0

  defp usage_pct(n, limit) when is_integer(limit) and limit > 0,
    do: min(100, round(n * 100 / limit))

  defp usage_pct(_, _), do: nil

  # AT/near capacity is a plan fact, not a failure — amber says "look at your
  # limits"; rose would cry lockout (and the pct clamps at 100, so a true
  # over-limit never renders anyway).
  defp usage_class(pct) when is_integer(pct) and pct >= 80, do: "bg-amber-400"
  defp usage_class(pct) when is_integer(pct), do: "bg-brand-400"

  defp usage_class(_), do: "bg-brand-400"

  defp humanize_reason(reason) when is_binary(reason), do: reason

  defp humanize_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp humanize_reason(_), do: "unknown error"

  # mailto for a billing support request — prefilled subject carrying the
  # account name so support can route it without a round-trip. General enough
  # for any plan (the aside "Contact support" link and the Enterprise note).
  defp support_mailto(account) do
    subject = URI.encode("Billing question — #{account.name}")
    "mailto:support@emisar.dev?subject=#{subject}"
  end

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:billing}
      width={:table}
    >
      <:title>Billing</:title>

      <.page_intro>
        Your plan and usage against its limits.
        <.doc_link href="/pricing#compare">Compare plans</.doc_link>
      </.page_intro>

      <.loading_state :if={@loading?} />

      <%!-- billing_summary/2 can return {:error, _} (→ nil); never deref a
           nil @summary into a white screen — show a load-error state and a
           reload. This is on us, not the operator's payment. --%>
      <.empty_state
        :if={not @loading? and is_nil(@summary)}
        tone={:danger}
        icon="hero-exclamation-triangle"
        title="Couldn't load billing"
      >
        Something went wrong loading your plan and usage — this is on our side,
        not a problem with your payment. Try again in a moment.
        <:cta navigate={~p"/app/#{@current_account}/settings/billing"}>Reload</:cta>
      </.empty_state>

      <div :if={not @loading? and not is_nil(@summary)} class="space-y-6">
        <.subscription_banner status={@summary.subscription_status}>
          <:cta :if={Billing.subject_can_manage_billing?(@current_subject)}>
            <.button
              variant={:secondary}
              size={:sm}
              class="shrink-0"
              phx-click="manage_billing"
              phx-disable-with="Opening portal…"
            >
              Manage billing
            </.button>
          </:cta>
        </.subscription_banner>
        <%!-- Current-plan strip on the canvas: plan facts + self-serve money
             actions in the wide left column; the usage meters (current limits)
             and a help/support aside on the right — the create-page helper-rail
             grammar, so "what you have / what you're using / who to ask" read in
             one row. --%>
        <section class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
          <div class="space-y-8 lg:col-span-3">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                  Current plan
                </div>
                <div class="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <span class="text-2xl font-semibold text-zinc-50">{@summary.plan_name}</span>
                  <span class="text-sm text-zinc-500">·</span>
                  <span class="text-sm text-zinc-400">
                    {format_total(@summary.monthly_total_cents)}/mo
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
                  <.chip
                    :if={@summary.cancel_at_period_end == true and @summary.current_period_end}
                    tone={:amber}
                  >
                    Cancels on <.local_time value={@summary.current_period_end} class="inline" />
                  </.chip>
                  <.chip :if={@summary.trial_end} tone={:brand}>
                    Trial ends <.local_time value={@summary.trial_end} class="inline" />
                  </.chip>
                  <span
                    :if={@summary.current_period_end && @summary.cancel_at_period_end != true}
                    class="text-zinc-500"
                  >
                    Next charge <.local_time value={@summary.current_period_end} class="inline" />
                  </span>
                </div>
              </div>

              <%!-- Manage subscription only — the plan CARDS below own
                 upgrade/downgrade, so the strip never duplicates them. Surfaces
                 the Paddle Customer Portal (invoices, payment method, plan
                 change, cancellation) once a Paddle customer is attached. --%>
              <div class="flex flex-wrap gap-2">
                <.button
                  :if={
                    @current_account.paddle_customer_id &&
                      Billing.subject_can_manage_billing?(@current_subject)
                  }
                  variant={:secondary}
                  phx-click="manage_billing"
                  phx-disable-with="Opening portal…"
                  icon="hero-credit-card"
                >
                  Manage subscription
                </.button>
              </div>
            </div>

            <%!-- Recent invoices — a payment history inline, so operators don't
                 open the portal just to check the last charge. Manage subscription
                 still owns the full ledger + PDF downloads. A paid row is silent
                 (no green "Paid" chip); only past-due earns a tone. --%>
            <section :if={@invoices != []}>
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Recent invoices
              </h3>
              <ul class="mt-3 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
                <li
                  :for={invoice <- @invoices}
                  class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3 text-sm"
                >
                  <.local_time
                    :if={invoice.billed_at}
                    value={invoice.billed_at}
                    class="w-28 shrink-0 text-zinc-400"
                  />
                  <span class="font-medium tabular-nums text-zinc-200">
                    {format_total(invoice.amount_cents)}
                  </span>
                  <span :if={invoice.invoice_number} class="font-mono text-xs text-zinc-500">
                    {invoice.invoice_number}
                  </span>
                  <.chip
                    :if={invoice.status != "completed"}
                    class="ml-auto"
                    tone={if invoice.status == "past_due", do: :rose, else: :neutral}
                  >
                    {invoice_status_label(invoice.status)}
                  </.chip>
                </li>
              </ul>
            </section>

            <%!-- Enterprise is a custom, sales-led plan (no self-serve price), so
               plan + billing changes go through our team. The icon-caps-a-spine
               grammar (event_block) — a vertical line drops from the lifebuoy —
               marks it a standing posture note; the action is the aside's
               "Contact support". --%>
            <.event_block
              :if={@summary.plan == "enterprise"}
              icon="hero-lifebuoy"
              tone={:neutral}
              title="Custom Enterprise plan"
              class="max-w-prose"
            >
              <:body>
                Your plan and billing are handled with our team, not self-serve. Contact support to
                change your plan, ask about an invoice, or cancel — we'll take care of it.
              </:body>
            </.event_block>

            <%!-- Plans sit in the main column (not full width under the rail).
                 Picking a plan is the choice_cards concept — the current plan
                 takes the selected treatment (bright ring), the rest quiet. --%>
            <section>
              <.section_header title="Plans" />
              <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                <%!-- ONE card style for every plan — identity ("current") and merch
                 ("most popular") are the CHIPS' job; per-plan border treatments
                 read as three different products. --%>
                <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — the choice-card recipe (pick-a-plan grid; current = selected ring) --%>
                <article
                  :for={plan <- @plans}
                  class={[
                    "relative flex flex-col rounded-lg p-5",
                    if(current_plan?(plan, @summary),
                      do: "bg-white/[0.04] ring-2 ring-brand-400/70",
                      else: "bg-black/20 ring-1 ring-zinc-800"
                    )
                  ]}
                >
                  <div class="flex items-center justify-between gap-2">
                    <h3 class="text-lg font-semibold text-zinc-100">{plan.name}</h3>
                    <.chip :if={current_plan?(plan, @summary)} tone={:neutral}>current</.chip>
                    <%!-- Upsell merch only reads as such BELOW the badged plan —
                     a customer already above it gets silence. --%>
                    <.chip :if={plan.key == "team" and plan_rank("team") > plan_rank(@summary.plan)}>
                      most popular
                    </.chip>
                  </div>

                  <p class="mt-2 text-sm text-zinc-400">{price_label(plan)}</p>

                  <ul class="mt-4 flex-1 space-y-2 text-xs text-zinc-300">
                    <li :for={f <- plan.features} class="flex items-start gap-2">
                      <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                      <span class="leading-relaxed">{f}</span>
                    </li>
                  </ul>

                  <%!-- No footer on the current plan: the chip + bright ring already
                   say it — a disabled "You're here" button was a fake affordance. --%>
                  <div :if={not current_plan?(plan, @summary)} class="mt-5">
                    <%= cond do %>
                      <% plan.key == "enterprise" -> %>
                        <.button
                          variant={:secondary}
                          size={:md}
                          class="w-full"
                          phx-click="contact_sales"
                        >
                          Contact sales
                        </.button>
                      <% not Billing.subject_can_manage_billing?(@current_subject) -> %>
                        <%!-- Quiet fact for non-owners, not a gray slab that apes a
                         disabled button. --%>
                        <p class="py-2 text-center text-xs font-medium text-zinc-500">Owners only</p>
                      <% @summary.plan == "enterprise" -> %>
                        <%!-- On a custom Enterprise plan every other tier is a downgrade,
                         and there's no self-serve path off it — the note above
                         carries the one real action (contact support). --%>
                        <.button
                          variant={:secondary}
                          size={:md}
                          class="w-full"
                          href={support_mailto(@current_account)}
                        >
                          Contact support to switch
                        </.button>
                      <% plan_rank(plan.key) > plan_rank(@summary.plan) -> %>
                        <.button
                          size={:md}
                          class="w-full"
                          phx-click="upgrade"
                          phx-value-plan={plan.key}
                          phx-disable-with="Starting checkout…"
                        >
                          Upgrade to {plan.name}
                        </.button>
                      <% true -> %>
                        <%!-- Lower tier than the current plan — a downgrade. A downgrade
                         isn't a checkout (that would open a second subscription); plan
                         changes + cancellations live in the Paddle customer portal, so
                         route there instead of mislabeling it "Upgrade to Free". --%>
                        <.button
                          variant={:secondary}
                          size={:md}
                          class="w-full"
                          phx-click="manage_billing"
                          phx-disable-with="Opening portal…"
                        >
                          Downgrade to {plan.name}
                        </.button>
                    <% end %>
                  </div>
                </article>
              </div>
            </section>
          </div>

          <%!-- Right rail — current limits, plan features, and where to get help
             (the create-page helper-column grammar), no framing line. --%>
          <aside class="space-y-8">
            <div>
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Usage
              </h3>
              <%!-- The summary limits are entitlement-aware (Paddle product
                 custom_data overrides the compiled plan defaults) — never
                 re-derive them from the plans map by name. --%>
              <div class="mt-4 space-y-4">
                <.usage_meter
                  label="Runners"
                  count={@summary.runner_count}
                  limit_label={limit_label(@summary.runner_limit)}
                  pct={usage_pct(@summary.runner_count, @summary.runner_limit)}
                />
                <.usage_meter
                  label="Team members"
                  count={@member_count}
                  limit_label={limit_label(@summary.member_limit)}
                  pct={usage_pct(@member_count, @summary.member_limit)}
                />
                <%!-- Audit retention is a plan cap too, but a duration not a
                     count — a plain key/value row in the same rail as the meters. --%>
                <div class="flex items-baseline justify-between text-xs">
                  <span class="text-zinc-400">Audit retention</span>
                  <span class="font-medium text-zinc-200">
                    {@summary.audit_retention_days} days
                  </span>
                </div>
              </div>
            </div>
            <div>
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Features
              </h3>
              <%!-- Plan-gated features (entitlement-aware) — what this plan turns on. --%>
              <ul class="mt-4 space-y-2 text-sm">
                <.feature_line enabled={@features.sso} label="Single sign-on (OIDC)" />
                <.feature_line enabled={@features.scim} label="SCIM directory sync" />
                <.feature_line enabled={@features.audit_export} label="Audit export (CSV + SIEM)" />
              </ul>
            </div>
            <div>
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
                Need help?
              </h3>
              <p class="mt-3 text-sm leading-relaxed text-zinc-400">
                Questions about your plan, an invoice, or your limits? Our team can help — and can set
                up a custom plan if you're outgrowing these.
              </p>
              <a
                href={support_mailto(@current_account)}
                class="mt-3 inline-flex items-center gap-1 text-sm font-medium text-brand-400 hover:text-brand-300"
              >
                Contact support <.icon name="hero-arrow-right" class="h-3.5 w-3.5" />
              </a>
            </div>
          </aside>
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  attr :enabled, :boolean, required: true
  attr :label, :string, required: true

  # One plan-feature line in the billing rail: a check when the plan turns it
  # on, a muted dash when it doesn't.
  defp feature_line(assigns) do
    ~H"""
    <li class="flex items-center gap-2">
      <.icon
        name={if @enabled, do: "hero-check-circle-mini", else: "hero-minus-circle-mini"}
        class={"h-4 w-4 flex-none " <> if(@enabled, do: "text-brand-400", else: "text-zinc-600")}
      />
      <span class={(@enabled && "text-zinc-300") || "text-zinc-500"}>{@label}</span>
    </li>
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
      <%!-- A progress bar only when there's a numeric cap to show progress
           against. "Unlimited" has no progress, so no bar — an empty/full bar
           there is meaningless; the "N / Unlimited" count above says it all. --%>
      <div :if={@pct} class="mt-2 h-1.5 overflow-hidden rounded-full bg-zinc-900">
        <div class={["h-full transition-[width]", usage_class(@pct)]} style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end
end
