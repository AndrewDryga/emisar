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
     "# nomad-hvn03 · Dell R640 · Pure FlashArray //M50 over iSCSI multipath · democratic-csi"},
    {2, "server", "srv-prompt", "curl -sSL https://emisar.dev/install.sh | sudo bash"},
    {3, "server", "srv-install", "downloading emisar-v0.2.0-linux-amd64.tar.gz"},
    {4, "server", "srv-install", "checksum verified  sha256:9f2c1e7b4a0d…  ·  installed v0.2.0"},
    {5, "server", "srv-banner",
     "emisar connecting to wss://app.emisar.dev/runner (group=storage packs=storage,nomad,debugging,docker)"},
    {6, "server", "srv-ok", "runner online · nomad-hvn03 · advertising 58 actions"},

    # --- Claude Code: the alarm, then investigate through emisar -----
    {7, "llm", "cc-meta", "emisar MCP connected · 58 tools · scoped to nomad-hvn03"},
    {8, "llm", "cc-user",
     "grafana shows the last 7 days of metrics flat — only the last 12 minutes are alive. the process is healthy and ingesting. where did 33 hours of data go?"},
    {9, "llm", "cc-spin", "Investigating"},
    {10, "llm", "cc-text",
     "That pattern means the storage moved out from under VictoriaMetrics. I'll walk the layers through emisar — declared actions, no SSH."},
    {11, "llm", "cc-tool",
     "emisar · storage.csi_volume_ls(volume: \"vm-data\", reason: \"inspect the LUN behind VictoriaMetrics\")"},
    {12, "llm", "cc-result", "drwx------ 2 root root 16384 lost+found"},
    {13, "llm", "cc-result-cont",
     "# a fresh ext4, born 30 minutes ago — the 33h of history isn't on it"},
    {14, "llm", "cc-tool",
     "emisar · debugging.dmesg_tail(lines: 400, reason: \"what happened at mount time?\")"},
    {15, "llm", "cc-result",
     "13:11:03  device-mapper: multipath 254:3: queue_if_no_path enabled"},
    {16, "llm", "cc-result-cont",
     "13:11:09  EXT4-fs (dm-3): mounted filesystem clean   # 6 seconds, no active path group"},
    {17, "llm", "cc-tool",
     "emisar · docker.logs(container: \"democratic-csi\", lines: 2000, reason: \"did the driver format it?\")"},
    {18, "llm", "cc-result", "GetDiskFormat /dev/mapper/3624…265c → blkid output=\"\" (empty)"},
    {19, "llm", "cc-result-cont",
     "\"unformatted\" → mkfs.ext4 -F /dev/mapper/3624… → \"successfully formatted\"   # over a live LUN"},
    {20, "llm", "cc-spin", "Analyzing"},
    {21, "llm", "cc-text",
     "Root cause: a multipath path-group race. On migration every path came up queue-ready but none active — blkid read empty, democratic-csi took \"empty\" for \"unformatted\" and ran mkfs over the live LUN. It's kubernetes#95183. VictoriaMetrics is writing fresh parts over the old blocks now — I need to stop it."},

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

    # --- Claude Code: confirm, then codify the fix as a PR ----------
    {28, "llm", "cc-result", "alloc a1b2c3d4 stopped · writes halted · LUN frozen for forensics"},
    {29, "llm", "cc-spin", "Writing the fix"},
    {30, "llm", "cc-text",
     "Bleed stopped on your one approval. A host-side fix wouldn't survive the next drain, so the durable one goes where it belongs — a Terraform PR for you to review."},
    {31, "llm", "cc-tool",
     "git · open PR \"csi: never auto-format on blkid-empty (the 33h wipe)\""},
    {32, "llm", "cc-result",
     "+ node { format { disabled = true } }   # refuse to mkfs a \"blank\" device"},
    {33, "llm", "cc-result-cont",
     "+ multipath-watchdog.nomad.hcl · format-new-volume.sh (xfs, no overwrite) · alerts/multipath.yaml"},
    {34, "llm", "cc-text",
     "Done — investigated through declared actions, stopped the bleed behind one approval, durable fix handed back as a diff you merge, every step on the audit trail. Honest note: emisar can't stop the driver's mkfs; it changes everything you and the agent do around the failure."}
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
      class="mx-auto mt-16 max-w-4xl overflow-hidden rounded-xl border border-zinc-800 bg-[#0c0c0e] shadow-2xl shadow-indigo-950/40 ring-1 ring-white/5"
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
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium text-indigo-300 transition hover:text-indigo-200"
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
          <p class="text-sm font-semibold text-indigo-400">Legal</p>
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
                      class="-ml-px block border-l border-transparent py-1 pl-4 text-sm text-zinc-400 transition hover:border-indigo-400 hover:text-zinc-100"
                    >
                      {label}
                    </a>
                  </li>
                </ul>
              </nav>
            </aside>

            <article class="prose prose-invert max-w-none prose-headings:scroll-mt-8 prose-headings:font-bold prose-headings:tracking-tight prose-headings:text-zinc-50 prose-h2:mb-4 prose-h2:mt-12 prose-h2:text-2xl prose-p:leading-8 prose-p:text-zinc-400 prose-a:font-medium prose-a:text-indigo-300 prose-a:no-underline hover:prose-a:text-indigo-200 prose-strong:text-zinc-200 prose-li:text-zinc-400 prose-li:marker:text-zinc-600">
              {render_slot(@inner_block)}
            </article>
          </div>
        </div>
      </section>

      <.marketing_footer />
    </div>
    """
  end
end
