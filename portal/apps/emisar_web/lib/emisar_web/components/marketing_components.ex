defmodule EmisarWeb.MarketingComponents do
  @moduledoc """
  The public marketing site's own components — the nav, footer, hero heading,
  CTA buttons and the brand marks.

  Split out of CoreComponents, which had grown to 6,836 lines and 92 components
  across four audiences that share nothing. These render on server-rendered
  marketing pages and the auth chrome; none of them belongs on an operator
  console screen.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents
  alias EmisarWeb.TimeHelpers

  # -- emisar-specific layout helpers -----------------------------------

  @doc """
  Brand mark used across the marketing site, auth flows, onboarding,
  and the in-app shell. With `wordmark` (default) it renders the full
  horizontal lockup — the gate icon plus the emisar wordmark — otherwise
  just the icon. Both SVGs bake the dark-theme white + emerald palette,
  so they render correctly on any zinc-950 background without tinting.
  """
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :wordmark, :boolean, default: true
  attr :class, :string, default: nil

  def brand(assigns) do
    ~H"""
    <img
      src={
        if @wordmark, do: ~p"/images/brand/emisar-logo.svg", else: ~p"/images/brand/emisar-icon.svg"
      }
      alt="emisar"
      class={[brand_mark_class(@size, @wordmark), @class]}
    />
    """
  end

  defp brand_mark_class(:sm, true), do: "h-7 w-auto"

  defp brand_mark_class(:md, true), do: "h-9 w-auto"

  defp brand_mark_class(:lg, true), do: "h-11 w-auto"

  defp brand_mark_class(:sm, false), do: "h-7 w-7"

  defp brand_mark_class(:md, false), do: "h-9 w-9"

  defp brand_mark_class(:lg, false), do: "h-11 w-11"

  @doc """
  The trailing "→" of a forward CTA (link or button), sliding right when its
  enclosing `group` is hovered — ONE animated-arrow shape so every
  call-to-action reads the same. **The parent link/button MUST carry
  `class="group"`.** Inherits the current text colour (so it takes on the link's
  tone); `class` overrides the size, default `h-3.5 w-3.5`.

      <.link navigate={~p"/x"} class="group … text-brand-400">
        Connect an agent <.cta_arrow />
      </.link>
  """
  attr :class, :string, default: "h-3.5 w-3.5"

  def cta_arrow(assigns) do
    ~H"""
    <.icon
      name="hero-arrow-right"
      class={"shrink-0 transition-transform duration-150 group-hover:translate-x-0.5 #{@class}"}
    />
    """
  end

  # -- Marketing chrome ------------------------------------------------

  @doc """
  Top nav for marketing pages. Pass `current` to highlight the active
  link, and `current_user` so a signed-in visitor sees a Dashboard link
  instead of the Sign in / Start free CTAs.

      <.marketing_nav current={:pricing} current_user={@current_user} />
  """
  attr :current, :atom, default: nil
  attr :current_user, :any, default: nil
  attr :sticky, :boolean, default: false

  def marketing_nav(assigns) do
    ~H"""
    <header class={[
      "border-b border-zinc-900/80 bg-zinc-950/80 backdrop-blur",
      @sticky && "sticky top-0 z-50"
    ]}>
      <div class="mx-auto flex max-w-7xl items-center justify-between px-6 py-5 lg:px-8">
        <.link href={~p"/"}>
          <.brand size={:md} />
        </.link>

        <%!-- Desktop nav: visible md+. Five items — use cases (proof),
             security (trust), pricing, packs (the catalog), and docs. The
             "what your AI gains" pitch leads the home page itself now;
             Changelog and About live in the footer. --%>
        <nav class="hidden items-center gap-8 md:flex">
          <.marketing_nav_link href={~p"/use-cases"} active={@current == :use_cases}>
            Use cases
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/security"} active={@current == :security}>
            Security
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/pricing"} active={@current == :pricing}>
            Pricing
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/packs"} active={@current == :packs}>
            Packs
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/docs"} active={@current == :docs}>Docs</.marketing_nav_link>
        </nav>

        <%!-- Desktop CTAs: visible md+. A signed-in visitor gets a
             Dashboard link; everyone else gets Sign in / Start free. --%>
        <div class="hidden items-center gap-4 md:flex">
          <%= if @current_user do %>
            <.marketing_button size={:sm} href={~p"/app"} icon="hero-arrow-right">
              Dashboard
            </.marketing_button>
          <% else %>
            <.link
              href={~p"/sign_in"}
              class="whitespace-nowrap text-sm font-semibold text-zinc-100 hover:text-brand-300"
            >
              Sign in
            </.link>
            <.marketing_button size={:sm} href={~p"/sign_up"}>Start free</.marketing_button>
          <% end %>
        </div>

        <%!-- Mobile hamburger: visible < md. Toggles the drawer
             below; uses the same JS dance as the in-app shell so
             the body lock works the same. --%>
        <button
          type="button"
          aria-label="Open menu"
          aria-controls="marketing-mobile-nav"
          aria-expanded="false"
          data-mobile-nav-open
          class="-mr-1.5 rounded-md p-2.5 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 md:hidden"
        >
          <.icon name="hero-bars-3" class="h-5 w-5" />
        </button>
      </div>
    </header>

    <%!-- Mobile menu — the "gate". A full-screen takeover (a SIBLING of
         <header>, so the header's `backdrop-blur` doesn't trap this fixed
         overlay in the nav bar) over the SAME contract-grid + grain as the hero,
         so it reads as the site folding open. The routes are nodes on the gate's
         vertical track — the current page lit emerald, like the logo's middle
         node — and reveal in stagger. Toggled by mobile_nav.js (focus-trapped). --%>
    <div
      id="marketing-mobile-nav"
      class="fixed inset-0 z-50 hidden bg-[#07080a] md:hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Site menu"
    >
      <div class="flex h-full flex-col">
        <%!-- Top bar — mirrors the page nav (same border-b + bg-zinc-950/80 backdrop-blur,
             same px-6 py-5 + <.brand size={:md}/>), so the menu reads as the same chrome and
             the checkered body below it lines up with the hero's grid (both sit below an
             equal-height nav). --%>
        <div class="flex shrink-0 items-center justify-between border-b border-zinc-900/80 bg-zinc-950/80 px-6 py-5 backdrop-blur">
          <.link href={~p"/"}>
            <.brand size={:md} />
          </.link>
          <button
            type="button"
            aria-label="Close menu"
            data-mobile-nav-close
            class="-mr-1.5 rounded-md p-2.5 text-zinc-400 transition hover:bg-zinc-900 hover:text-zinc-100"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <%!-- Body — the hero surface below the bar: the SAME .contract-grid + .grain, which
             fade in with the routes + CTAs as the menu opens. --%>
        <div class="relative flex-1">
          <div
            class="contract-grid mobile-nav-grid pointer-events-none absolute inset-0"
            aria-hidden="true"
          >
          </div>
          <div class="grain pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="absolute inset-0 overflow-y-auto">
            <div class="flex min-h-full flex-col">
              <nav class="relative flex flex-1 flex-col px-6 pb-8 pt-8">
                <%!-- the gate track the route-nodes sit on --%>
                <span
                  class="pointer-events-none absolute bottom-16 left-[2.125rem] top-16 w-px -translate-x-1/2 bg-gradient-to-b from-transparent via-zinc-700/60 to-transparent"
                  aria-hidden="true"
                ></span>
                <ul class="flex flex-1 flex-col justify-around">
                  <li>
                    <.marketing_gate_link
                      href={~p"/use-cases"}
                      active={@current == :use_cases}
                      idx={1}
                    >
                      Use cases
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/security"} active={@current == :security} idx={2}>
                      Security
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/pricing"} active={@current == :pricing} idx={3}>
                      Pricing
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/packs"} active={@current == :packs} idx={4}>
                      Packs
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/docs"} active={@current == :docs} idx={5}>
                      Docs
                    </.marketing_gate_link>
                  </li>
                </ul>
              </nav>

              <div class="rise-5 relative px-6 pb-9">
                <.scan_line class="mb-7 opacity-50" />
                <div class="space-y-3">
                  <%= if @current_user do %>
                    <.marketing_button block href={~p"/app"} icon="hero-arrow-right">
                      Dashboard
                    </.marketing_button>
                  <% else %>
                    <.marketing_button block href={~p"/sign_up"}>Start free</.marketing_button>
                    <.marketing_button variant={:secondary} block href={~p"/sign_in"}>
                      Sign in
                    </.marketing_button>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  "Use your coding agent" cross-sell — a paste-ready prompt that makes the
  reader's agent run this page's flow via the customer skill (`skills/` on
  GitHub). One recognizable shape on the marketing docs pages and the console
  rails: a collapsed-by-default disclosure (border-only, §8.1 — no wash) whose
  sparkles summary row opens to the caller-written sentence, the copyable
  prompt box, and a quiet read-the-skill link.

  `prompt` is ONE line (it soft-wraps in the box; a single-line attribute
  string survives `mix format`, where escape sequences in attrs would not) and
  reads like something the operator would type: the task, any credential
  placeholder, and the skill's raw SKILL.md URL.

      <.agent_skill_cta
        skill="install-emisar"
        prompt="Install the emisar runner … Use the install-emisar skill: https://…/SKILL.md"
      >
        The <code>install-emisar</code>
        skill walks your agent through this whole page.
      </.agent_skill_cta>
  """
  attr :skill, :string, required: true, doc: "skill directory name under skills/"
  attr :prompt, :string, required: true, doc: "one-line paste-ready prompt, incl. the skill URL"
  attr :class, :string, default: nil
  slot :inner_block, required: true, doc: "one sentence: what the agent will do"

  def agent_skill_cta(assigns) do
    assigns = assign(assigns, :prompt_id, "skill-prompt-" <> assigns.skill)

    ~H"""
    <details class={[
      "group overflow-hidden rounded-xl border border-zinc-800 text-sm leading-7",
      @class
    ]}>
      <summary class="flex cursor-pointer items-center gap-3 px-5 py-4 transition-colors hover:bg-zinc-900/30 [&::-webkit-details-marker]:hidden">
        <.icon name="hero-sparkles" class="h-5 w-5 flex-none text-brand-300" />
        <strong class="min-w-0 flex-1 text-zinc-100">Use your coding agent</strong>
        <.icon
          name="hero-chevron-down"
          class="h-5 w-5 shrink-0 text-zinc-500 transition duration-200 group-hover:text-zinc-300 group-open:rotate-180 group-open:text-brand-400"
        />
      </summary>
      <div class="border-t border-zinc-900 px-5 pb-5 pt-4">
        <p class="text-zinc-400">
          {render_slot(@inner_block)}
        </p>
        <div class="mt-3 overflow-hidden rounded-lg border border-zinc-900 bg-black/40">
          <div class="flex items-center justify-between gap-3 border-b border-zinc-900 bg-zinc-950/80 px-3.5 py-1.5">
            <span class="font-mono text-[10px] uppercase tracking-widest text-zinc-500">
              paste into your agent
            </span>
            <button
              type="button"
              data-copy={"#" <> @prompt_id}
              class="font-mono text-[11px] font-medium text-zinc-400 transition-colors hover:text-zinc-200"
            >
              Copy
            </button>
          </div>
          <pre
            id={@prompt_id}
            class="whitespace-pre-wrap p-3.5 font-mono text-xs leading-5 text-zinc-300"
          >{@prompt}</pre>
        </div>
        <p class="mt-2.5 text-xs text-zinc-500">
          Works in Claude Code, Codex, or any agent that reads Markdown skills — <.external_link
            href={"https://github.com/andrewdryga/emisar/tree/main/skills/" <> @skill}
            class="font-medium text-brand-300/90 hover:text-brand-200"
          >read the skill first</.external_link>.
        </p>
      </div>
    </details>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :idx, :integer, default: 1, doc: "1-based position, for the staggered rise on open"
  slot :inner_block, required: true

  defp marketing_gate_link(assigns) do
    ~H"""
    <.link href={@href} class={["group flex items-center gap-4 py-4", "rise-#{@idx}"]}>
      <%!-- the route's node on the gate track; lit emerald when it's the
           current page, like the logo's middle node (a request passing). --%>
      <span class="relative flex h-5 w-5 shrink-0 items-center justify-center" aria-hidden="true">
        <span class={[
          "rounded-full ring-[5px] ring-zinc-950 transition",
          @active && "h-2.5 w-2.5 bg-brand-400 shadow-[0_0_16px_3px] shadow-brand-400/40",
          !@active && "h-2 w-2 bg-zinc-700 group-hover:bg-brand-400/70"
        ]}></span>
      </span>
      <span class={[
        "text-2xl font-semibold tracking-tight transition",
        @active && "text-white",
        !@active && "text-zinc-400 group-hover:text-white"
      ]}>
        {render_slot(@inner_block)}
      </span>
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp marketing_nav_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "relative text-sm font-medium transition",
        @active && "text-zinc-100",
        !@active && "text-zinc-400 hover:text-zinc-100"
      ]}
    >
      {render_slot(@inner_block)}
      <%!-- Subtle brand underline on the active page so the
           current section is identifiable without reading the URL. --%>
      <span
        :if={@active}
        class="absolute -bottom-1 left-0 right-0 h-0.5 rounded-full bg-brand-400"
        aria-hidden="true"
      />
    </.link>
    """
  end

  @doc """
  The one call-to-action button for the marketing site — every "Start free",
  "Get started", "Talk to sales", "Read the docs"-style button routes through
  here so they stay visually identical across the 27 pages. The in-app
  `<.button>` is a separate visual world; marketing buttons live here.

  Renders an `<.link>` when given `href`/`navigate` in `:rest`, otherwise a
  `<button>` (so it works for the sign-up form's submit). Pass `external` for
  an outbound link (adds `target="_blank"` + the `noopener noreferrer` rel),
  and `icon` for a trailing heroicon (the conventional right-arrow affordance).

      <.marketing_button navigate={~p"/sign_up"} icon="hero-arrow-right">Start free</.marketing_button>
      <.marketing_button variant={:secondary} navigate={~p"/docs"}>Read the docs</.marketing_button>
      <.marketing_button external href="https://github.com/...">Read the source</.marketing_button>
  """
  attr :variant, :atom, default: :primary, values: [:primary, :secondary]
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :block, :boolean, default: false, doc: "full-width (pricing-card buttons)"
  attr :external, :boolean, default: false, doc: "outbound link — opens a new, isolated tab"
  attr :icon, :string, default: nil, doc: ~s(trailing heroicon, e.g. "hero-arrow-right")
  attr :type, :string, default: nil, doc: ~s(button type when rendering a <button>, e.g. "submit")
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch form name value)
  slot :inner_block, required: true

  def marketing_button(%{external: true} = assigns) do
    ~H"""
    <.link
      target="_blank"
      rel="noopener noreferrer"
      class={marketing_button_class(@variant, @size, @block, @class)}
      {@rest}
    >
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </.link>
    """
  end

  def marketing_button(%{rest: rest} = assigns)
      when is_map_key(rest, :href) or is_map_key(rest, :navigate) or is_map_key(rest, :patch) do
    ~H"""
    <.link class={marketing_button_class(@variant, @size, @block, @class)} {@rest}>
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </.link>
    """
  end

  def marketing_button(assigns) do
    ~H"""
    <button type={@type} class={marketing_button_class(@variant, @size, @block, @class)} {@rest}>
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </button>
    """
  end

  # Base: inline flex + gap so a trailing icon sits tight, rounded-lg pill,
  # one type ramp. `block` makes it a full-width card button (pricing tiers).
  defp marketing_button_class(variant, size, block, extra) do
    [
      if(block, do: "flex w-full", else: "inline-flex"),
      "group/btn items-center justify-center gap-2 whitespace-nowrap rounded-lg text-sm font-semibold transition active:scale-[0.96] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950",
      marketing_button_size(size),
      marketing_button_variant(variant),
      extra
    ]
  end

  defp marketing_button_size(:sm), do: "px-4 py-2"

  defp marketing_button_size(:md), do: "px-5 py-2.5"

  defp marketing_button_size(:lg), do: "px-6 py-3"

  defp marketing_button_variant(:primary), do: "bg-brand-500 text-zinc-950 hover:bg-brand-400"

  defp marketing_button_variant(:secondary),
    do: "bg-transparent text-zinc-100 ring-1 ring-zinc-800 hover:ring-zinc-700"

  @doc """
  Heading for marketing pages — the type scale lives here so headings at the
  same level look the same across pages. Pass `tag` (the semantic level, kept
  as-is per page — this never changes the HTML hierarchy) and `scale` (the
  visual size). `:hero` is the standard page title; `:display` is the larger
  top-level-landing title (home, pricing, security, about, docs index).

      <.marketing_heading tag="h1" scale={:hero}>Quickstart</.marketing_heading>
      <.marketing_heading tag="h1" scale={:display} class="mt-2">Pricing</.marketing_heading>
  """
  attr :tag, :string, required: true, values: ~w(h1 h2 h3)
  attr :scale, :atom, default: :hero, values: [:display, :hero, :section]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def marketing_heading(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "text-balance font-display font-bold text-zinc-50",
        marketing_heading_scale(@scale),
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  defp marketing_heading_scale(:display),
    do: "text-4xl/[1.1] tracking-[-0.035em] sm:text-6xl/[1.1] md:text-7xl/[1.1]"

  defp marketing_heading_scale(:hero), do: "text-4xl tracking-[-0.03em] md:text-5xl"
  # Big centered section header (CTA blocks, "How it works" section tops).

  defp marketing_heading_scale(:section), do: "text-4xl tracking-[-0.03em] sm:text-5xl"

  @doc """
  Conversion CTA for the foot of a marketing page — a convinced reader gets
  one obvious next step. The primary action is always "Start free"; pass a
  contextual secondary (`secondary_label` + `secondary_path`, the latter a
  `~p` route, a `mailto:`, or — with `secondary_external` — an off-site URL).
  `note` defaults to the free-tier reassurance.
  """
  attr :headline, :string, required: true
  attr :subcopy, :string, required: true
  attr :secondary_label, :string, required: true
  attr :secondary_path, :string, required: true

  attr :secondary_external, :boolean,
    default: false,
    doc: "secondary CTA is an outbound link — opens a new, isolated tab"

  attr :note, :string, default: "Three runners. Seven-day audit. No credit card."

  def marketing_cta(assigns) do
    ~H"""
    <section class="pb-24 sm:pb-32">
      <div class="mx-auto max-w-3xl px-6 lg:px-8">
        <div class="relative overflow-hidden rounded-xl border border-brand-500/30 bg-zinc-950 p-8 text-center sm:p-10">
          <div class="glow-emerald pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="grain pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="relative">
            <h2 class="text-2xl font-bold tracking-tight text-white sm:text-3xl">{@headline}</h2>
            <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-zinc-400">{@subcopy}</p>
            <div class="mt-7 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <.marketing_button
                href={~p"/sign_up"}
                icon="hero-arrow-right"
                class="w-full sm:w-auto"
              >
                Start free
              </.marketing_button>
              <.marketing_button
                variant={:secondary}
                external={@secondary_external}
                href={@secondary_path}
                class="w-full sm:w-auto"
              >
                {@secondary_label}
              </.marketing_button>
            </div>
            <p class="mt-4 text-xs text-zinc-400">{@note}</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ============================================================
  #  Marketing "gate" kit
  #
  #  The brand mark is an emerald gate (images/brand/emisar-icon.svg); these
  #  primitives carry it across the marketing site (see design-creative-director):
  #  `gate_mark` is the logo icon, `scan_line` marks the decision point, and
  #  `state_chip` shows what the gate decided. The accent is `brand-*` (the
  #  exact logo green); pass/pending/deny stay emerald/amber/rose so they
  #  match `<.chip>`/`<.risk_pill>`. Marketing-only — the operator console
  #  keeps its own calm system.
  # ============================================================

  @doc """
  The emisar gate mark — the logo icon as an inline SVG: an ink chevron and an
  emerald chevron flanking a vertical track of three nodes, the middle one
  emerald (a request passing the gate). Inline so it inherits `currentColor`
  for the ink and sits in flows at any size. `animate` pulses the three nodes
  top-to-bottom (a request crossing); base opacity is full, so reduced-motion
  lands them lit and static. The mark is decorative, so it is `aria-hidden`.

      <.gate_mark class="h-9 w-9 text-zinc-100" />
      <.gate_mark animate class="h-12 w-12 sm:h-14 sm:w-14" />
  """
  attr :animate, :boolean, default: false
  attr :class, :string, default: "h-12 w-12"

  def gate_mark(assigns) do
    ~H"""
    <svg viewBox="-18 0 390 390" class={@class} fill="none" aria-hidden="true">
      <g stroke-linejoin="round" stroke-linecap="butt" stroke-width="37">
        <path d="M96 50 L19.5 195 L96 340" stroke="currentColor" />
        <path d="M258 50 L334.5 195 L258 340" stroke="#36E6A5" />
      </g>
      <line x1="177" y1="84" x2="177" y2="153" stroke="currentColor" stroke-width="16" />
      <line x1="177" y1="237" x2="177" y2="306" stroke="currentColor" stroke-width="16" />
      <circle
        cx="177"
        cy="42.5"
        r="34.5"
        stroke="currentColor"
        stroke-width="14"
        class={@animate && "gate-dot"}
      />
      <circle
        cx="177"
        cy="195"
        r="34.5"
        stroke="#36E6A5"
        stroke-width="14"
        class={@animate && "gate-dot gate-dot-2"}
      />
      <circle
        cx="177"
        cy="347.5"
        r="34.5"
        stroke="currentColor"
        stroke-width="14"
        class={@animate && "gate-dot gate-dot-3"}
      />
    </svg>
    """
  end

  @doc """
  Footer for marketing pages. Same on every page.
  """
  def marketing_footer(assigns) do
    # Render timestamp is stamped per request (server-rendered marketing has no
    # LiveView caching) — behind a CDN/edge it freezes at cache time, so if it
    # trails the real clock the footer is being served from a stale cache. Pairs
    # with the build version as a two-part freshness signal (which build · when
    # rendered).
    assigns =
      assigns
      |> assign(:app_version, EmisarWeb.AppVersion.version())
      |> assign(:rendered_at, TimeHelpers.forensic_time(DateTime.utc_now()))

    ~H"""
    <footer class="border-t border-zinc-800/70 bg-zinc-950">
      <div class="mx-auto max-w-7xl px-6 py-16 lg:px-8">
        <%!-- Product-updates capture — the considered buyer's low-commitment
             path. A server-rendered POST: marketing has no LiveView, so the
             flash renders via the app layout and the redirect anchors back here
             (#updates) rather than jumping to the page top. Honeypot + CSRF + a
             citext-unique idempotent guard back it. --%>
        <div
          id="updates"
          class="mb-12 flex flex-col gap-6 border-b border-zinc-900 pb-12 sm:flex-row sm:items-center sm:justify-between"
        >
          <div>
            <h2 class="font-display text-sm font-semibold tracking-[-0.01em] text-zinc-100">
              Product updates
            </h2>
            <p class="mt-1 max-w-md text-sm text-zinc-400">
              The occasional note when we ship something major — new packs, features, and security
              improvements. No noise.
            </p>
          </div>
          <.form for={%{}} action={~p"/subscribe"} class="w-full sm:w-auto" data-subscribe>
            <input type="hidden" name="source" value="footer" />
            <%!-- Honeypot — hidden from people, tempting to bots. --%>
            <input
              type="text"
              name="company"
              tabindex="-1"
              autocomplete="off"
              aria-hidden="true"
              class="hidden"
            />
            <div class="flex max-w-sm gap-2">
              <label for="subscribe-email" class="sr-only">Email address</label>
              <input
                type="email"
                id="subscribe-email"
                name="email"
                autocomplete="email"
                required
                placeholder="you@company.com"
                class="min-w-0 flex-1 rounded-md border border-zinc-800 bg-zinc-900/60 px-3 py-2 text-sm text-zinc-100 placeholder:text-zinc-600 focus-visible:border-brand-500 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-brand-500"
              />
              <.marketing_button type="submit" variant={:secondary} size={:sm}>
                Subscribe
              </.marketing_button>
            </div>
            <p class="mt-2 text-xs text-zinc-400">
              No spam, just product news. See our <.link
                navigate={~p"/privacy"}
                class="text-zinc-400 underline decoration-zinc-700 underline-offset-2 hover:text-zinc-300"
              >privacy policy</.link>.
            </p>
          </.form>
        </div>

        <div class="grid grid-cols-1 gap-12 lg:grid-cols-4">
          <div>
            <.link href={~p"/"}>
              <.brand size={:md} />
            </.link>
            <p class="mt-4 max-w-xs text-sm text-zinc-400">
              The best way to give your AI agents access to production.
            </p>
            <p class="mt-3 max-w-xs text-xs leading-relaxed text-zinc-400">
              The runner, MCP bridge, and packs are Apache-2.0 open source; the control-plane
              source is available under the <a
                href="https://github.com/andrewdryga/emisar/blob/main/LICENSE.md"
                target="_blank"
                rel="noopener noreferrer"
                class="text-zinc-400 hover:text-zinc-200"
              >Business Source License</a>, converting to Apache-2.0 per release.
            </p>
          </div>

          <div class="grid grid-cols-2 gap-8 sm:grid-cols-3 lg:col-span-3 lg:grid-cols-5">
            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Product</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/how-it-works"} class="text-zinc-400 hover:text-zinc-100">
                    How it works
                  </.link>
                </li>
                <li>
                  <.link href={~p"/packs"} class="text-zinc-400 hover:text-zinc-100">Packs</.link>
                </li>
                <li>
                  <.link href={~p"/pricing"} class="text-zinc-400 hover:text-zinc-100">Pricing</.link>
                </li>
                <li>
                  <.link href={~p"/security"} class="text-zinc-400 hover:text-zinc-100">
                    Security
                  </.link>
                </li>
                <li>
                  <.link href={~p"/zero-trust"} class="text-zinc-400 hover:text-zinc-100">
                    Zero Trust
                  </.link>
                </li>
                <li>
                  <.link href={~p"/docs"} class="text-zinc-400 hover:text-zinc-100">Docs</.link>
                </li>
                <li>
                  <.link href={~p"/guides"} class="text-zinc-400 hover:text-zinc-100">Guides</.link>
                </li>
                <li>
                  <.link href={~p"/changelog"} class="text-zinc-400 hover:text-zinc-100">
                    Changelog
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Use cases</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link
                    href={~p"/use-cases/csi-data-loss"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    The 33-hour wipe
                  </.link>
                </li>
                <li>
                  <.link href={~p"/use-cases/ingress-502"} class="text-zinc-400 hover:text-zinc-100">
                    The fleet-wide 502
                  </.link>
                </li>
                <li>
                  <.link href={~p"/use-cases"} class="text-zinc-400 hover:text-zinc-100">
                    All use cases
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Compare</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/compare/raw-ssh-for-ai"} class="text-zinc-400 hover:text-zinc-100">
                    SSH vs emisar
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/compare/custom-mcp-server"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    Custom MCP vs emisar
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/compare/copy-paste-ai-ops"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    Copy-paste workflow vs emisar
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Company</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/about"} class="text-zinc-400 hover:text-zinc-100">About</.link>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    GitHub <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <a
                    href={
                      Application.get_env(:emisar_web, :status_page_url, "https://status.emisar.dev")
                    }
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    Status <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <.link href={~p"/support"} class="text-zinc-400 hover:text-zinc-100">Support</.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Legal</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/trust"} class="text-zinc-400 hover:text-zinc-100">
                    Trust &amp; compliance
                  </.link>
                </li>
                <li>
                  <.link href={~p"/privacy"} class="text-zinc-400 hover:text-zinc-100">Privacy</.link>
                </li>
                <li>
                  <.link href={~p"/terms"} class="text-zinc-400 hover:text-zinc-100">Terms</.link>
                </li>
                <li>
                  <.link href={~p"/dpa"} class="text-zinc-400 hover:text-zinc-100">DPA</.link>
                </li>
                <li>
                  <.link href={~p"/refund-policy"} class="text-zinc-400 hover:text-zinc-100">
                    Refund Policy
                  </.link>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar/blob/main/.github/SECURITY.md"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    Security policy
                    <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar/blob/main/LICENSE.md"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    License <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="mt-12 flex flex-col gap-2 border-t border-zinc-800/70 pt-8 text-xs text-zinc-400 sm:flex-row sm:items-center sm:justify-between">
          <span>
            © {Date.utc_today().year} <a
              href="https://dryga.com"
              target="_blank"
              rel="noopener noreferrer"
              class="text-zinc-400 underline-offset-2 hover:text-zinc-200 hover:underline"
            >Andrii Dryga</a>. All rights reserved.
          </span>
          <span>
            v{@app_version}
            <span
              class="text-zinc-400"
              title="Server-render time (UTC). If it trails the real clock, a CDN/edge is serving this page from cache."
            >
              · {@rendered_at}
            </span>
            — built with
            <a
              href="https://coop.dryga.com/"
              target="_blank"
              rel="noopener noreferrer"
              class="text-zinc-400 underline-offset-2 hover:text-zinc-200 hover:underline"
            >
              co:op
            </a>
          </span>
        </div>
      </div>
    </footer>
    """
  end
end
