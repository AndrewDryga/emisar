defmodule EmisarWeb.ShellComponents do
  @moduledoc """
  The authenticated console's chrome: the page shell, its sidebar and topbar,
  the account switcher, and the navigation links and badges inside them.

  Split out of CoreComponents, which holds the audience-neutral primitives —
  a button, an icon, a dropdown. This file is app navigation: it knows the
  product's sections, which account you are in, and where the pending-approval
  count comes from. Every view still gets every component through
  `EmisarWeb.html_helpers/0`, so no call site changed; the split is about which
  file you read.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents
  alias Emisar.Accounts
  alias EmisarWeb.MailTo
  alias Phoenix.LiveView.JS

  @doc """
  Shell for authenticated product pages: sidebar + topbar + main.
  Expects @current_user, @current_account in assigns.
  `:pending_approvals_count` is set by the `:track_pending_approvals`
  on_mount hook (UserAuth) — defaults to 0 so the shell still renders
  in test contexts that haven't gone through the hook.
  `:switchable_accounts` is the full list of accounts the user can
  pick from (including the current one); defaults to a list with just
  the current account so the shell still renders without the on_mount
  hook in unit tests.
  """
  attr :current_user, :map, required: true
  attr :current_account, :map, required: true
  attr :current_subject, :map, required: true
  # `chrome.membership` is what names the person, not `current_user`: a directory
  # can rename a member per account, and `users.full_name` is cross-account, so a
  # multi-account synced member was called two different things depending on the
  # surface. The struct defaults throughout, so a unit test can render the shell
  # without the on_mount hooks that seed it.
  attr :current_membership, :map, default: nil

  attr :chrome, EmisarWeb.ShellChrome,
    default: %EmisarWeb.ShellChrome{},
    doc: "the shell's own nav cues and account facts, seeded by the UserAuth hooks"

  attr :section, :atom, default: :dashboard

  attr :width, :atom,
    default: :detail,
    values: [:table, :detail, :form, :settings],
    doc:
      "content column width: :table (7xl — every operate/list page incl. dashboard/runs/audit), :detail (6xl), :form (3xl), :settings (4xl)"

  slot :inner_block, required: true
  slot :title, required: true
  slot :actions

  def console_shell(assigns) do
    ~H"""
    <div
      id="portal-performance"
      phx-hook="PortalPerformance"
      class="flex min-h-screen bg-zinc-950 text-zinc-100"
    >
      <%!-- Desktop sidebar (lg and up). `sticky top-0 h-screen` pins
           it to the viewport so the bottom user-block (and sign-out
           icon) stays reachable on tall pages instead of being pushed
           off-screen by content height. --%>
      <%!-- The sidebar sits on the SAME black plane as the work canvas — one
           surface, a single landed hairline between nav and work (the old
           zinc-950 panel read as separate admin chrome beside the canvas). --%>
      <aside class="hidden w-64 flex-shrink-0 flex-col border-r border-zinc-800/70 bg-black lg:sticky lg:top-0 lg:flex lg:h-screen">
        <.shell_brand
          current_account={@current_account}
          switchable_accounts={@chrome.switchable_accounts}
        />
        <.shell_nav
          current_account={@current_account}
          current_user={@current_user}
          current_subject={@current_subject}
          section={@section}
          support_channels={@chrome.support_channels}
          pending_approvals_count={@chrome.pending_approvals_count}
          pending_access_requests_count={@chrome.pending_access_requests_count}
          pending_packs_count={@chrome.pending_packs_count}
          fleet_all_offline?={@chrome.fleet_all_offline?}
          no_agents?={@chrome.no_agents?}
          onboarding_incomplete?={@chrome.onboarding_incomplete?}
        />
        <.shell_user
          current_user={@current_user}
          current_account={@current_account}
          current_membership={@current_membership}
        />
      </aside>

      <%!-- Mobile drawer (hidden by default; JS toggles `open`). The focus_wrap
           contains Tab inside the open drawer; DialogFocus returns focus to the
           hamburger on close — without both, a keyboard/SR operator tabs into
           the page hidden behind the backdrop and loses their place. --%>
      <div
        id="mobile-nav"
        class="fixed inset-0 z-40 hidden lg:hidden"
        role="dialog"
        aria-modal="true"
        aria-label="Menu"
        phx-hook="DialogFocus"
        phx-window-keydown={close_mobile_nav()}
        phx-key="escape"
      >
        <div class="absolute inset-0 bg-black/60" phx-click={close_mobile_nav()}></div>
        <.focus_wrap
          id="mobile-nav-wrap"
          class="relative flex h-full w-72 max-w-[80vw] flex-col border-r border-zinc-800/70 bg-black shadow-2xl"
        >
          <div class="flex items-center justify-between border-b border-zinc-800/70 px-4 py-3">
            <.shell_brand
              current_account={@current_account}
              switchable_accounts={@chrome.switchable_accounts}
            />
            <button
              type="button"
              aria-label="Close menu"
              class="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
              phx-click={close_mobile_nav()}
            >
              <.icon name="action.close" class="h-5 w-5" />
            </button>
          </div>
          <.shell_nav
            current_account={@current_account}
            current_user={@current_user}
            current_subject={@current_subject}
            section={@section}
            support_channels={@chrome.support_channels}
            pending_approvals_count={@chrome.pending_approvals_count}
            pending_access_requests_count={@chrome.pending_access_requests_count}
            pending_packs_count={@chrome.pending_packs_count}
            fleet_all_offline?={@chrome.fleet_all_offline?}
            no_agents?={@chrome.no_agents?}
            onboarding_incomplete?={@chrome.onboarding_incomplete?}
          />
          <.shell_user
            current_user={@current_user}
            current_account={@current_account}
            current_membership={@current_membership}
          />
        </.focus_wrap>
      </div>

      <%!-- The whole console — sidebar AND work column — is one black plane.
           The id is the capture anchor for full-workspace docs shots
           (tools/internal/browser/docs.go): the page without the nav rail. --%>
      <div id="shell-canvas" class="flex min-w-0 flex-1 flex-col bg-black">
        <%!-- Portal-wide nudge: a signed-in user whose email isn't
             confirmed yet. Shown on every page until they verify; the
             "Resend" button is handled by the global `:email_confirmation`
             on_mount hook so it works regardless of which LV is mounted. --%>
        <.callout
          :if={@current_user && @current_user.email && is_nil(@current_user.confirmed_at)}
          tone={:amber}
          variant={:strip}
          icon="communication.email"
        >
          Verify your email — open the confirmation link for <span class="break-all font-medium text-amber-100">{@current_user.email}</span>, or request a new one.
          <:action>
            <.button variant={:secondary} size={:sm} phx-click="resend_confirmation">
              Resend email
            </.button>
          </:action>
        </.callout>

        <%!-- The no-LLM nudge is ONE signal: the nav item's attention dot.
             The page-wide banner strip died — three signals for one fact (a
             brand-washed banner on every page + the nav dot + the dashboard
             pillar) shouted an invitation, and green belongs to pass/healthy,
             not to "nothing connected yet". --%>
        <%!-- min-h (not h): the title WRAPS on a phone instead of ellipsizing —
             a truncated machine id ("api-iad-…") is useless on an audit-grade
             surface, so the bar grows to fit and break-words splits an unbroken
             id token only when it must. --%>
        <%!-- The title floats ON the canvas — no bar, no border, no blur. A
             gray sticky strip with a lone word was pure admin-template chrome;
             the page title is the first line of the content, set large, and the
             page begins. --%>
        <header class="px-4 pb-2 pt-7 sm:px-8 sm:pt-9">
          <%!-- items-center, not items-start: a taller action button (a :md
               control beside the H1) would otherwise stretch the row's bottom
               below the title and inflate the gap to the page intro — the gap
               read larger on Audit / Runbooks than on action-less pages. --%>
          <div class={[
            "mx-auto flex w-full flex-wrap items-center gap-x-3 gap-y-3",
            shell_width(@width)
          ]}>
            <%!-- Mobile hamburger (hidden on lg) — the 36px button centers on
                 the title's 35px first line; a top margin pushed the icon
                 visibly below the title's optical center. --%>
            <button
              type="button"
              id="mobile-nav-open"
              aria-label="Open menu"
              aria-controls="mobile-nav"
              aria-expanded="false"
              class="-ml-1.5 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 lg:hidden"
              phx-click={open_mobile_nav()}
            >
              <.icon name="action.menu" class="h-5 w-5" />
            </button>
            <%!-- basis-0 + a generous min width: while the title has room it
                 shares the row with the actions; on a phone the actions WRAP
                 to their own line below instead of crushing the h1 into
                 mid-word breaks ("Run/ner/s"). --%>
            <h1 class="min-w-[12rem] flex-1 basis-0 break-words font-display text-[28px] font-bold leading-tight tracking-[-0.03em] text-zinc-50">
              {render_slot(@title)}
            </h1>
            <%!-- ml-auto: actions hold the RIGHT edge on the shared row AND
                 when they wrap to their own line on a phone. --%>
            <div class="ml-auto flex shrink-0 flex-wrap items-center gap-2 sm:gap-3">
              {render_slot(@actions)}
            </div>
          </div>
        </header>

        <%!-- The work canvas is clean flat BLACK. Most content sits DIRECTLY on
             it — typography and space carry the structure; a contained surface
             (island) is reserved for things where the box MEANS something (a
             code artifact, a form, an attention panel). --%>
        <%!-- Wide content is clamped with `overflow-x-clip`, never the `-hidden`
             spelling: `-hidden` on ONE axis forces the other to compute to `auto`,
             which silently made this canvas a vertical SCROLL container. It then
             swallowed every absolutely-positioned overlay hanging out of it — an
             open dropdown panel on the last row of a list vanished instead of
             extending the page, and no amount of scrolling reached it. `clip`
             contains the same wide table without creating that boundary. --%>
        <main class="flex-1 overflow-x-clip bg-black px-4 pb-10 pt-2 sm:px-8">
          <div class={["mx-auto w-full space-y-6", shell_width(@width)]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  # Content width tiers: one column width per page kind so every screen lines up
  # (the shell owns it — pages pass `width=`, never hand-roll `mx-auto max-w-*`).
  # Dense DATA TABLES go FULL-BLEED (founder: "centering tables like the audit log
  # is a no-go — too much data") for column density; card-lists + dashboard stay
  # capped so a single-column card doesn't stretch thin; reading/forms bounded for
  # line length. Literal classes so Tailwind's purge keeps them.
  # ONE operating width: every top-level console page caps at 7xl (`:full`
  # died — dashboard/runs/audit stretching edge-to-edge beside 7xl-capped
  # peers made adjacent clicks feel like different products). The ladder:
  # 7xl operate/list · 6xl detail · 4xl settings · 3xl focused flow.
  defp shell_width(:table), do: "max-w-7xl"
  defp shell_width(:detail), do: "max-w-6xl"
  defp shell_width(:form), do: "max-w-3xl"
  defp shell_width(:settings), do: "max-w-4xl"

  # The drawer opens/closes entirely client-side, so these commands own the
  # hamburger's aria-expanded state too; focus_first moves focus inside on open
  # (the focus_wrap sentinels are aria-hidden, so it lands on a real control)
  # and the DialogFocus hook restores it to the hamburger on close.
  defp open_mobile_nav do
    JS.show(to: "#mobile-nav", display: "block")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#mobile-nav-open")
    |> JS.focus_first(to: "#mobile-nav")
  end

  defp close_mobile_nav do
    JS.hide(to: "#mobile-nav")
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-nav-open")
  end

  # -- shell sub-components (shared between desktop + mobile) ----------

  attr :current_account, :map, required: true
  attr :switchable_accounts, :list, required: true

  defp shell_brand(assigns) do
    others =
      Enum.reject(assigns.switchable_accounts, &(&1.id == assigns.current_account.id))

    assigns = assign(assigns, :other_accounts, others)

    ~H"""
    <.dropdown
      class="border-b border-zinc-800/70"
      align={:stretch}
      summary_class="flex h-16 items-center gap-3 px-2 transition hover:bg-white/[0.04] lg:px-6"
      panel_class="z-30 mt-1 overflow-hidden shadow-2xl"
    >
      <:trigger>
        <img src={~p"/images/brand/emisar-icon.svg"} alt="" class="h-8 w-8 shrink-0" />
        <div class="min-w-0 flex-1 translate-y-[2px]">
          <img
            src={~p"/images/brand/emisar-wordmark.svg"}
            alt="emisar"
            class="h-2.5 w-auto opacity-75"
          />
          <div class="mt-0.5 truncate text-sm font-semibold leading-tight text-zinc-100">
            {@current_account.name}
          </div>
        </div>
        <.icon
          name="action.select"
          class="h-4 w-4 shrink-0 text-zinc-500 transition group-open:text-zinc-300"
        />
      </:trigger>

      <div class="border-b border-zinc-900 px-3 py-2">
        <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Switch workspace
        </p>
      </div>

      <ul class="scrollbar-subtle max-h-[60vh] overflow-y-auto py-1">
        <li>
          <div class="flex items-center gap-2 px-3 py-2 text-sm">
            <.avatar
              name={@current_account.name}
              shape={:square}
              size={:xs}
              tone={:brand}
            />
            <span class="truncate font-medium">{@current_account.name}</span>
          </div>
        </li>
        <%= for account <- @other_accounts do %>
          <li>
            <form action={~p"/app/accounts/switch"} method="post" class="contents">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <input type="hidden" name="account_id" value={account.id} />
              <button
                type="submit"
                class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-zinc-200 transition hover:bg-zinc-900"
              >
                <.avatar name={account.name} shape={:square} size={:xs} />
                <span class="truncate">{account.name}</span>
              </button>
            </form>
          </li>
        <% end %>
      </ul>

      <div class="border-t border-zinc-800/70 p-1">
        <.link
          navigate={~p"/onboarding"}
          class="flex items-center gap-2 rounded-md px-3 py-2 text-sm text-zinc-300 transition hover:bg-zinc-900 hover:text-zinc-100"
        >
          <.icon name="action.add" class="h-4 w-4 shrink-0" />
          <span>Create new workspace</span>
        </.link>
      </div>
    </.dropdown>
    """
  end

  attr :section, :atom, required: true
  attr :current_subject, :map, required: true
  attr :support_channels, :map, default: %{email?: false, slack_url: nil}
  attr :pending_approvals_count, :integer, default: 0
  attr :pending_access_requests_count, :integer, default: 0
  attr :pending_packs_count, :integer, default: 0
  attr :fleet_all_offline?, :boolean, default: false
  attr :no_agents?, :boolean, default: false
  attr :onboarding_incomplete?, :boolean, default: false
  attr :current_account, :map, required: true
  attr :current_user, :map, required: true

  defp shell_nav(assigns) do
    # One domain predicate per section — the nav shows only what the member
    # can actually open (a billing_manager sees Billing + Team, not six dead
    # links). Courtesy only: every context still denies server-side (IL-15).
    subject = assigns.current_subject

    assigns =
      assign(assigns,
        can_view_runners?: Emisar.Runners.subject_can_view_runners?(subject),
        can_view_agents?: Emisar.ApiKeys.subject_can_view_api_keys?(subject),
        can_view_runs?: Emisar.Runs.subject_can_view_runs?(subject),
        can_view_approvals?: Emisar.Approvals.subject_can_view_approvals?(subject),
        can_view_audit?: Emisar.Audit.subject_can_view_audit?(subject),
        can_view_packs?: Emisar.Catalog.subject_can_view_packs?(subject),
        can_view_policies?: Emisar.Policies.subject_can_view_policies?(subject),
        can_view_runbooks?: Emisar.Runbooks.subject_can_view_runbooks?(subject)
      )

    support_context =
      MailTo.context(%{
        current_account: assigns.current_account,
        current_user: assigns.current_user
      })

    assigns =
      assign(
        assigns,
        :support_mailto,
        MailTo.support(
          subject: "Support request - #{assigns.current_account.name}",
          context: support_context
        )
      )

    ~H"""
    <%!-- pt-2/pb-4 + the tightened group air below keep the WHOLE nav (18 links,
         5 groups) under ~730px, so at common laptop heights (≥860px with the
         brand + user blocks) nothing sits half-clipped at the scroll fold —
         "Support" cut in half read as a rendering defect on every screenshot. --%>
    <nav class="scrollbar-subtle flex-1 space-y-0.5 overflow-y-auto px-3 pb-4 pt-2 text-sm">
      <.nav_link
        :if={@can_view_runs?}
        to={~p"/app/#{@current_account}"}
        active={@section == :dashboard}
        icon="product.dashboard"
        alert={@onboarding_incomplete?}
        alert_label="Finish setup — add a runner or an agent"
      >
        Dashboard
      </.nav_link>

      <%!-- Connect — the two things you need to USE emisar: a runner to execute and
           an agent to call it. Surfaced at the top so setup is one glance away. --%>
      <.nav_group :if={@can_view_runners? or @can_view_agents?} label="Connect" />
      <.nav_link
        :if={@can_view_runners?}
        to={~p"/app/#{@current_account}/runners"}
        active={@section == :runners}
        icon="product.runner"
        alert={@fleet_all_offline?}
        alert_label="All runners offline"
      >
        Runners
      </.nav_link>
      <.nav_link
        :if={@can_view_agents?}
        to={~p"/app/#{@current_account}/agents"}
        active={@section == :agents}
        icon="product.agent"
        alert={@no_agents?}
        alert_label="No AI agent connected yet"
      >
        AI agents
      </.nav_link>

      <.nav_group
        :if={@can_view_runs? or @can_view_approvals? or @can_view_audit?}
        label="Operate"
      />
      <.nav_link
        :if={@can_view_runs?}
        to={~p"/app/#{@current_account}/runs"}
        active={@section == :runs}
        icon="product.run"
      >
        Runs
      </.nav_link>
      <.nav_link
        :if={@can_view_approvals?}
        to={~p"/app/#{@current_account}/approvals"}
        active={@section == :approvals}
        icon="product.approval"
        badge={@pending_approvals_count}
      >
        Approvals
      </.nav_link>
      <.nav_link
        :if={@can_view_audit?}
        to={~p"/app/#{@current_account}/audit"}
        active={@section == :audit}
        icon="product.audit"
      >
        Audit
      </.nav_link>

      <.nav_group
        :if={@can_view_packs? or @can_view_policies? or @can_view_runbooks?}
        label="Control"
      />
      <.nav_link
        :if={@can_view_packs?}
        to={~p"/app/#{@current_account}/packs"}
        active={@section == :packs}
        icon="product.pack"
        badge={@pending_packs_count}
      >
        Packs
      </.nav_link>
      <.nav_link
        :if={@can_view_policies?}
        to={~p"/app/#{@current_account}/policies"}
        active={@section == :policies}
        icon="product.policy"
      >
        Policy
      </.nav_link>
      <.nav_link
        :if={@can_view_runbooks?}
        to={~p"/app/#{@current_account}/runbooks"}
        active={@section == :runbooks}
        icon="product.runbook"
      >
        Runbooks
      </.nav_link>

      <.nav_group label="Settings" />
      <.nav_link
        to={~p"/app/#{@current_account}/settings/team"}
        active={@section == :team}
        icon="product.team"
        badge={@pending_access_requests_count}
      >
        Team
      </.nav_link>
      <.nav_link
        to={~p"/app/#{@current_account}/settings/billing"}
        active={@section == :billing}
        icon="product.billing"
      >
        Billing
      </.nav_link>

      <.nav_group label="Resources" />
      <.nav_link_external href={~p"/docs"} icon="product.docs">Docs</.nav_link_external>
      <.nav_link_external href={~p"/changelog"} icon="product.changelog">Changelog</.nav_link_external>
      <.nav_link_external
        href={Application.get_env(:emisar_web, :status_page_url, "https://status.emisar.dev")}
        icon="product.service_status"
      >
        Status
      </.nav_link_external>
      <.nav_link_external
        :if={@support_channels.slack_url}
        href={@support_channels.slack_url}
        icon="product.support"
      >
        Slack support
      </.nav_link_external>
      <.nav_link_external
        :if={@support_channels.email?}
        href={@support_mailto}
        icon="product.support"
      >
        Email support
      </.nav_link_external>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link_external(assigns) do
    ~H"""
    <.link
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="emisar-icon-mono flex items-center gap-3 rounded-lg px-3 py-1.5 text-zinc-400 transition hover:bg-white/[0.04] hover:text-zinc-100"
    >
      <.icon name={@icon} class="h-4 w-4" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <.icon name="action.external_link" class="h-3.5 w-3.5 text-zinc-500" />
    </.link>
    """
  end

  attr :label, :string, required: true

  defp nav_group(assigns) do
    ~H"""
    <div class="pb-1 pt-2.5 first:pt-0">
      <p class="px-3 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
        {@label}
      </p>
    </div>
    """
  end

  attr :current_user, :map, required: true
  attr :current_account, :map, required: true
  attr :current_membership, :map, default: nil

  defp shell_user(assigns) do
    ~H"""
    <div class="border-t border-zinc-800/70 p-4 text-sm">
      <div class="flex items-center gap-3">
        <.link
          navigate={~p"/app/#{@current_account}/settings/profile"}
          phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
          class="flex min-w-0 flex-1 items-center gap-3 rounded-lg p-1 -m-1 transition hover:bg-white/[0.04]"
          aria-label="Open profile settings"
        >
          <.avatar
            name={Accounts.member_display_name(@current_membership, @current_user)}
            size={:sm}
          />
          <div class="min-w-0 flex-1">
            <div class="truncate font-medium">
              {Accounts.member_display_name(@current_membership, @current_user)}
            </div>
            <div
              :if={email = Accounts.secondary_user_email(@current_user)}
              class="truncate text-xs text-zinc-400"
            >
              {email}
            </div>
          </div>
        </.link>
        <.link
          href={~p"/sign_out"}
          method="delete"
          class="grid h-8 w-8 shrink-0 place-items-center rounded-md text-zinc-500 transition hover:bg-zinc-900 hover:text-zinc-200"
          title="Sign out"
          aria-label="Sign out"
        >
          <.icon name="action.sign_out" class="h-4 w-4" />
        </.link>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true

  attr :badge, :any,
    default: nil,
    doc:
      "Optional notification count rendered as a pill on the right edge. `nil` / `0` / `false` " <>
        "hide the badge; positive integers render as e.g. `3`; values ≥ 100 render as `99+` so " <>
        "the pill never overflows the rail."

  attr :alert, :boolean,
    default: false,
    doc:
      "A small amber alert dot on the right edge (e.g. the whole fleet is offline), independent " <>
        "of the count `badge`. Pair with `alert_label` for the screen-reader text."

  attr :alert_label, :string, default: nil, doc: "Visually-hidden text announcing the alert dot."

  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <%!-- Active = the house light wash + bright text, with the ICON carrying
         the one quiet brand signal — the old filled green pill (fill + ring)
         was the last admin-template artifact in the shell, and green-as-
         selection diluted "emerald = passed the gate".

         `emisar-icon-mono`: a nav icon LABELS a destination, it never reports a
         state, so its colour is the row's own resting/active colour and the
         registry's semantic accents are switched off. Left on, the rail lit
         half its icons emerald at rest and the active row lost its signal. --%>
    <.link
      navigate={@to}
      phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
      class={[
        "emisar-icon-mono flex items-center gap-3 rounded-lg px-3 py-1.5 transition",
        @active && "bg-white/[0.06] font-medium text-zinc-50",
        !@active && "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100"
      ]}
    >
      <%!-- The icon rides the ROW's tone (resting zinc-400, hover zinc-100)
           rather than sitting a step dimmer: a low-contrast 1.5px stroke reads
           as haze, and the rail's icons were fainter than their own labels.
           Active keeps the one brand signal. --%>
      <.icon name={@icon} class={"h-4 w-4 #{if @active, do: "text-brand-400"}"} />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <span
        :if={badge_visible?(@badge)}
        class="rounded-full bg-amber-500/20 px-2 py-0.5 text-[10px] font-semibold leading-none tabular-nums text-amber-200 ring-1 ring-inset ring-amber-500/30"
      >
        {badge_label(@badge)}
      </span>
      <span :if={@alert} class="h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400" aria-hidden="true"></span>
      <span :if={@alert} class="sr-only">{@alert_label}</span>
    </.link>
    """
  end

  defp badge_visible?(n) when is_integer(n) and n > 0, do: true
  defp badge_visible?(_), do: false

  defp badge_label(n) when is_integer(n) and n >= 100, do: "99+"
  defp badge_label(n) when is_integer(n), do: Integer.to_string(n)
end
