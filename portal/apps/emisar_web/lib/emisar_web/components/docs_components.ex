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

        <%!-- max-w-2xl caps the reading measure at ~72ch: uncapped, body text
             runs 100+ chars on wide viewports, which reads dense however loose
             the leading is. Code, tables, and figures all fit inside 42rem, so
             one cap on the column keeps every block on the same left edge. --%>
        <div class="min-w-0 max-w-2xl [&_p]:leading-7 [&_li]:leading-7">
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
    <div class="mt-5 overflow-hidden rounded-xl border border-zinc-900 bg-black/40">
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
  A collapsible "Verify this download" block placed under an install command:
  the download-then-verify commands (SLSA provenance + checksum) with THIS
  release's artifact names, so a security team can prove the binary before it
  runs as sudo. `tarball`/`checksums` differ between the runner and the
  emisar-mcp bridge, so each install surface passes its own.
  """
  attr :tarball, :string, required: true
  attr :checksums, :string, required: true

  def docs_verify_download(assigns) do
    commands = """
    # provenance — built by our workflow, from our source
    $ gh attestation verify #{assigns.tarball} --owner andrewdryga
    # checksums — the bytes match what we published
    $ sha256sum -c #{assigns.checksums}\
    """

    assigns = assign(assigns, :commands, commands)

    ~H"""
    <details class="group mt-4 overflow-hidden rounded-lg border border-zinc-900 bg-black/40">
      <summary class="flex cursor-pointer items-center justify-between gap-4 px-5 py-4 text-sm font-semibold text-zinc-100 transition-colors hover:bg-zinc-900/30 [&::-webkit-details-marker]:hidden">
        <span class="flex items-center gap-2">
          <.icon name="hero-shield-check" class="h-4 w-4 text-zinc-500" /> Verify this download first
        </span>
        <.icon
          name="hero-chevron-down"
          class="h-5 w-5 shrink-0 text-zinc-500 transition duration-200 group-hover:text-zinc-300 group-open:rotate-180 group-open:text-brand-400"
        />
      </summary>
      <div class="border-t border-zinc-900 px-5 pb-5 pt-4">
        <p class="text-sm leading-7 text-zinc-400">
          The installer checks the checksum itself; to prove the binary before it runs as <code class="rounded bg-zinc-900 px-1 py-0.5 text-xs">sudo</code>, download it and run these
          first — a green check names our source repository and the release workflow that built it.
        </p>
        <.docs_code phx-no-format label="shell">{@commands}</.docs_code>
        <p class="mt-3 text-xs leading-5 text-zinc-500">
          More on the signing pipeline: <.link
            href="/trust#release-integrity"
            class="text-brand-400 hover:text-brand-300"
          >Release integrity</.link>.
        </p>
      </div>
    </details>
    """
  end

  @doc """
  Which console a walkthrough step happens in.

  A provider guide hops between two consoles — theirs and ours — and the step
  titles alone do not say which ("Create a client secret" is at the provider,
  "Set the identifier claim" is here). Reading the eyebrows down the column tells
  you which tab to be in before you read the step.

      <.docs_step_venue>Okta</.docs_step_venue>
      <.docs_step_venue>emisar</.docs_step_venue>
  """
  slot :inner_block, required: true

  def docs_step_venue(assigns) do
    ~H"""
    <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
      In {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  A captioned docs screenshot that opens fullscreen on click. The window-bar
  `title` and the visible `caption` mark it as a figure OF the console, so a
  screenshot can't be mistaken for the docs page's own UI. Pure CSS lightbox
  (a hidden checkbox toggles a fixed overlay via `peer-checked`) so it works
  on these controller-rendered pages with no JS and no CSP inline. `id` is
  derived from the filename so each figure's checkbox drives only its own
  overlay.
  """
  attr :src, :string, required: true
  attr :alt, :string, required: true
  attr :title, :string, required: true, doc: "window-bar label — the console surface shown"
  attr :caption, :string, default: nil, doc: "one visible sentence under the figure"

  attr :preview_h, :string,
    default: nil,
    doc:
      "cap the inline preview height (a Tailwind max-h class) for very tall shots; the lightbox still shows it whole"

  def docs_screenshot(assigns) do
    assigns =
      assign(assigns, :lb_id, "lb-" <> (assigns.src |> Path.basename() |> Path.rootname()))

    ~H"""
    <figure class="mt-8">
      <div class="overflow-hidden rounded-xl border border-zinc-800 shadow-lg shadow-black/30">
        <div class="flex items-center gap-2 border-b border-zinc-800 bg-zinc-950 px-4 py-2.5 font-mono text-[11px] text-zinc-400">
          <.icon name="hero-window" class="h-3.5 w-3.5" /> {@title}
        </div>
        <input type="checkbox" id={@lb_id} class="peer sr-only" aria-hidden="true" tabindex="-1" />
        <label for={@lb_id} class="group relative block cursor-zoom-in">
          <img
            src={@src}
            alt={@alt}
            loading="lazy"
            class={["w-full", @preview_h && "#{@preview_h} object-cover object-top"]}
          />
          <%!-- Bottom fade only when the preview is height-cropped, so it reads as
               "there's more — expand" rather than an abrupt cut. --%>
          <span
            :if={@preview_h}
            class="pointer-events-none absolute inset-x-0 bottom-0 h-16 bg-gradient-to-t from-zinc-950/90 to-transparent"
          ></span>
          <span class="pointer-events-none absolute right-3 top-3 flex items-center gap-1 rounded-md bg-black/60 px-2 py-1 text-xs font-medium text-brand-300 ring-1 ring-brand-500/30 opacity-0 backdrop-blur transition group-hover:opacity-100">
            <.icon name="hero-arrows-pointing-out" class="h-3.5 w-3.5" /> Expand
          </span>
        </label>
        <label
          for={@lb_id}
          class="fixed inset-0 z-[60] hidden cursor-zoom-out items-center justify-center bg-black/90 p-4 backdrop-blur-sm peer-checked:flex sm:p-10"
        >
          <img src={@src} alt={@alt} class="max-h-full max-w-full rounded-lg shadow-2xl" />
        </label>
      </div>
      <figcaption :if={@caption} class="mt-2.5 text-sm leading-6 text-zinc-500">
        {@caption}
      </figcaption>
    </figure>
    """
  end

  @doc """
  The one callout grammar — a bordered note (`:note`), tip (`:tip`), or
  warning (`:warn`) with a leading icon and an optional bold `title`. Replaces
  the hand-rolled boxes so every docs aside reads the same way. Pass `icon` to
  swap the kind's default glyph for a semantically sharper one (a checklist on
  a prerequisites note) while keeping the kind's box and tint.
  """
  attr :kind, :atom, default: :note, values: [:note, :tip, :warn]
  attr :title, :string, default: nil
  attr :icon, :string, default: nil, doc: "override the kind's default glyph"
  slot :inner_block, required: true

  def docs_callout(assigns) do
    ~H"""
    <div class={["mt-6 flex gap-3 rounded-xl border p-5 text-sm leading-7", docs_callout_box(@kind)]}>
      <.icon
        name={@icon || docs_callout_icon(@kind)}
        class={"mt-1 h-5 w-5 flex-none " <> docs_callout_tint(@kind)}
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
  A self-contained terminal cast. The static transcript renders for no-JS
  visitors and crawlers; `assets/js/terminal_cast.js` types the commands and
  streams the output once it scrolls into view (and honors reduced motion).

  Pass `lines` for a single transcript, or `tabs` — a list of
  `%{id:, label:, icon:, lines:}` — for a tabbed terminal (tab buttons in the
  header, like the home-page demo; each tab plays when selected). Each line is
  `%{k: kind, t: text}` (+ optional `:p` prompt glyph), where kind is
  `cmd` / `llm` (typed) or `out` / `sys` / `ok` / `install` / `note` / `blank`.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "terminal"
  attr :caption, :string, default: nil
  attr :lines, :list, default: nil
  attr :tabs, :list, default: nil
  attr :class, :string, default: nil

  def terminal_cast(assigns) do
    ~H"""
    <figure
      id={@id}
      data-terminal-cast
      class={[
        "mt-8 overflow-hidden rounded-xl border border-zinc-800 bg-[#0c0c0e] shadow-lg shadow-black/30",
        @class
      ]}
    >
      <figcaption class="flex items-center gap-3 border-b border-zinc-800/80 bg-zinc-950/60 px-4 py-2.5">
        <span class="flex items-center gap-1.5" aria-hidden="true">
          <span class="h-3 w-3 rounded-full bg-[#ff5f57]"></span>
          <span class="h-3 w-3 rounded-full bg-[#febc2e]"></span>
          <span class="h-3 w-3 rounded-full bg-[#28c840]"></span>
        </span>
        <div :if={@tabs} class="flex items-center gap-1" role="tablist" aria-label={@label}>
          <button
            :for={{tab, i} <- Enum.with_index(@tabs)}
            type="button"
            role="tab"
            data-cast-tab={tab.id}
            aria-selected={to_string(i == 0)}
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <.icon :if={Map.get(tab, :icon)} name={tab.icon} class="h-3.5 w-3.5" />{tab.label}
          </button>
        </div>
        <span :if={!@tabs} class="font-mono text-xs text-zinc-500">{@label}</span>
      </figcaption>
      <div
        data-cast-screen
        class="max-h-[28rem] overflow-y-auto px-5 py-4 font-mono text-[12.5px] leading-[1.7] [scrollbar-width:thin]"
      >
        <div
          :for={{tab, i} <- Enum.with_index(@tabs || [])}
          data-cast-pane={tab.id}
          hidden={i != 0}
        >
          <.cast_line :for={line <- tab.lines} kind={line.k} prompt={Map.get(line, :p)} text={line.t} />
        </div>
        <.cast_line
          :for={line <- @lines || []}
          :if={!@tabs}
          kind={line.k}
          prompt={Map.get(line, :p)}
          text={line.t}
        />
      </div>
      <figcaption class="flex items-center justify-end gap-3 border-t border-zinc-800/80 bg-zinc-950/60 px-4 py-2">
        <p :if={@caption} class="mr-auto text-[11px] text-zinc-500">{@caption}</p>
        <button
          type="button"
          data-cast-replay
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium text-brand-300 transition hover:text-brand-200"
        >
          <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Replay
        </button>
      </figcaption>
    </figure>
    """
  end

  attr :kind, :string, required: true
  attr :prompt, :string, default: nil
  attr :text, :string, required: true

  defp cast_line(%{kind: "blank"} = assigns) do
    ~H"""
    <div class="h-3" aria-hidden="true"></div>
    """
  end

  # Installer output — the blue prefix install.sh / install-mcp.sh actually
  # prints. Defaults to [install]; pass `p: "install-mcp"` for the MCP installer.
  defp cast_line(%{kind: "install"} = assigns) do
    assigns = assign(assigns, :prefix, assigns.prompt || "install")

    ~H"""
    <div data-cast-line data-kind="install" class="cast-line text-zinc-400" phx-no-format><span class="select-none font-semibold text-sky-400">[{@prefix}]</span> <span data-cast-text>{@text}</span></div>
    """
  end

  # phx-no-format keeps {@text} tight to its span — the JS reads textContent,
  # so leaked template indentation would surface in the typed output.
  defp cast_line(assigns) do
    ~H"""
    <div data-cast-line data-kind={@kind} class={["cast-line", cast_line_tone(@kind)]} phx-no-format><span :if={@prompt} class="select-none text-zinc-500">{@prompt} </span><span data-cast-text>{@text}</span></div>
    """
  end

  defp cast_line_tone("cmd"), do: "text-zinc-100"
  defp cast_line_tone("llm"), do: "text-zinc-100"
  defp cast_line_tone("out"), do: "text-zinc-400"
  defp cast_line_tone("sys"), do: "text-zinc-500"
  defp cast_line_tone("ok"), do: "text-brand-400"
  defp cast_line_tone("warn"), do: "text-amber-400"
  defp cast_line_tone("note"), do: "text-zinc-500"
  defp cast_line_tone(_), do: "text-zinc-400"

  @doc """
  An auto-advancing console screencast built from real captured frames (the
  terminal_cast idea, for console pages — still no video file or player
  library). The server renders the full storyboard — every frame with its step
  label and caption — for no-JS visitors and crawlers;
  `assets/js/console_cast.js` collapses it into a stepped player that plays
  the take once scrolled into view: an overlay cursor travels to each frame's
  `click` point, a click ripple fires, and the next frame crossfades in — so
  the stop-motion reads as the interaction that really produced it. Step tabs
  and Replay stay manual. Honors prefers-reduced-motion: no autoplay, no
  cursor, instant swaps.

  Each `:frame` is one real capture — `src`/`alt` for the image (1600x1475,
  from `./run capture docs loop-*`), `label` for its step tab, `caption` for
  the line under the image. `click` is where the cursor clicks to leave this
  frame ("x,y" percentages of the image, from the capture take's printed
  targets); `spot` ("x,y,w,h" percentages) spotlights one element — the rest
  of the frame dims through the spotlight's punched-hole shadow — with `note`
  as the short label pinned to it. The spotlight and cursor are presentation
  for sighted motion users — captions and alt text carry the story for
  everyone else.
  """
  attr :id, :string, required: true
  attr :class, :string, default: nil

  slot :frame, required: true do
    attr :src, :string, required: true
    attr :alt, :string, required: true
    attr :label, :string, required: true
    attr :caption, :string, required: true
    attr :click, :string
    attr :spot, :string
    attr :note, :string
    attr :spot2, :string
    attr :note2, :string
    attr :spot3, :string
    attr :note3, :string
  end

  def console_cast(assigns) do
    ~H"""
    <figure
      id={@id}
      data-console-cast
      class={[
        "overflow-hidden rounded-xl border border-zinc-800 bg-zinc-950/60 shadow-lg shadow-black/30",
        @class
      ]}
    >
      <figcaption class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-zinc-800/80 bg-zinc-950/60 px-4 py-2.5">
        <span class="flex items-center gap-1.5" aria-hidden="true">
          <span class="h-3 w-3 rounded-full bg-[#ff5f57]"></span>
          <span class="h-3 w-3 rounded-full bg-[#febc2e]"></span>
          <span class="h-3 w-3 rounded-full bg-[#28c840]"></span>
        </span>
        <span
          data-cast-steps
          hidden
          class="flex flex-wrap items-center gap-1"
          role="tablist"
          aria-label="Screencast steps"
        >
          <button
            :for={{frame, index} <- Enum.with_index(@frame)}
            type="button"
            role="tab"
            data-cast-step={index}
            aria-selected={to_string(index == 0)}
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <span class="text-zinc-500">{index + 1}</span>{frame.label}
          </button>
        </span>
      </figcaption>
      <div data-cast-stage class="relative space-y-10 p-4 sm:p-5">
        <div
          :for={{frame, index} <- Enum.with_index(@frame)}
          data-cast-frame={index}
          data-click={frame[:click]}
        >
          <p
            data-cast-frame-label
            class="mb-2 font-mono text-xs font-semibold uppercase tracking-wider text-zinc-500"
          >
            Step {index + 1} · {frame.label}
          </p>
          <%!-- The window clips the frame to a fixed aspect once the player
               takes over (JS adds it); the pan layer then scrolls the page
               INSIDE the window to reach low beats — the console scrolling,
               not the reader's page. No-JS keeps the full storyboard frame. --%>
          <div
            data-cast-window
            class="relative overflow-hidden rounded-lg border border-zinc-800/80"
          >
            <div data-cast-pan class="relative">
              <img
                src={frame.src}
                alt={frame.alt}
                width="1600"
                height="1475"
                loading="lazy"
                class="w-full"
              />
              <%!-- The spotlights (a frame may play up to two in sequence): a
                 transparent hole whose oversized shadow dims everything else in
                 the (overflow-clipped) frame; the label pins to the hole's
                 edge. --%>
              <span
                :for={
                  {spot, note} <- [
                    {frame[:spot], frame[:note]},
                    {frame[:spot2], frame[:note2]},
                    {frame[:spot3], frame[:note3]}
                  ]
                }
                :if={spot}
                data-cast-spot
                data-spot={spot}
                hidden
                aria-hidden="true"
                class="pointer-events-none absolute z-10 rounded-md ring-1 ring-brand-400/70 opacity-0 shadow-[0_0_0_9999px_rgba(9,9,11,0.62)] transition-opacity duration-500"
              >
                <span
                  :if={note}
                  data-cast-spot-label
                  class="absolute left-0 w-max max-w-md rounded-md border border-brand-500/40 bg-zinc-950/95 px-2 py-1 font-mono text-[11px] font-medium leading-relaxed text-brand-300 shadow-lg shadow-black/40"
                >
                  {note}
                </span>
              </span>
            </div>
          </div>
          <p class="mt-3 text-sm leading-6 text-zinc-400">{frame.caption}</p>
        </div>
        <%!-- The shared cursor + click ripple, positioned by JS over the active
             frame's image. Presentation only: hidden from AT, no-JS never sees
             them, reduced-motion never enables them. The cursor's negative
             margins put the arrow TIP on the positioned point. --%>
        <span
          data-cast-cursor
          hidden
          aria-hidden="true"
          class="pointer-events-none absolute z-20 -ml-[5px] -mt-[3px] opacity-0"
        >
          <svg
            width="22"
            height="22"
            viewBox="0 0 24 24"
            class="drop-shadow-[0_1px_2px_rgba(0,0,0,0.8)]"
          >
            <path
              d="M5.5 3.2 19.2 12.6l-6.2 1.1 3.4 6.3-2.8 1.5-3.4-6.4-4.7 4.2z"
              fill="#fafafa"
              stroke="#18181b"
              stroke-width="1.4"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <%!-- Two spans: the outer centers on the click point with static
             negative margins; the inner carries animate-ping, whose keyframe
             transform would otherwise overwrite a centering translate. --%>
        <span
          data-cast-ripple
          hidden
          aria-hidden="true"
          class="pointer-events-none absolute z-10 -ml-4 -mt-4 h-8 w-8"
        >
          <span data-cast-ripple-ring class="block h-8 w-8 rounded-full border-2 border-brand-400/90"></span>
        </span>
      </div>
      <figcaption class="flex items-center justify-between gap-3 border-t border-zinc-800/80 bg-zinc-950/60 px-4 py-2">
        <p class="text-[11px] text-zinc-500">
          The demo workspace, captured as-is — a real request, decision, run, and audit trail.
        </p>
        <button
          type="button"
          data-cast-replay
          hidden
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium text-brand-300 transition hover:text-brand-200"
        >
          <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Replay
        </button>
      </figcaption>
    </figure>
    """
  end

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
