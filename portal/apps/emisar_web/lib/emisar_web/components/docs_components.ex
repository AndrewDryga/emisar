defmodule EmisarWeb.DocsComponents do
  @moduledoc """
  The documentation shell: the shared layout (left nav + content + right
  table of contents), the header block, section headings with anchor links,
  the code surface, the callout grammar, and the prev/next footer that every
  `/docs/*` page renders. The IA comes from `EmisarWeb.DocsNav`; the marketing
  chrome (nav, footer) stays on the page.
  """
  use Phoenix.Component
  import EmisarWeb.CoreComponents
  alias EmisarWeb.DocsNav

  @doc """
  The docs page frame: a sticky grouped nav, the article column (with the
  prev/next footer appended), and — when `toc` is non-empty — a sticky "On
  this page" rail on the widest breakpoint. `toc` is a list of `{anchor_id,
  label}` matching the `docs_h2` ids in the body.
  """
  attr :current, :string, required: true
  attr :toc, :list, default: []
  slot :inner_block, required: true

  def docs_layout(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-6 pb-24 lg:px-8">
      <details class="group mb-8 rounded-xl border border-zinc-900 bg-zinc-950/60 lg:hidden">
        <summary class="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-sm font-semibold text-zinc-100 [&::-webkit-details-marker]:hidden">
          Docs navigation
          <.icon
            name="hero-chevron-down"
            class="h-4 w-4 text-zinc-500 transition-transform group-open:rotate-180"
          />
        </summary>
        <div class="border-t border-zinc-900 px-2 pb-4 pt-2">
          <.docs_nav_groups current={@current} />
        </div>
      </details>

      <div class="lg:grid lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-x-10 xl:grid-cols-[15rem_minmax(0,1fr)_13rem] xl:gap-x-12">
        <%!-- px-2 (not pr-3): the sticky rail is an overflow-y-auto scroll
             container, which clips a child's focus outline (2px width + 2px
             offset) where a link sits flush against the scrollport edge — so
             the nav needs ≥4px horizontal padding on BOTH sides for the ring
             to render whole. --%>
        <nav
          aria-label="Docs"
          class="sticky top-8 hidden max-h-[calc(100vh-4rem)] overflow-y-auto px-2 pb-10 lg:block"
        >
          <.docs_nav_groups current={@current} />
        </nav>

        <div class="min-w-0">
          {render_slot(@inner_block)}
          <.docs_prev_next current={@current} />
        </div>

        <nav
          :if={@toc != []}
          aria-label="On this page"
          class="sticky top-8 hidden max-h-[calc(100vh-4rem)] overflow-y-auto px-2 pb-10 xl:block"
        >
          <p class="font-mono text-[11px] font-semibold uppercase tracking-widest text-zinc-500">
            On this page
          </p>
          <ul class="mt-3 space-y-1.5 border-l border-zinc-900">
            <li :for={{id, label} <- @toc}>
              <a
                href={"#" <> id}
                data-toc-link={id}
                class="-ml-px block border-l-2 border-transparent py-0.5 pl-3.5 text-[13px] leading-snug text-zinc-400 transition-colors hover:text-zinc-200"
              >
                {label}
              </a>
            </li>
          </ul>
        </nav>
      </div>
    </div>
    """
  end

  attr :current, :string, required: true

  defp docs_nav_groups(assigns) do
    ~H"""
    <div :for={{{label, pages}, group_index} <- Enum.with_index(DocsNav.groups())}>
      <p class={[
        "font-mono text-[11px] font-semibold uppercase tracking-widest text-zinc-500",
        if(group_index == 0, do: "mt-0", else: "mt-8")
      ]}>
        {label}
      </p>
      <ul class="mt-3 space-y-0.5">
        <li :for={page <- pages}>
          <.docs_nav_link page={page} current={@current} />
        </li>
      </ul>
    </div>
    """
  end

  attr :page, :map, required: true
  attr :current, :string, required: true

  # No plan tag here on purpose: the nav is wayfinding, and the paywall is
  # already visible before the click on the /docs index row and on the page
  # itself — an amber suffix in a 15rem rail just wraps into noise.
  defp docs_nav_link(assigns) do
    assigns = assign(assigns, :active?, assigns.page.slug == assigns.current)

    ~H"""
    <.link
      href={@page.path}
      aria-current={@active? && "page"}
      class={[
        "block rounded-md px-2.5 py-1.5 text-sm transition-colors",
        @active? && "bg-brand-500/10 font-medium text-brand-300",
        !@active? && "text-zinc-400 hover:bg-zinc-900/60 hover:text-zinc-200"
      ]}
    >
      {@page.title}
    </.link>
    """
  end

  @doc """
  The page header block — breadcrumbs (Docs → group → page), the `:hero`
  title, and an optional lede from the `:dek` slot. Derives the group + title
  from `DocsNav` by `current`. The enclosing section lives on the page.
  """
  attr :current, :string, required: true
  slot :dek

  def docs_header(assigns) do
    assigns =
      assign(assigns,
        page: DocsNav.fetch!(assigns.current),
        group_label: DocsNav.group_label(assigns.current)
      )

    ~H"""
    <.breadcrumbs items={[{"Docs", "/docs"}, {@group_label, nil}, {@page.title, nil}]} />
    <.marketing_heading tag="h1" scale={:hero} class="mt-3">{@page.title}</.marketing_heading>
    <p :if={@dek != []} class="mt-6 text-lg leading-8 text-zinc-400 text-pretty">
      {render_slot(@dek)}
    </p>
    """
  end

  @doc """
  A linkable section heading — the `id` is the TOC anchor and the `#` affordance
  reveals on hover. `scroll-mt-24` keeps the target clear of the sticky nav.
  """
  attr :id, :string, required: true
  slot :inner_block, required: true

  def docs_h2(assigns) do
    ~H"""
    <h2
      id={@id}
      class="group/h mt-12 scroll-mt-24 text-2xl font-semibold text-zinc-50 text-balance"
    >
      {render_slot(@inner_block)}<a
        href={"#" <> @id}
        class="ml-2 text-zinc-700 opacity-0 transition-opacity group-hover/h:opacity-100 hover:text-brand-400"
        aria-label="Link to this section"
      >#</a>
    </h2>
    """
  end

  @doc "A linkable sub-section heading — the smaller sibling of `docs_h2`."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def docs_h3(assigns) do
    ~H"""
    <h3
      id={@id}
      class="group/h mt-8 scroll-mt-24 text-lg font-semibold text-zinc-50 text-balance"
    >
      {render_slot(@inner_block)}<a
        href={"#" <> @id}
        class="ml-2 text-zinc-700 opacity-0 transition-opacity group-hover/h:opacity-100 hover:text-brand-400"
        aria-label="Link to this section"
      >#</a>
    </h3>
    """
  end

  @doc """
  The framed code/terminal surface — an optional `label` header and a Copy
  button wired to the delegated clipboard handler. `copy_text` is the
  paste-ready literal (use it whenever the pre carries display-only chrome — a
  `$` prompt, log output — the reader must not paste); `copy_id` copies the
  `<pre>`'s textContent verbatim and only fits chrome-free content. The slot is
  the preformatted content; call sites carry `phx-no-format` and open the slot
  tight against the tag so the leading whitespace survives.
  """
  attr :label, :string, default: nil
  attr :copy_id, :string, default: nil
  attr :copy_text, :string, default: nil
  slot :inner_block, required: true

  def docs_code(assigns) do
    ~H"""
    <div class="mt-4 overflow-hidden rounded-xl border border-zinc-900 bg-black/40">
      <div
        :if={@label}
        class="flex items-center justify-between border-b border-zinc-900 bg-zinc-950/80 px-4 py-2"
      >
        <span class="font-mono text-[10px] uppercase tracking-widest text-zinc-500">{@label}</span>
        <button
          :if={@copy_text || @copy_id}
          type="button"
          data-copy={if(is_nil(@copy_text), do: "#" <> @copy_id)}
          data-copy-text={@copy_text}
          class="font-mono text-[11px] font-medium text-zinc-400 transition-colors hover:text-zinc-200"
        >
          Copy
        </button>
      </div>
      <pre
        id={@copy_id}
        class="overflow-x-auto p-4 font-mono text-xs leading-6 text-zinc-300"
      >{render_slot(@inner_block)}</pre>
    </div>
    """
  end

  @doc """
  The one callout grammar — a bordered note (`:note`), tip (`:tip`), or
  warning (`:warn`) with a leading icon and an optional bold `title`. Replaces
  the hand-rolled boxes so every docs aside reads the same way.
  """
  attr :kind, :atom, default: :note, values: [:note, :tip, :warn]
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def docs_callout(assigns) do
    ~H"""
    <div class={["mt-6 flex gap-3 rounded-xl border p-5 text-sm leading-6", docs_callout_box(@kind)]}>
      <.icon
        name={docs_callout_icon(@kind)}
        class={"mt-0.5 h-5 w-5 flex-none " <> docs_callout_tint(@kind)}
      />
      <div>
        <strong :if={@title} class="text-zinc-100">{@title}</strong>
        <div class={[
          "space-y-2 text-zinc-400 [&_a]:text-brand-400 [&_a:hover]:text-brand-300",
          @title && "mt-1"
        ]}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp docs_callout_box(:note), do: "border-zinc-800 bg-zinc-950/60"
  defp docs_callout_box(:tip), do: "border-brand-900/40 bg-brand-950/20"
  defp docs_callout_box(:warn), do: "border-amber-900/40 bg-amber-950/15"

  defp docs_callout_icon(:note), do: "hero-information-circle"
  defp docs_callout_icon(:tip), do: "hero-light-bulb"
  defp docs_callout_icon(:warn), do: "hero-exclamation-triangle"

  defp docs_callout_tint(:note), do: "text-zinc-400"
  defp docs_callout_tint(:tip), do: "text-brand-400"
  defp docs_callout_tint(:warn), do: "text-amber-400"

  @doc """
  The prev/next footer, derived from `DocsNav.prev_next/1`. A missing neighbor
  drops its card; when there is no previous page the next card holds column two.
  """
  attr :current, :string, required: true

  def docs_prev_next(assigns) do
    {prev, next} = DocsNav.prev_next(assigns.current)
    assigns = assign(assigns, prev: prev, next: next)

    ~H"""
    <div class="mt-16 grid gap-4 border-t border-zinc-900 pt-8 sm:grid-cols-2">
      <.link
        :if={@prev}
        href={@prev.path}
        class="group rounded-xl border border-zinc-900 p-4 transition-colors hover:border-brand-500/40"
      >
        <p class="text-[11px] font-medium uppercase tracking-wider text-zinc-500">← Previous</p>
        <p class="mt-1 text-sm font-semibold text-zinc-50 group-hover:text-brand-300">
          {@prev.title}
        </p>
      </.link>
      <.link
        :if={@next}
        href={@next.path}
        class={[
          "group rounded-xl border border-zinc-900 p-4 text-right transition-colors hover:border-brand-500/40",
          is_nil(@prev) && "sm:col-start-2"
        ]}
      >
        <p class="text-[11px] font-medium uppercase tracking-wider text-zinc-500">Next →</p>
        <p class="mt-1 text-sm font-semibold text-zinc-50 group-hover:text-brand-300">
          {@next.title}
        </p>
      </.link>
    </div>
    """
  end
end
