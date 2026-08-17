defmodule EmisarWeb.BillingLive do
  use EmisarWeb, :live_view
  alias Emisar.Billing
  alias EmisarWeb.{MailTo, Permissions}

  @plan_order ["free", "team", "enterprise"]

  def mount(_params, _session, socket) do
    socket =
      assign(socket, page_title: "Billing", loading?: not connected?(socket), cycle: :month)

    if connected?(socket) do
      account = socket.assigns.current_account
      subject = socket.assigns.current_subject

      {:ok,
       socket
       |> assign(:plans, ordered_plans())
       |> assign(:summary, fetch_summary(account, subject))
       |> assign(:features, feature_states(account))
       |> assign_invoices(account, subject)}
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

  # A member who may not read the ledger never fires its read, so the assign
  # never exists — the section is `:if`-gated on the same predicate, exactly as
  # the dead render leaves it unassigned. Firing it anyway would render the
  # context's refusal as this section's failure state, which reads as an outage
  # rather than "not yours".
  defp assign_invoices(socket, account, subject) do
    if Billing.subject_can_view_invoices?(subject) do
      assign_async(socket, :invoices, fn -> fetch_invoices(account, subject) end)
    else
      socket
    end
  end

  defp fetch_summary(account, subject) do
    case Billing.billing_summary(account, subject) do
      {:ok, summary} -> summary
      {:error, _} -> nil
    end
  end

  # Recent invoices for the payment-history list, fetched off the mount path
  # (IL-18) — a slow Paddle response must not hold up the first paint. A
  # failure renders as the section's inline retry state; the rest of the
  # page (and the portal link) still works.
  defp fetch_invoices(account, subject) do
    case Billing.list_recent_invoices(account, subject) do
      {:ok, invoices} -> {:ok, %{invoices: invoices}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Pure UI state — flips the plan cards between monthly and annual pricing;
  # the chosen cycle rides on the Upgrade click, so no re-fetch here.
  def handle_event("set_cycle", %{"cycle" => cycle}, socket) do
    {:noreply, assign(socket, :cycle, parse_cycle(cycle))}
  end

  def handle_event("upgrade", %{"plan" => plan} = params, socket) do
    Permissions.gated(
      socket,
      Billing.subject_can_manage_billing?(socket.assigns.current_subject),
      fn socket ->
        if plan in @plan_order do
          case Billing.start_checkout(
                 socket.assigns.current_account,
                 plan,
                 parse_cycle(params["cycle"]),
                 socket.assigns.current_subject
               ) do
            {:ok, url} ->
              {:noreply, redirect(socket, external: url)}

            {:error, :subscription_already_active} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "This account already has a subscription. Use Manage billing to change plans."
               )}

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

  # Download one invoice's PDF — Billing re-checks the transaction against the
  # account's own invoices + manage-billing, then Paddle mints a short-lived
  # signed URL we redirect to (it's served as a download, so the page stays put).
  def handle_event("download_invoice", %{"id" => id}, socket) do
    case Billing.invoice_pdf_url(
           socket.assigns.current_account,
           id,
           socket.assigns.current_subject
         ) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't open that invoice: #{humanize_reason(reason)}")}
    end
  end

  # Re-run the failed async invoice fetch in place. Authorization lives in
  # the context read (manage-billing + account scope), same as the mount fetch.
  def handle_event("retry_invoices", _params, socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject

    {:noreply, assign_invoices(socket, account, subject)}
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

  # Whitelist the cycle off the client (IL-14) — anything but "year" is monthly.
  defp parse_cycle("year"), do: :year
  defp parse_cycle(_), do: :month

  defp price_label(%{monthly_price_cents: nil}, _cycle), do: "Custom pricing"
  defp price_label(%{monthly_price_cents: 0}, _cycle), do: "$0"

  defp price_label(%{annual_price_cents: cents}, :year) when is_integer(cents),
    do: "$#{div(cents, 100)} / runner / year"

  defp price_label(%{monthly_price_cents: cents}, :month),
    do: "$#{div(cents, 100)} / runner / month"

  # "N months free" on the annual cycle when it beats 12× monthly; nil for
  # free/enterprise or any plan whose annual price carries no discount.
  defp savings_note(%{monthly_price_cents: m, annual_price_cents: a})
       when is_integer(m) and m > 0 and is_integer(a) and a > 0 and a < m * 12,
       do: "#{12 - div(a, m)} months free"

  defp savings_note(_plan), do: nil

  defp current_plan?(%{key: key}, %{plan: current}), do: key == current

  # Tier position in @plan_order so a card can tell an upgrade from a downgrade.
  # An unknown plan ranks ABOVE every known one: the only way to hold one is a
  # slug minted in Paddle for a custom deal, which `billing_summary` already
  # treats as custom pricing rather than free's $0. Ranking it -1 put it *below*
  # free and inverted every comparison, so an enterprise customer was offered
  # "Upgrade to Free".
  defp plan_rank(key) when is_binary(key),
    do: Enum.find_index(@plan_order, &(&1 == key)) || length(@plan_order)

  # A plan with no self-serve path off it: Enterprise, and any slug this build
  # doesn't know — the only way to hold one is a custom deal minted in Paddle,
  # which is sales-led by definition. Both send the operator to support rather
  # than offering a checkout that `start_checkout` would refuse anyway.
  defp sales_led_plan?(plan) when is_binary(plan), do: plan_rank(plan) >= plan_rank("enterprise")

  # Formats a total in the currency's minor unit. Paddle bills in the customer's
  # local currency, so both the subscription summary and each invoice carry their
  # own code — hardcoding "$" printed a EUR amount as dollars.
  #
  # Never called with nil: `period_price_label` answers "Custom" for a plan with
  # no self-serve price, and the invoice row renders an em-dash for an amount
  # Paddle sent in a shape we could not read. The two mean different things, so
  # neither belongs in here.
  defp format_total(0, currency), do: "#{currency_symbol(currency)}0"

  defp format_total(cents, currency) when is_integer(cents) do
    major = div(cents, 100)
    minor = rem(cents, 100)

    "#{currency_symbol(currency)}#{major}.#{String.pad_leading(Integer.to_string(minor), 2, "0")}"
  end

  # Symbols for the currencies we sell in; anything else prints its ISO code so
  # the number is labeled correctly rather than plausibly.
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(code) when is_binary(code) and code != "USD", do: code <> " "
  defp currency_symbol(_), do: "$"

  # The current-plan strip price, cadence-aware: the annual subscriber reads
  # "$X/yr" at the annual rate, monthly "$X/mo", and a custom (unknown-price)
  # plan just "Custom" — no bare "Custom/mo" suffix.
  defp period_price_label(%{period_total_cents: nil}), do: "Custom"

  defp period_price_label(%{
         period_total_cents: cents,
         currency_code: currency,
         billing_interval: :year
       }),
       do: "#{format_total(cents, currency)}/yr"

  defp period_price_label(%{period_total_cents: cents, currency_code: currency}),
    do: "#{format_total(cents, currency)}/mo"

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

  # Billing mailto context rides the authed page assigns so support can route
  # the request without asking which account or user sent it.
  defp billing_support_mailto(account, user) do
    context = MailTo.context(%{current_account: account, current_user: user})

    MailTo.support(
      subject: "Billing question - #{account.name}",
      context: context
    )
  end

  defp enterprise_sales_mailto(account, user) do
    context = MailTo.context(%{current_account: account, current_user: user})

    MailTo.sales(
      subject: "Enterprise plan - #{account.name}",
      context: context
    )
  end

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
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
        Your plan sets this account's limits — how many runners connect, how long the audit log is
        kept, and which features are on. Track usage against them, change plan, and manage payment
        here. <.doc_link href="/pricing#compare">Compare plans</.doc_link>
        <.doc_link href={~p"/docs/billing"}>Billing docs</.doc_link>
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
                <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                  Current plan
                </div>
                <div class="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <span class="text-2xl font-semibold text-zinc-50">{@summary.plan_name}</span>
                  <span class="text-sm text-zinc-500">·</span>
                  <span class="text-sm text-zinc-400">{period_price_label(@summary)}</span>
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
                    Cancels on
                    <.local_time
                      id="billing-cancels-on"
                      value={@summary.current_period_end}
                      class="inline"
                    />
                  </.chip>
                  <.chip :if={@summary.trial_end} tone={:brand}>
                    Trial ends
                    <.local_time id="billing-trial-ends" value={@summary.trial_end} class="inline" />
                  </.chip>
                  <span
                    :if={@summary.current_period_end && @summary.cancel_at_period_end != true}
                    class="text-zinc-400"
                  >
                    Next charge
                    <.local_time
                      id="billing-next-charge"
                      value={@summary.current_period_end}
                      class="inline"
                    />
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
                 (no green "Paid" chip); only past-due earns a tone. Loaded async
                 off the mount path (IL-18); loading/failed chrome renders only
                 once a Paddle customer exists — a never-billed account resolves
                 to [] instantly, and a flash of "Recent invoices" that then
                 vanishes would just jiggle the page. --%>
            <%!-- The ledger is money, not operations: an operator reading their
                 plan and limits above has no business in what the company paid
                 and when, while an admin answers for what the account spends.
                 Gated on the same `view_invoices` the context read enforces —
                 the section is hidden because there is nothing to show, not to
                 hide a control that would work. --%>
            <.async_result
              :let={invoices}
              :if={Billing.subject_can_view_invoices?(@current_subject)}
              assign={@invoices}
            >
              <:loading>
                <section :if={@current_account.paddle_customer_id}>
                  <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                    Recent invoices
                  </h3>
                  <p class="mt-3 flex items-center gap-2 text-sm text-zinc-400">
                    <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" />
                    Loading payment history…
                  </p>
                </section>
              </:loading>
              <:failed>
                <.event_block
                  icon="hero-exclamation-triangle"
                  tone={:rose}
                  title="Couldn't load recent invoices"
                  class="max-w-prose"
                >
                  <:body>
                    Something went wrong loading your payment history — this is on our
                    side, not a problem with your payment.
                  </:body>
                  <.button
                    variant={:secondary}
                    size={:sm}
                    class="mt-4"
                    phx-click="retry_invoices"
                    phx-disable-with="Loading…"
                  >
                    Try again
                  </.button>
                </.event_block>
              </:failed>
              <section :if={invoices != []}>
                <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                  Recent invoices
                </h3>
                <ul class="mt-3 divide-y divide-zinc-800/70 border-t border-zinc-800/70">
                  <li
                    :for={invoice <- invoices}
                    class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3 text-sm"
                  >
                    <.local_time
                      :if={invoice.billed_at}
                      id={"invoice-billed-#{invoice.id}"}
                      value={invoice.billed_at}
                      class="w-36 shrink-0 whitespace-nowrap text-zinc-400"
                    />
                    <%!-- An amount Paddle sent in a shape we could not read is an
                         em-dash, not "Custom" (which means a sales-led price on a
                         plan card) and certainly not "$0.00". --%>
                    <span class="w-16 font-medium tabular-nums text-zinc-200">
                      {if invoice.amount_cents,
                        do: format_total(invoice.amount_cents, invoice.currency),
                        else: "—"}
                    </span>
                    <span :if={invoice.invoice_number} class="font-mono text-xs text-zinc-400">
                      {invoice.invoice_number}
                    </span>
                    <div class="ml-auto flex items-center gap-4">
                      <.chip
                        :if={invoice.status != "completed"}
                        tone={if invoice.status == "past_due", do: :rose, else: :neutral}
                      >
                        {invoice_status_label(invoice.status)}
                      </.chip>
                      <%!-- Paddle mints the PDF on demand — a phx-click, not an href,
                         since we fetch the signed URL server-side then redirect. --%>
                      <button
                        type="button"
                        phx-click="download_invoice"
                        phx-value-id={invoice.id}
                        phx-disable-with="Opening…"
                        class="inline-flex items-center gap-1 font-medium text-brand-400 hover:text-brand-300"
                        title={"Download invoice #{invoice.invoice_number} (PDF)"}
                      >
                        <.icon name="hero-arrow-down-tray" class="h-3.5 w-3.5" /> PDF
                      </button>
                    </div>
                  </li>
                </ul>
              </section>
            </.async_result>

            <%!-- Enterprise is a custom, sales-led plan (no self-serve price), so
               plan + billing changes go through our team. The icon-caps-a-spine
               grammar (event_block) — a vertical line drops from the lifebuoy —
               marks it a standing posture note; the action is the aside's
               "Contact support". --%>
            <.event_block
              :if={sales_led_plan?(@summary.plan)}
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
            <%!-- What the tiers include is an operational fact every member
                 works against (the same `view_billing` the usage rail and the
                 plan strip already render from) — an admin chasing a limit
                 needs to see which plan lifts it before asking an owner for it,
                 and hiding the whole catalogue left them nothing to point at.
                 Buying stays the money-handler's job: `start_checkout/4` has
                 always required manage-billing, so the CTA — not the card —
                 is what that permission gates. --%>
            <section>
              <.section_header title="Plans">
                <:actions>
                  <%!-- Monthly/annual is pure UI state (set_cycle) — the chosen
                       cycle rides on the Upgrade click. The saving shows per plan
                       on the card, so the toggle itself stays neutral. --%>
                  <div class="inline-flex rounded-lg p-0.5 text-xs font-medium ring-1 ring-zinc-800">
                    <button
                      :for={{value, label} <- [{"month", "Monthly"}, {"year", "Annual"}]}
                      type="button"
                      phx-click="set_cycle"
                      phx-value-cycle={value}
                      aria-pressed={to_string(@cycle) == value}
                      class={[
                        "rounded-md px-3 py-1.5 transition-colors",
                        if(to_string(@cycle) == value,
                          do: "bg-zinc-800 text-zinc-100",
                          else: "text-zinc-400 hover:text-zinc-200"
                        )
                      ]}
                    >
                      {label}
                    </button>
                  </div>
                </:actions>
              </.section_header>
              <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
                <%!-- ONE card style for every plan — identity ("current") and merch
                 ("most popular") are the CHIPS' job; per-plan border treatments
                 read as three different products. --%>
                <%!-- The current plan is METADATA, not a pass verdict (design-system
                     §3.1), so it never wears the brand ring: the neutral `current`
                     chip names it, and a neutral wash keeps it findable in the row. --%>
                <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — the choice-card recipe (pick-a-plan grid; current = neutral wash) --%>
                <article
                  :for={plan <- @plans}
                  class={[
                    "relative flex flex-col rounded-lg p-5 ring-1 ring-zinc-800",
                    if(current_plan?(plan, @summary), do: "bg-white/[0.04]", else: "bg-black/20")
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

                  <p class="mt-2 text-sm text-zinc-400">
                    {price_label(plan, @cycle)}
                    <span :if={@cycle == :year and savings_note(plan)} class="text-brand-400">
                      · {savings_note(plan)}
                    </span>
                  </p>

                  <ul class="mt-4 flex-1 space-y-2 text-xs text-zinc-300">
                    <li :for={f <- plan.features} class="flex items-start gap-2">
                      <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                      <span class="leading-relaxed">{f}</span>
                    </li>
                  </ul>

                  <%!-- No footer on the current plan: the chip already says it —
                   a disabled "You're here" button was a fake affordance. Same
                   reasoning for a member who can't buy: every button here would
                   die in a denial, and a card whose footer is simply absent
                   reads as a price list, which is what it is for them. --%>
                  <div
                    :if={
                      not current_plan?(plan, @summary) and
                        Billing.subject_can_manage_billing?(@current_subject)
                    }
                    class="mt-5"
                  >
                    <%= cond do %>
                      <% plan.key == "enterprise" -> %>
                        <.button
                          variant={:secondary}
                          size={:md}
                          class="w-full"
                          href={enterprise_sales_mailto(@current_account, @current_user)}
                        >
                          Contact sales
                        </.button>
                      <% sales_led_plan?(@summary.plan) -> %>
                        <%!-- On a custom Enterprise plan (or any Paddle-minted slug
                         this build doesn't know) every other tier is a downgrade,
                         and there's no self-serve path off it — the note above
                         carries the one real action (contact support). --%>
                        <.button
                          variant={:secondary}
                          size={:md}
                          class="w-full"
                          href={billing_support_mailto(@current_account, @current_user)}
                        >
                          Contact support to switch
                        </.button>
                      <% plan_rank(plan.key) > plan_rank(@summary.plan) -> %>
                        <.button
                          size={:md}
                          class="w-full"
                          phx-click="upgrade"
                          phx-value-plan={plan.key}
                          phx-value-cycle={@cycle}
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
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
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
                  count={@summary.member_count}
                  limit_label={limit_label(@summary.member_limit)}
                  pct={usage_pct(@summary.member_count, @summary.member_limit)}
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
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
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
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Need help?
              </h3>
              <p class="mt-3 text-sm leading-relaxed text-zinc-400">
                Questions about your plan, an invoice, or your limits? Our team can help — and can set
                up a custom plan if you're outgrowing these.
              </p>
              <a
                href={billing_support_mailto(@current_account, @current_user)}
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
  # on, a muted dash when it doesn't. The included-feature glyph is the house
  # bare `hero-check` in brand — the same one the plan cards, docs
  # prerequisites, and auth components render; a filled circle here made one
  # page speak two dialects for one fact.
  defp feature_line(assigns) do
    ~H"""
    <li class="flex items-center gap-2">
      <.icon
        name={if @enabled, do: "hero-check", else: "hero-minus"}
        class={"h-4 w-4 flex-none " <> if(@enabled, do: "text-brand-400", else: "text-zinc-500")}
      />
      <span class={(@enabled && "text-zinc-300") || "text-zinc-400"}>{@label}</span>
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
          {@count} <span class="text-zinc-400">/ {@limit_label}</span>
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
