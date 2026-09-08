defmodule EmisarWeb.BillingLive do
  use EmisarWeb, :live_view
  alias Emisar.Billing
  alias EmisarWeb.{BillingIntent, MailTo, Permissions, ShellChrome}

  @plan_order ["free", "team", "enterprise"]
  @refresh_ms 15_000

  def mount(params, _session, socket) do
    billing_intent = billing_intent(params["billing_intent"])

    socket =
      assign(socket,
        page_title: "Billing",
        loading?: not connected?(socket),
        cycle: (billing_intent && billing_intent.cycle) || :month,
        billing_intent: billing_intent,
        summary: nil,
        billing_refresh: nil
      )

    if connected?(socket) do
      {:ok,
       socket
       |> assign(:plans, ordered_plans())
       |> refresh_summary()
       |> assign_invoices(socket.assigns.current_account, socket.assigns.current_subject)
       |> schedule_refresh()}
    else
      {:ok, socket}
    end
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

  defp refresh_summary(socket) do
    summary = fetch_summary(socket.assigns.current_account, socket.assigns.current_subject)
    channels = if summary, do: summary.support_channels, else: %{email?: false, slack_url: nil}

    socket
    |> assign(:summary, summary)
    |> ShellChrome.put(support_channels: channels)
  end

  # One local-database refresh at a time. Neither the timer nor the return
  # from checkout confirms payment or calls Paddle; only the stored billing
  # state determines access. Invoice reads stay on mount and explicit retry.
  defp schedule_refresh(socket) do
    case socket.assigns.billing_refresh do
      {_attempt, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    attempt = make_ref()

    timer =
      Process.send_after(
        self(),
        {:refresh_billing, attempt},
        refresh_delay(socket.assigns.summary)
      )

    assign(socket, :billing_refresh, {attempt, timer})
  end

  defp refresh_delay(%{entitlement_state: :ending} = summary) do
    case summary.scheduled_change_effective_at || summary.current_period_end do
      %DateTime{} = deadline ->
        deadline |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(1) |> min(@refresh_ms)

      _ ->
        @refresh_ms
    end
  end

  defp refresh_delay(_summary), do: @refresh_ms

  # Recent invoices for the payment-history list, fetched off the mount path
  # (IL-18) — a slow Paddle response must not hold up the first paint. A
  # failure renders as the section's inline retry state; the rest of the
  # page (and the portal link) still works.
  defp fetch_invoices(account, subject) do
    case Billing.list_recent_invoices(account, subject, limit: 3) do
      {:ok, invoices} -> {:ok, %{invoices: invoices}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Pure UI state — flips the plan cards between monthly and annual pricing;
  # the chosen cycle rides on the Upgrade click, so no re-fetch here.
  def handle_event("set_cycle", %{"cycle" => cycle}, socket) do
    case parse_cycle(cycle) do
      {:ok, cycle} -> {:noreply, assign(socket, :cycle, cycle)}
      {:error, :invalid_cycle} -> {:noreply, put_flash(socket, :error, "Unknown billing cycle.")}
    end
  end

  def handle_event("upgrade", %{"plan" => plan} = params, socket) do
    Permissions.gated(
      socket,
      Billing.subject_can_manage_billing?(socket.assigns.current_subject),
      fn socket ->
        with {:ok, cycle} <- parse_cycle(params["cycle"]),
             true <- Billing.self_service_checkout?(plan, cycle) do
          case Billing.start_checkout(
                 socket.assigns.current_account,
                 plan,
                 cycle,
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
              {:noreply, put_flash(socket, :error, checkout_error(reason))}
          end
        else
          _invalid -> {:noreply, put_flash(socket, :error, "Unknown plan or billing cycle.")}
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
               "No billing details are available yet. Contact support for help."
             )}

          {:error, _reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Couldn't open billing. Try again, or contact support if this continues."
             )}
        end
      end
    )
  end

  # Download one invoice's PDF — Billing re-checks the transaction against the
  # account's own invoices + view-invoices, then Paddle mints a short-lived
  # signed URL we redirect to (it's served as a download, so the page stays put).
  def handle_event("download_invoice", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      Billing.subject_can_view_invoices?(socket.assigns.current_subject),
      fn socket ->
        case Billing.invoice_pdf_url(
               socket.assigns.current_account,
               id,
               socket.assigns.current_subject
             ) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, invoice_error(reason))}
        end
      end
    )
  end

  # Refresh the async invoice list in place. Authorization lives in
  # the context read (view-invoices + account scope), same as the mount fetch.
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

  # Recovery and support-owned subscriptions are management surfaces, not
  # acquisition funnels. An ended, unmanaged subscription may choose afresh.
  defp offer_keys(summary) do
    cond do
      summary.subscription_source == "complimentary" -> []
      summary.entitlement_state in [:dunning, :ending, :unresolved] -> []
      summary.entitlement_state == :expired and summary.subscription_status != "canceled" -> []
      summary.plan == "free" and not summary.subscription_managed? -> ["team", "enterprise"]
      summary.plan == "team" -> ["enterprise"]
      true -> []
    end
  end

  defp offer_features(plan, summary) do
    runners =
      if plan.runners_limit == :unlimited,
        do: "Unlimited runners",
        else: "Up to #{plan.runners_limit} runners"

    plan.features
    |> Keyword.put_new(:runners, runners)
    |> Keyword.update(:support, "Email support", fn label ->
      if plan.key == "enterprise" and summary.support_channels.email?,
        do: "Slack support",
        else: label
    end)
    |> Enum.filter(fn
      {:runners, _} -> greater_limit?(plan.runners_limit, summary.runner_limit)
      {:members, _} -> greater_limit?(plan.members_limit, summary.member_limit)
      {:audit_retention, _} -> plan.audit_retention_days > summary.audit_retention_days
      {feature, _} when feature in [:sso, :scim, :audit_export] -> not summary.features[feature]
      {:team, _} -> summary.plan == "free"
      {:support, _} -> plan.key == "enterprise" or not summary.support_channels.email?
      # Full commercial detail remains in the docs; keep the upgrade offer short.
      {feature, _} -> feature == :security_review
    end)
  end

  defp greater_limit?(_offered, :unlimited), do: false
  defp greater_limit?(:unlimited, _current), do: true
  defp greater_limit?(offered, current), do: offered > current

  defp additional_plan_features(plans, summary) do
    case Enum.find(plans, &(&1.key == summary.plan)) do
      nil ->
        []

      plan ->
        Keyword.take(plan.features, [:security_review, :deployment_planning, :rollout_support])
    end
  end

  defp estimate_label(plan, summary, cycle) do
    quantity = max(summary.runner_count, 1)
    cents = if cycle == :year, do: plan.annual_price_cents, else: plan.monthly_price_cents
    period = if cycle == :year, do: "year", else: "month"
    runners = if quantity == 1, do: "1 billable runner", else: "#{quantity} billable runners"

    "Estimated total: #{format_total(cents * quantity, "USD")}/#{period} for #{runners}"
  end

  defp limit_label(:unlimited), do: "Unlimited"
  defp limit_label(n) when is_integer(n), do: Integer.to_string(n)
  defp limit_label(_), do: "—"

  # Whitelist the cycle off the client (IL-14). Invalid values fail closed;
  # silently treating one as monthly would change the commercial choice.
  defp parse_cycle("month"), do: {:ok, :month}
  defp parse_cycle("year"), do: {:ok, :year}
  defp parse_cycle(_), do: {:error, :invalid_cycle}

  defp billing_intent(token) do
    case BillingIntent.verify(token) do
      {:ok, intent} -> intent
      {:error, :invalid} -> nil
    end
  end

  defp billing_intent_actionable?(intent, summary, subject) do
    not is_nil(intent) and intent.plan == "team" and
      "team" in offer_keys(summary) and
      plan_rank("team") > plan_rank(summary.plan) and
      plan_action(%{key: "team"}, summary) == :upgrade and
      Billing.subject_can_manage_billing?(subject)
  end

  defp cycle_label(:month), do: "Monthly billing"
  defp cycle_label(:year), do: "Annual billing"

  defp price_label(%{monthly_price_cents: nil}, _cycle), do: "Custom pricing"
  defp price_label(%{monthly_price_cents: 0}, _cycle), do: "$0"

  defp price_label(%{annual_price_cents: cents}, :year) when is_integer(cents),
    do: "$#{div(cents, 100)} / runner / year"

  defp price_label(%{monthly_price_cents: cents}, :month),
    do: "$#{div(cents, 100)} / runner / month"

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

  defp plan_action(plan, summary) do
    cond do
      summary.subscription_source == "complimentary" -> :support
      sales_led_plan?(summary.plan) -> :support
      summary.subscription_managed? and sales_led_plan?(summary.subscribed_plan) -> :support
      plan.key == "enterprise" -> :sales
      summary.subscription_managed? and summary.billing_portal_available? -> :manage
      summary.subscription_managed? -> :support
      plan_rank(plan.key) > plan_rank(summary.plan) -> :upgrade
      true -> :support
    end
  end

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
  defp period_price_label(%{subscription_source: "complimentary"}), do: "Complimentary"
  defp period_price_label(%{plan: "free"}), do: "$0"
  defp period_price_label(%{period_total_cents: nil}), do: "Custom pricing"

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

  defp checkout_error(:checkout_pending) do
    "We're confirming your checkout. Try again shortly."
  end

  defp checkout_error(:payment_reconciling) do
    "We're confirming your payment and subscription. Try again shortly, or contact support if this continues."
  end

  defp checkout_error(:subscription_retirement_pending) do
    "We're confirming the cancellation of an earlier subscription. Try again shortly, or contact support if this continues."
  end

  defp checkout_error(:legacy_checkout_pending) do
    "We couldn't confirm an earlier checkout. Try again shortly, or contact support if this continues."
  end

  defp checkout_error(:account_closed), do: "This account is closed. Checkout is unavailable."

  defp checkout_error(:checkout_unavailable),
    do: "Checkout is unavailable for this account. Contact support for help."

  defp checkout_error(_reason),
    do: "Couldn't start checkout. Try again, or contact support if this continues."

  defp invoice_error(:not_found), do: "That invoice is no longer available."
  defp invoice_error(_reason), do: "Couldn't open the invoice. Try again."

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

  def handle_info({:refresh_billing, attempt}, socket) do
    case socket.assigns.billing_refresh do
      {^attempt, _timer} -> {:noreply, socket |> refresh_summary() |> schedule_refresh()}
      _stale -> {:noreply, socket}
    end
  end

  # The badge/fleet hooks own unrelated account broadcasts.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    offers =
      if assigns.summary,
        do: Enum.filter(assigns.plans, &(&1.key in offer_keys(assigns.summary))),
        else: []

    assigns = assign(assigns, :offers, offers)

    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:billing}
      width={:table}
    >
      <:title>Billing</:title>

      <.page_intro>
        See what your plan includes and how much you're using, with billing details and upgrade
        options in one place. <.doc_link href={~p"/docs/billing"}>Billing docs</.doc_link>
      </.page_intro>

      <.loading_state :if={@loading?} />

      <%!-- billing_summary/2 can return {:error, _} (→ nil); never deref a
           nil @summary into a white screen — show a load-error state and a
           reload. This is on us, not the operator's payment. --%>
      <.empty_state
        :if={not @loading? and is_nil(@summary)}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load billing"
      >
        Reload this page to try again.
        <:cta navigate={~p"/app/#{@current_account}/settings/billing"}>Reload</:cta>
      </.empty_state>

      <div :if={not @loading? and not is_nil(@summary)} class="space-y-6">
        <.subscription_banner
          entitlement_state={@summary.entitlement_state}
          status={@summary.subscription_status}
          scheduled_action={@summary.scheduled_change_action}
          scheduled_effective_at={
            @summary.scheduled_change_effective_at || @summary.current_period_end
          }
        >
          <:cta :if={Billing.subject_can_manage_billing?(@current_subject)}>
            <.button
              :if={@summary.billing_portal_available?}
              variant={:secondary}
              size={:sm}
              class="shrink-0"
              phx-click="manage_billing"
              phx-disable-with="Opening billing…"
            >
              Manage billing
            </.button>
            <.button
              :if={not @summary.billing_portal_available?}
              variant={:secondary}
              size={:sm}
              href={billing_support_mailto(@current_account, @current_user)}
            >
              Contact support
            </.button>
          </:cta>
        </.subscription_banner>
        <div class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
          <div class="min-w-0 space-y-8">
            <section id="billing-current-plan">
              <.section_header title="Current plan">
                <:actions :if={Billing.subject_can_manage_billing?(@current_subject)}>
                  <.button
                    :if={
                      @summary.billing_portal_available? and
                        @summary.subscription_source != "complimentary"
                    }
                    variant={:secondary}
                    phx-click="manage_billing"
                    phx-disable-with="Opening billing…"
                  >
                    Manage billing
                  </.button>
                  <.button
                    :if={
                      @summary.subscription_source == "complimentary" or
                        (not @summary.billing_portal_available? and
                           (@summary.support_channels.email? or @summary.subscription_managed?))
                    }
                    variant={:secondary}
                    href={billing_support_mailto(@current_account, @current_user)}
                  >
                    Contact support
                  </.button>
                </:actions>
              </.section_header>
              <div>
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <span class="text-2xl font-semibold text-zinc-50">{@summary.plan_name}</span>
                  <span class="text-sm tabular-nums text-zinc-400">{period_price_label(@summary)}</span>
                </div>
                <%!-- The banner owns pause/cancellation deadlines. --%>
                <p :if={@summary.trial_end} class="mt-2 text-xs text-zinc-400">
                  Trial ends
                  <.local_time id="billing-trial-ends" value={@summary.trial_end} class="inline" />
                </p>
                <p
                  :if={
                    @summary.entitlement_state in [:active, :dunning] &&
                      @summary.current_period_end && @summary.cancel_at_period_end != true &&
                      is_nil(@summary.scheduled_change_action)
                  }
                  class="mt-2 text-xs text-zinc-400"
                >
                  Next charge
                  <.local_time
                    id="billing-next-charge"
                    value={@summary.current_period_end}
                    class="inline"
                  />
                </p>
              </div>
            </section>
            <.async_result
              :let={invoices}
              :if={Billing.subject_can_view_invoices?(@current_subject)}
              assign={@invoices}
            >
              <:loading>
                <section :if={@summary.billing_portal_available?}>
                  <.section_header title="Recent invoices" />
                  <p class="flex items-center gap-2 text-sm text-zinc-400">
                    <.icon name="state.loading" class="h-4 w-4 animate-spin" /> Loading invoices…
                  </p>
                </section>
              </:loading>
              <:failed>
                <.event_block
                  icon="state.warning"
                  tone={:rose}
                  title="Couldn't load recent invoices"
                  class="max-w-prose"
                >
                  <:body>Try again to load your invoices.</:body>
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
              <section :if={@summary.billing_portal_available?}>
                <.section_header title="Recent invoices">
                  <:actions>
                    <.button
                      variant={:secondary}
                      size={:sm}
                      phx-click="retry_invoices"
                      phx-disable-with="Loading…"
                    >
                      Refresh invoices
                    </.button>
                    <.button
                      :if={Billing.subject_can_manage_billing?(@current_subject)}
                      variant={:secondary}
                      size={:sm}
                      phx-click="manage_billing"
                      phx-disable-with="Opening billing…"
                    >
                      View all invoices
                    </.button>
                  </:actions>
                </.section_header>
                <ul :if={invoices != []} id="billing-invoices" class="divide-y divide-zinc-800/70">
                  <li
                    :for={invoice <- Enum.take(invoices, 3)}
                    class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3 text-sm"
                  >
                    <.local_time
                      :if={invoice.billed_at}
                      id={"invoice-billed-#{invoice.id}"}
                      value={invoice.billed_at}
                      class="w-36 shrink-0 whitespace-nowrap text-zinc-400"
                    />
                    <%!-- Unreadable provider amounts stay unknown, never zero. --%>
                    <span class="min-w-[4rem] font-medium tabular-nums text-zinc-200">
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
                      <%!-- The context rechecks ownership before minting the PDF URL. --%>
                      <.button
                        variant={:secondary}
                        size={:sm}
                        phx-click="download_invoice"
                        phx-value-id={invoice.id}
                        phx-disable-with="Opening…"
                        aria-label={"Download invoice #{invoice.invoice_number} (PDF)"}
                      >
                        PDF
                      </.button>
                    </div>
                  </li>
                </ul>
              </section>
            </.async_result>
          </div>
          <aside class="min-w-0 space-y-8">
            <section id="billing-usage">
              <.section_header title="Usage" />
              <div class="space-y-4">
                <%!-- These are actual entitlements, including account-specific limits. --%>
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
                <div class="flex items-baseline justify-between gap-3 text-xs">
                  <span class="text-zinc-400">Audit retention</span>
                  <span class="font-medium tabular-nums text-zinc-200">
                    {@summary.audit_retention_days} days
                  </span>
                </div>
              </div>
            </section>
            <section id="billing-features">
              <.section_header title="Features" />
              <ul class="space-y-2 text-sm">
                <.feature_line enabled={@summary.features.sso} label="Single sign-on (OIDC)" />
                <.feature_line enabled={@summary.features.scim} label="SCIM directory sync" />
                <.feature_line
                  enabled={@summary.features.audit_export}
                  label="Audit export (CSV + SIEM)"
                />
                <.feature_line
                  :for={{_key, label} <- additional_plan_features(@plans, @summary)}
                  enabled={true}
                  label={label}
                />
              </ul>
            </section>
            <section :if={@summary.support_channels.email?} id="billing-support">
              <.section_header title="Need help?" />
              <p class="text-sm leading-relaxed text-zinc-400">
                <%= if sales_led_plan?(@summary.plan) do %>
                  Contact us for general support, billing help, plan changes, or cancellation.
                <% else %>
                  Contact us for help with emisar or your billing.
                <% end %>
              </p>
              <div class="mt-3 flex flex-wrap gap-x-5 gap-y-2">
                <.link
                  :if={@summary.support_channels.slack_url}
                  href={@summary.support_channels.slack_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-1 text-sm font-medium text-brand-400 hover:text-brand-300"
                >
                  Slack support <.icon name="action.external_link" class="h-3.5 w-3.5" />
                </.link>
                <a
                  href={billing_support_mailto(@current_account, @current_user)}
                  class="group text-sm font-medium text-brand-400 hover:text-brand-300"
                >
                  Email support&nbsp;<.cta_arrow />
                </a>
              </div>
            </section>
          </aside>
        </div>

        <section :if={@offers != []} id="billing-upgrade-offers" class="max-w-3xl">
          <.status_note
            :if={billing_intent_actionable?(@billing_intent, @summary, @current_subject)}
            icon="product.billing"
            tone={:neutral}
            title={"Review Team for #{@current_account.name}"}
            class="mb-5"
          >
            {cycle_label(@cycle)} is selected. Choose Upgrade to Team below to open checkout.
            Nothing is charged until you confirm there.
          </.status_note>
          <.section_header title={
            if @summary.plan == "free", do: "Upgrade your plan", else: "Upgrade to Enterprise"
          } />
          <div class={["grid gap-4", length(@offers) == 2 && "md:grid-cols-2"]}>
            <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — paid choices reuse the shared choice-card recipe; a single offer stays on canvas --%>
            <article
              :for={plan <- @offers}
              id={"billing-offer-#{plan.key}"}
              class={
                if length(@offers) == 2,
                  do: "flex min-w-0 flex-col rounded-lg bg-black/20 p-4 ring-1 ring-zinc-800",
                  else: "grid min-w-0 gap-x-10 gap-y-4 md:grid-cols-2"
              }
            >
              <div>
                <.section_header
                  :if={length(@offers) == 2}
                  level={3}
                  title={plan.name}
                  class="min-h-8"
                >
                  <:badge :if={
                    plan.key == "team" and
                      billing_intent_actionable?(@billing_intent, @summary, @current_subject)
                  }>
                    <.chip tone={:neutral}>Selected</.chip>
                  </:badge>
                  <:actions :if={plan.key == "team"}>
                    <div
                      class="inline-flex rounded-lg p-0.5 text-xs font-medium ring-1 ring-zinc-800"
                      role="group"
                      aria-label="Team billing cycle"
                    >
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
                <p class="text-sm tabular-nums text-zinc-200">{price_label(plan, @cycle)}</p>
                <p :if={plan.key == "team"} class="mt-2 text-xs tabular-nums text-zinc-400">
                  {estimate_label(plan, @summary, @cycle)}
                  <span
                    :if={@cycle == :year and Billing.annual_savings_label(plan)}
                    class="block mt-1"
                  >
                    {Billing.annual_savings_label(plan)}
                  </span>
                </p>
              </div>
              <ul class={[
                "space-y-1.5 text-xs text-zinc-300",
                if(length(@offers) == 2,
                  do: "mt-4 flex-1",
                  else: "md:col-start-2 md:row-start-1 md:row-span-2"
                )
              ]}>
                <li
                  :for={{_key, label} <- offer_features(plan, @summary)}
                  class="flex items-start gap-2"
                >
                  <.icon name="state.included" class="h-4 w-4 flex-none text-zinc-400" />
                  <span>{label}</span>
                </li>
              </ul>
              <div
                :if={Billing.subject_can_manage_billing?(@current_subject)}
                class={if length(@offers) == 2, do: "mt-4", else: "md:col-start-1 md:row-start-2"}
              >
                <%= case plan_action(plan, @summary) do %>
                  <% :upgrade -> %>
                    <.button
                      class="w-full"
                      size={:sm}
                      phx-click="upgrade"
                      phx-value-plan={plan.key}
                      phx-value-cycle={@cycle}
                      phx-disable-with="Starting checkout…"
                    >
                      Upgrade to {plan.name}
                    </.button>
                  <% :sales -> %>
                    <.button
                      variant={:secondary}
                      class={if length(@offers) == 2, do: "w-full"}
                      size={:sm}
                      href={enterprise_sales_mailto(@current_account, @current_user)}
                    >
                      Contact sales
                    </.button>
                  <% :support -> %>
                    <.button
                      variant={:secondary}
                      size={:sm}
                      href={billing_support_mailto(@current_account, @current_user)}
                    >
                      Contact support
                    </.button>
                  <% :manage -> %>
                    <.button
                      variant={:secondary}
                      size={:sm}
                      phx-click="manage_billing"
                      phx-disable-with="Opening billing…"
                    >
                      Manage billing
                    </.button>
                <% end %>
              </div>
            </article>
          </div>
        </section>
      </div>
    </.console_shell>
    """
  end

  attr :enabled, :boolean, required: true
  attr :label, :string, required: true

  # One plan-feature line in the usage rail: a check when the plan turns it
  # on, a muted dash when it doesn't. The included-feature glyph is the house
  # bare `state.included` in brand — the same one the plan cards, docs
  # prerequisites, and auth components render; a filled circle here made one
  # page speak two dialects for one fact.
  defp feature_line(assigns) do
    ~H"""
    <li class="flex items-center gap-2">
      <.icon
        name={if @enabled, do: "state.included", else: "state.not_included"}
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
      <div class="flex items-baseline justify-between gap-3 text-xs">
        <span class="text-zinc-400">{@label}</span>
        <span class="font-medium tabular-nums text-zinc-200">
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
