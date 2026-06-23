defmodule EmisarWeb.MarketingHTML do
  @moduledoc """
  Templates for the public marketing site.

  See the `marketing_html` directory for all templates available.
  """
  use EmisarWeb, :html

  embed_templates "marketing_html/*"

  # Hero icon for an action row in the pack-detail action list. `exec`
  # = lightning (runs a binary), `script` = code-bracket (packaged shell
  # script). Defaults to cube for any future kinds.
  def action_icon("exec"), do: "hero-bolt"
  def action_icon("script"), do: "hero-code-bracket"
  def action_icon(_), do: "hero-cube"

  # Heroicon per pack-registry category (slug from PacksRegistry.@pack_categories).
  # The icon varies for scannability; the accent stays brand — one accent, by design.
  def category_icon("databases"), do: "hero-circle-stack"
  def category_icon("containers"), do: "hero-cube"
  def category_icon("observability"), do: "hero-chart-bar"
  def category_icon("web"), do: "hero-globe-alt"
  def category_icon("cloud"), do: "hero-cloud"
  def category_icon("networking"), do: "hero-signal"
  def category_icon("storage"), do: "hero-server-stack"
  def category_icon("linux"), do: "hero-command-line"
  def category_icon("runtimes"), do: "hero-code-bracket"
  def category_icon("security"), do: "hero-lock-closed"
  def category_icon(_), do: "hero-cube-transparent"

  # The home page "watch emisar work" terminal. One incident — a CSI driver
  # reformats a live LUN and wipes 33h of metrics — told as an ordered
  # transcript across two tabs: the host (nomad-hvn03: real shell + Go-runner
  # output) and the LLM (a faithful Claude Code session). `data-seq` is
  # the play order that `assets/js/emisar_demo.js` reads; per-kind styling
  # (the prompt, `[install]`, the ⏺/⎿ glyphs, colors, indents) lives in
  # the `.demo-*` rules in app.css. Server lines mirror install.sh +
  # `banner()`/slog output; the LLM lines mirror Claude Code's UI.
  #
  # `spin`/`spin-wait` are JS-only animated spinners — rendered `hidden`
  # so no-JS visitors and crawlers skip them; their text is the gerund the
  # spinner shows.
  @demo_lines [
    # --- Host: a storage node on the fleet, one curl to connect ------
    {1, "server", "srv-comment",
     "# nomad-hvn03 · Dell R640 · Pure FlashArray over iSCSI multipath · democratic-csi v1.9.5"},
    {2, "server", "srv-prompt", "curl -sSL https://emisar.dev/install.sh | sudo bash"},
    {3, "server", "srv-install", "downloading emisar-v0.2.0-linux-amd64.tar.gz"},
    {4, "server", "srv-install", "checksum verified  sha256:9f2c1e7b4a0d…  ·  installed v0.2.0"},
    {5, "server", "srv-banner",
     "emisar connecting to wss://emisar.dev/runner/socket/websocket (group=storage packs=multipath,iscsi,pure,nomad,debugging,docker)"},
    {6, "server", "srv-ok",
     "runner online · nomad-hvn03 · advertising 84 actions, every one policy-gated"},

    # --- Claude Code: the alarm, then investigate through emisar -----
    {7, "llm", "cc-meta", "emisar MCP connected · 84 tools · scoped to nomad-hvn03"},
    {8, "llm", "cc-user",
     "grafana shows the last 7 days of metrics flat — only the last 12 minutes are alive. the process is healthy and ingesting. where did 33 hours of data go?"},
    {9, "llm", "cc-spin", "Investigating"},
    {10, "llm", "cc-text",
     "A flat week with only the last 12 minutes alive means VictoriaMetrics restarted onto empty storage. So I'll follow the data: look at its volume, then the kernel log from when it was mounted, then the CSI driver that mounted it."},
    {11, "llm", "cc-tool",
     "emisar · fs.ls_long(path: \"…/vm-data\", reason: \"what's actually on the VictoriaMetrics volume?\")"},
    {12, "llm", "cc-result", "drwx------ 2 root root 16384 lost+found"},
    {13, "llm", "cc-result-cont",
     "# a brand-new, empty ext4 — born 30 minutes ago. The 33h of history isn't here."},
    {14, "llm", "cc-tool",
     "emisar · debugging.dmesg_tail(lines: 400, reason: \"what happened at mount time?\")"},
    {15, "llm", "cc-result",
     "13:11:03  device-mapper: multipath 254:3: queue_if_no_path enabled"},
    {16, "llm", "cc-result-cont",
     "13:11:09  EXT4-fs (dm-3): mounted a clean filesystem   # 6 seconds — with no active path"},
    {17, "llm", "cc-tool",
     "emisar · docker.logs(container: \"democratic-csi\", lines: 2000, reason: \"did the CSI driver format it?\")"},
    {18, "llm", "cc-result", "GetDiskFormat /dev/mapper/3624…265c → blkid output=\"\" (empty)"},
    {19, "llm", "cc-result-cont",
     "\"unformatted\" → mkfs.ext4 -F /dev/mapper/3624… → \"successfully formatted\"   # over a LIVE LUN"},
    {20, "llm", "cc-spin", "Analyzing"},
    {21, "llm", "cc-text",
     "Root cause: a multipath path-group race. On migration every path came up queue-ready but none active, so the first read returned empty — democratic-csi took \"empty\" for \"unformatted\" and reformatted the live LUN. It's the known CSI bug kubernetes#95183. VictoriaMetrics is overwriting the old blocks right now, so the first move is to stop the writes."},

    # --- Claude Code: stop the bleed — one approval -----------------
    {22, "llm", "cc-tool",
     "emisar · nomad.alloc_stop(alloc: \"a1b2c3d4\", reason: \"CSI reformatted a live LUN — halt writes to preserve recoverable blocks\")"},
    {23, "llm", "cc-pending",
     "⏸ pending approval — nomad.alloc_stop is high-risk; a human approves in the portal"},
    {24, "llm", "cc-spin-wait", "Waiting for approval"},
    {25, "llm", "cc-approved", "✓ approved by you · one use · audit event recorded"},

    # --- Host: the runner executes the approved stop ----------------
    {26, "server", "srv-log",
     "level=INFO msg=\"run dispatched\" action=nomad.alloc_stop run=run_5d36c9 via=approval"},
    {27, "server", "srv-log",
     "level=INFO msg=\"run complete\" action=nomad.alloc_stop exit=0 dur=0.38s"},

    # --- Claude Code: verify the obvious fix in the source, then ship it
    {28, "llm", "cc-result", "alloc a1b2c3d4 stopped · writes halted · LUN frozen for forensics"},
    {29, "llm", "cc-text",
     "Writes are stopped. Now a durable fix — it goes in the infra repo, since a host change won't survive the next drain. The driver has a node.format.disabled flag that should prevent this; I'll check the source before relying on it."},
    {30, "llm", "cc-spin", "Checking the driver source"},
    {31, "llm", "cc-tool",
     "gh · democratic-csi/democratic-csi@v1.9.5 — read NodeStageVolume in src/driver/index.js"},
    {32, "llm", "cc-result",
     "async NodeStageVolume(call) { … await filesystem.formatDevice(device, fs_type) }"},
    {33, "llm", "cc-result-cont",
     "# formatDevice runs mkfs unconditionally, and nothing on this path reads node.format.disabled — it's a no-op in v1.9.5."},
    {34, "llm", "cc-text",
     "So the flag won't help. I'll shadow mkfs inside the CSI container so the driver can't reformat a live Pure LUN, and still set format.disabled (commented) so we pick up the upstream fix when it lands."},
    {35, "llm", "cc-tool",
     "git · open PR \"csi: guard against the driver reformatting live LUNs\""},
    {36, "llm", "cc-result", "1 file changed, 38 insertions(+)"},
    {37, "llm", "cc-diff-note", "@@ template local/driver-config.yaml @@"},
    {38, "llm", "cc-diff-ctx", "  node:"},
    {39, "llm", "cc-diff-add", "+    format:"},
    {40, "llm", "cc-diff-add",
     "+      # ignored by v1.9.5 (filesystem.formatDevice); kept for when upstream honors it"},
    {41, "llm", "cc-diff-add", "+      disabled: true"},
    {42, "llm", "cc-diff-note", "@@ task node · shadow mkfs before exec democratic-csi @@"},
    {43, "llm", "cc-diff-add",
     "+  for n in mkfs mkfs.ext4 mkfs.xfs …; do mv \"$d/$n\" \"$d/$n.real\"; cp guard \"$d/$n\"; done"},
    {44, "llm", "cc-diff-note", "@@ new file local/mkfs.guard @@"},
    {45, "llm", "cc-diff-add", "+  case \"$dev\" in /dev/*) ;; *) exec \"$real\" \"$@\" ;; esac"},
    {46, "llm", "cc-diff-add",
     "+  grep -qiE 'nvme|Pure|FlashArray' \"$sys/model\" || exec \"$real\" \"$@\"   # local disk → real mkfs"},
    {47, "llm", "cc-diff-add",
     "+  [ \"$(blkid -o value -s TYPE \"$dev\")\" = ext4 ] && exit 0   # re-attach → no-op"},
    {48, "llm", "cc-diff-add",
     "+  exit 64   # blank or unsure on a live Pure LUN → refuse, never mkfs"},
    {49, "llm", "cc-text",
     "33 hours of metrics are gone — overwritten before I caught the writes. The disk is frozen if you want to attempt recovery. The PR keeps format.disabled for when upstream honors it, and adds mkfs.guard so the driver can't mkfs a mounted Pure LUN. Review and merge before the next node drain."}
  ]

  @doc """
  Interactive "watch emisar work" terminal for the home page. The full
  incident is server-rendered in two panes (one per tab) so no-JS visitors
  and crawlers get the whole story and the tabs degrade to a readable,
  stacked transcript. `assets/js/emisar_demo.js` enhances it into a tabbed,
  typed replay with Claude-style spinners (and honors
  `prefers-reduced-motion`). CSP-safe — no inline script.
  """
  def emisar_demo(assigns) do
    assigns =
      assigns
      |> assign(:server_lines, Enum.filter(@demo_lines, fn {_, tab, _, _} -> tab == "server" end))
      |> assign(:llm_lines, Enum.filter(@demo_lines, fn {_, tab, _, _} -> tab == "llm" end))

    ~H"""
    <div
      data-emisar-demo
      class="mx-auto mt-16 max-w-4xl overflow-hidden rounded-xl border border-zinc-800 bg-[#0c0c0e] shadow-2xl shadow-brand-950/40 ring-1 ring-white/5"
    >
      <div class="flex items-center gap-4 border-b border-zinc-800/80 bg-zinc-950/60 px-4 py-2.5">
        <div class="flex items-center gap-1.5">
          <span class="h-3 w-3 rounded-full bg-[#ff5f57]"></span>
          <span class="h-3 w-3 rounded-full bg-[#febc2e]"></span>
          <span class="h-3 w-3 rounded-full bg-[#28c840]"></span>
        </div>
        <div class="flex items-center gap-1" role="tablist" aria-label="emisar demo">
          <button
            type="button"
            role="tab"
            data-demo-tab="server"
            aria-selected="true"
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <.icon name="hero-server-stack" class="h-3.5 w-3.5" /> nomad-hvn03
          </button>
          <button
            type="button"
            role="tab"
            data-demo-tab="llm"
            aria-selected="false"
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <.icon name="hero-sparkles" class="h-3.5 w-3.5 text-[#d97757]" /> claude
          </button>
        </div>
      </div>

      <div
        data-demo-screen
        class="h-[26rem] overflow-y-auto px-5 py-4 font-mono text-[12.5px] leading-[1.7] [scrollbar-width:thin]"
      >
        <div data-demo-pane="server">
          <.demo_line
            :for={{seq, tab, kind, text} <- @server_lines}
            seq={seq}
            tab={tab}
            kind={kind}
            text={text}
          />
        </div>
        <div data-demo-pane="llm" hidden>
          <.demo_line
            :for={{seq, tab, kind, text} <- @llm_lines}
            seq={seq}
            tab={tab}
            kind={kind}
            text={text}
          />
        </div>
      </div>

      <div class="flex items-center justify-between border-t border-zinc-800/80 bg-zinc-950/60 px-4 py-2">
        <p class="text-[11px] text-zinc-500">
          Real catalog actions. Reads run on policy; risky steps always stop for approval.
        </p>
        <button
          type="button"
          data-demo-replay
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium text-brand-300 transition hover:text-brand-200"
        >
          <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> Replay
        </button>
      </div>
    </div>
    """
  end

  attr :seq, :integer, required: true
  attr :tab, :string, required: true
  attr :kind, :string, required: true
  attr :text, :string, required: true

  # Spinner lines are JS-only — render them hidden so no-JS/crawlers skip
  # them. phx-no-format keeps {@text} tight against the tags (otherwise the
  # formatter reflows it and the indentation leaks into the rendered text,
  # which the typing animation's textContent read would then pick up).
  defp demo_line(assigns) do
    ~H"""
    <div
      data-demo-line
      data-tab={@tab}
      data-kind={@kind}
      data-seq={@seq}
      class={["demo-line", "demo-#{@kind}"]}
      hidden={@kind in ["cc-spin", "cc-spin-wait"]}
      phx-no-format
    >{@text}</div>
    """
  end

  attr :title, :string, required: true
  attr :updated, :string, required: true
  attr :summary, :string, default: nil

  attr :toc, :list,
    required: true,
    doc: "List of {anchor_id, label}; ids must match the id on each section's <h2> in the body."

  slot :inner_block, required: true

  @doc """
  Shared layout for the legal pages (Terms, Privacy, Refund). Renders the
  marketing chrome, a compact header (title + last-updated date + an
  optional plain-language summary), a sticky table of contents on desktop
  built from `toc`, and the body as readable prose. Keeping the chrome in
  one place is what keeps the three legal pages consistent.
  """
  def legal_page(assigns) do
    ~H"""
    <div class="bg-zinc-950 text-zinc-100">
      <.marketing_nav current={:legal} />

      <header class="border-b border-zinc-900">
        <div class="mx-auto max-w-5xl px-6 py-16 sm:py-20 lg:px-8">
          <p class="text-sm font-semibold text-brand-400">Legal</p>
          <h1 class="mt-2 text-4xl font-bold tracking-tight text-zinc-50 sm:text-5xl">
            {@title}
          </h1>
          <p class="mt-4 text-sm text-zinc-500">Last updated {@updated}</p>
          <p :if={@summary} class="mt-6 max-w-2xl text-base leading-7 text-zinc-400">
            {@summary}
          </p>
        </div>
      </header>

      <section class="py-14 sm:py-16">
        <div class="mx-auto max-w-5xl px-6 lg:px-8">
          <div class="lg:grid lg:grid-cols-[15rem_1fr] lg:gap-14">
            <aside class="hidden lg:block">
              <nav class="sticky top-12" aria-label="On this page">
                <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                  On this page
                </p>
                <ul class="mt-4 space-y-1 border-l border-zinc-800">
                  <li :for={{id, label} <- @toc}>
                    <a
                      href={"##{id}"}
                      data-toc-link={id}
                      class="-ml-px block border-l border-transparent py-1.5 pl-4 text-sm text-zinc-400 transition hover:border-brand-400 hover:text-zinc-100"
                    >
                      {label}
                    </a>
                  </li>
                </ul>
              </nav>
            </aside>

            <%!-- Legal body styling via element-targeted arbitrary variants
                 (NOT @tailwindcss/typography — that plugin isn't installed, so
                 every `prose-*` class was a silent no-op). Section dividers on
                 each h2, airy paragraph spacing, brighter lead-in strongs. --%>
            <article class="text-base text-zinc-400 [&_h2]:mb-5 [&_h2]:mt-14 [&_h2]:scroll-mt-24 [&_h2]:border-t [&_h2]:border-zinc-900 [&_h2]:pt-14 [&_h2]:text-2xl [&_h2]:font-bold [&_h2]:tracking-tight [&_h2]:text-balance [&_h2]:text-zinc-50 [&>h2:first-of-type]:mt-0 [&>h2:first-of-type]:border-t-0 [&>h2:first-of-type]:pt-0 [&_p]:my-7 [&_p]:leading-8 [&_p]:text-zinc-400 [&_strong]:font-semibold [&_strong]:text-zinc-100 [&_ul]:my-7 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_li]:text-zinc-400 [&_li]:marker:text-zinc-600 [&_a]:font-medium [&_a]:text-brand-300 [&_a:hover]:text-brand-200 [&_code]:rounded [&_code]:bg-zinc-900 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.85em] [&_code]:text-zinc-300">
              {render_slot(@inner_block)}
            </article>
          </div>
        </div>
      </section>

      <.marketing_footer />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :dek, :string, required: true, doc: "the standfirst / sub-headline"
  attr :date, :string, required: true
  attr :read_time, :string, required: true
  slot :inner_block, required: true

  @doc """
  Shared layout for a /guides article — the top-of-funnel long-form pages.
  Renders the marketing chrome, a header (back-link + title + dek + date and
  read-time), the body as readable single-column prose, and a conversion CTA.
  Same element-targeted styling as `legal_page` (the typography plugin isn't
  installed), extended for h3 / ordered lists / blockquotes.
  """
  def guide_page(assigns) do
    ~H"""
    <div class="bg-zinc-950 text-zinc-100">
      <.marketing_nav current={:guides} />

      <header class="border-b border-zinc-900 bg-[#07080a]">
        <div class="mx-auto max-w-3xl px-6 py-16 sm:py-20 lg:px-8">
          <.breadcrumbs items={[{"Guides", ~p"/guides"}, {@title, nil}]} />
          <h1 class="mt-6 text-4xl font-bold tracking-tight text-zinc-50 text-balance sm:text-5xl">
            {@title}
          </h1>
          <p class="mt-5 text-lg leading-relaxed text-zinc-300 text-pretty">{@dek}</p>
          <p class="mt-6 text-sm text-zinc-500">{@date} &middot; {@read_time}</p>
        </div>
      </header>

      <section class="py-14 sm:py-16">
        <div class="mx-auto max-w-3xl px-6 lg:px-8">
          <article class="text-base [&_blockquote]:my-6 [&_blockquote]:border-l-2 [&_blockquote]:border-brand-500/40 [&_blockquote]:pl-5 [&_blockquote]:text-zinc-300 [&_code]:rounded [&_code]:bg-zinc-900 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.85em] [&_code]:text-zinc-300 [&_h2]:mb-5 [&_h2]:mt-14 [&_h2]:scroll-mt-24 [&_h2]:border-t [&_h2]:border-zinc-900 [&_h2]:pt-12 [&_h2]:text-2xl [&_h2]:font-bold [&_h2]:tracking-tight [&_h2]:text-balance [&_h2]:text-zinc-50 [&>h2:first-of-type]:mt-0 [&>h2:first-of-type]:border-t-0 [&>h2:first-of-type]:pt-0 [&_h3]:mb-3 [&_h3]:mt-10 [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:text-zinc-100 [&_p]:my-6 [&_p]:leading-8 [&_p]:text-zinc-400 [&_strong]:font-semibold [&_strong]:text-zinc-100 [&_ul]:my-6 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_ol]:my-6 [&_ol]:list-decimal [&_ol]:space-y-2 [&_ol]:pl-5 [&_li]:text-zinc-400 [&_li]:marker:text-zinc-600 [&_a]:font-medium [&_a]:text-brand-300 [&_a:hover]:text-brand-200">
            {render_slot(@inner_block)}
          </article>
        </div>
      </section>

      <.marketing_cta
        headline="Give your AI agent production access — without the panic."
        subcopy="Start free on the Free plan, or book a walkthrough on your own infrastructure."
        secondary_label="Talk to sales"
        secondary_path="mailto:sales@emisar.dev"
      />

      <.marketing_footer />
    </div>
    """
  end
end
