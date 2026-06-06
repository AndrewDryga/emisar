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

  # The home page "watch emisar work" terminal. One incident, told as an
  # ordered transcript across two tabs: the host (real shell + Go-runner
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
    # --- Host: degraded, then install the runner -------------------
    {1, "server", "srv-comment",
     "# prod-api-3 · Ubuntu 22.04 · api.service degraded — 502s climbing, load high"},
    {2, "server", "srv-prompt", "curl -sSL https://emisar.dev/install.sh | sudo bash"},
    {3, "server", "srv-install", "install target: linux/amd64 via systemd"},
    {4, "server", "srv-install", "downloading emisar-v0.2.0-linux-amd64.tar.gz"},
    {5, "server", "srv-install", "checksum verified  sha256:9f2c1e7b4a0d…"},
    {6, "server", "srv-install", "installing binary to /usr/local/bin/emisar"},
    {7, "server", "srv-install", "installed: emisar v0.2.0"},
    {8, "server", "srv-install", "starting emisar.service"},
    {9, "server", "srv-banner",
     "emisar connecting to wss://app.emisar.dev/runner (group=default packs=2 actions=96)"},
    {10, "server", "srv-ok", "runner online · prod-api-3 · advertising 96 actions"},

    # --- Claude Code: investigate ----------------------------------
    {11, "llm", "cc-meta", "emisar MCP connected · 96 tools · scoped to prod-api-3"},
    {12, "llm", "cc-user",
     "prod-api-3 is throwing 502s and the load is through the roof. what's going on?"},
    {13, "llm", "cc-spin", "Triaging"},
    {14, "llm", "cc-text", "On it — pulling the host's vitals through emisar."},
    {15, "llm", "cc-tool", "emisar · debugging.loadavg(reason: \"triage 502s on prod-api-3\")"},
    {16, "llm", "cc-result", "load average: 38.21, 31.40, 18.92   (8 cores)"},
    {17, "llm", "cc-tool",
     "emisar · debugging.processes_top(sort: \"cpu\", reason: \"find the CPU hog\")"},
    {18, "llm", "cc-result", "PID     %CPU  STARTED  COMMAND"},
    {19, "llm", "cc-result-cont", "24317   782%  14:02    python /opt/jobs/reindex.py"},
    {20, "llm", "cc-result-cont", "880      6%   Apr18    postgres: api"},
    {21, "llm", "cc-spin", "Analyzing"},
    {22, "llm", "cc-text",
     "Found it — a runaway reindex job (pid 24317) has pinned all 8 cores since 14:02, starving api.service. I'll terminate it."},
    {23, "llm", "cc-tool",
     "emisar · debugging.kill_pid(pid: 24317, reason: \"runaway reindex starving prod-api-3\")"},
    {24, "llm", "cc-pending",
     "⏸ pending approval — kill_pid is high-risk; a human approves in the portal"},
    {25, "llm", "cc-spin-wait", "Waiting for approval"},
    {26, "llm", "cc-approved", "✓ approved by you · one use · audit event recorded"},

    # --- Host: the runner executes the approved action -------------
    {27, "server", "srv-log",
     "level=INFO msg=\"run dispatched\" action=debugging.kill_pid run=run_8f3a2c via=approval"},
    {28, "server", "srv-log",
     "level=INFO msg=\"run complete\" action=debugging.kill_pid exit=0 dur=0.41s"},

    # --- Claude Code: confirm + wrap up ----------------------------
    {29, "llm", "cc-result", "[24317] SIGTERM → python /opt/jobs/reindex.py  (terminated)"},
    {30, "llm", "cc-spin", "Verifying"},
    {31, "llm", "cc-tool",
     "emisar · debugging.loadavg(reason: \"confirm prod-api-3 recovered\")"},
    {32, "llm", "cc-result", "load average: 1.07, 4.90, 12.30   (8 cores)"},
    {33, "llm", "cc-text",
     "Done — load's back to ~1.0 and prod-api-3 is serving 200s again. The kill is on the record in the audit trail, tied to your approval."}
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
            <.icon name="hero-server-stack" class="h-3.5 w-3.5" /> prod-api-3
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
end
