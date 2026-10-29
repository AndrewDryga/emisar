defmodule EmisarWeb.MarketingHTML do
  @moduledoc """
  Templates for the public marketing site.

  See the `marketing_html` directory for all templates available.
  """
  use EmisarWeb, :html
  import EmisarWeb.HowItWorksMap
  alias EmisarWeb.SandboxRisks

  embed_templates "marketing_html/*"
  embed_templates "marketing_html/compare/*"
  embed_templates "marketing_html/docs/*"
  embed_templates "marketing_html/guides/*"
  embed_templates "marketing_html/docs/integrations/*"
  embed_templates "marketing_html/use_cases/*"

  attr :text, :string,
    default: nil,
    doc: "one authored setup string — a summary, an env description, or a note"

  @doc """
  Renders one pack-authored setup string with its inline code and links.

  The whole run is emitted on a single source line on purpose: whitespace
  between the segment tags would render as a space inside the reconstructed
  sentence. Every value stays escaped by HEEx, and only `https://` links ever
  reach `setup_segments/1`'s output, so a pack cannot inject markup or a
  hostile scheme onto this public page.
  """
  def setup_text(assigns) do
    assigns = assign(assigns, :segments, EmisarWeb.PacksRegistry.setup_segments(assigns.text))

    ~H"""
    <%= for segment <- @segments do %>
      <%= case segment do %>
        <% {:code, value} -> %>
          <code class="rounded-sm bg-zinc-900 px-1 py-0.5 font-mono text-xs text-zinc-300">{value}</code>
        <% {:link, label, url} -> %>
          <.external_link href={url} class="text-brand-400 hover:text-brand-300">{label}</.external_link>
        <% {:text, value} -> %>
          {value}
      <% end %>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :commands, :list, required: true

  @doc """
  Renders pack-authored setup commands as escaped, copyable text.

  This component is deliberately display-only. The strings come from the
  published pack catalog and are never interpreted or executed by the Portal.
  """
  def setup_command_block(assigns) do
    assigns = assign(assigns, :body, Enum.join(assigns.commands, "\n"))

    ~H"""
    <div class="overflow-hidden rounded-lg border border-zinc-800 bg-black/60">
      <div class="flex items-center justify-between gap-2 border-b border-zinc-800 px-4 py-2">
        <span class="text-[11px] font-medium text-zinc-400">{@label}</span>
        <EmisarWeb.CoreComponents.copy_button id={"copy-#{@id}"} text={@body}>
          Copy
        </EmisarWeb.CoreComponents.copy_button>
      </div>
      <pre
        id={@id}
        class="overflow-x-auto p-4 font-mono text-xs leading-relaxed text-zinc-200"
      ><%= @body %></pre>
    </div>
    """
  end

  attr :included, :boolean, required: true

  def plan_feature_availability(assigns) do
    ~H"""
    <.icon :if={@included} name="state.included" class="h-5 w-5 text-brand-400" />
    <span :if={!@included}>—</span>
    """
  end

  # Icon meaning for an action row in the pack-detail action list. `exec` runs
  # a binary, `script` is a packaged shell script. Any future kind falls back
  # to the pack itself.
  def action_icon("exec"), do: "action.execute"
  def action_icon("script"), do: "interface.api"
  def action_icon(_), do: "product.pack"

  # One lowercased blob per docs-index row for the client-side filter —
  # the page's title, description, its top-level group, its display
  # subgroup, and its optional extra keywords. Building it server-side is
  # what keeps `docs_filter.js` a plain textContent/attribute matcher with
  # no index of its own.
  def docs_search_terms(page, group_label, section_label) do
    [page.title, page.desc, group_label, section_label, page[:keywords]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  # Icon meaning per pack-registry category (slug from
  # `EmisarWeb.PacksRegistry.@pack_categories`).
  # The icon varies for scannability; the accent stays brand — one accent, by design.
  def category_icon("databases"), do: "infrastructure.database"
  def category_icon("containers"), do: "infrastructure.container"
  def category_icon("observability"), do: "story.observability"
  def category_icon("web"), do: "device.web"
  def category_icon("cloud"), do: "infrastructure.cloud"
  def category_icon("networking"), do: "infrastructure.network"
  def category_icon("storage"), do: "infrastructure.host_cluster"
  def category_icon("linux"), do: "interface.cli"
  def category_icon("runtimes"), do: "interface.api"
  def category_icon("security"), do: "security.posture"
  def category_icon(_), do: "pack.reference"

  # The home page "watch emisar work" terminal. One incident — a CSI driver
  # reformats a live LUN and wipes 33h of metrics — told as an ordered
  # transcript across two tabs: the host (nomad-hvn03: real shell + Go-runner
  # output) and the LLM (a faithful Claude Code session). `data-seq` is
  # the play order that `assets/js/emisar_demo.js` reads; per-kind styling
  # (the prompt, `[install]`, the ●/⎿ glyphs, colors, indents) lives in
  # the `.demo-*` rules in app.css. Server lines are install.sh's own log
  # lines and summary for the console's install command (with an explicit
  # EMISAR_PACKS set), `emisar status`, and the runner's slog text lines as
  # `journalctl -o cat` shows them; keep them in step when those change. The
  # LLM lines mirror Claude Code's UI.
  #
  # `spin`/`spin-wait` are JS-only animated spinners — rendered `hidden`
  # so no-JS visitors and crawlers skip them; their text is the gerund the
  # spinner shows.
  @mcp_tool_count EmisarWeb.MCP.SchemaRegistry.tool_count()

  # The hero installs a real runner, so the version it installs comes from the
  # same release policy the console's update hints read. It was a literal and
  # sat eight minors behind the tip.
  @runner_current Application.compile_env(:emisar, [Emisar.Compat, :runner_current])

  @doc "How many tools the MCP surface exposes. See `SchemaRegistry.tool_count/0`."
  def mcp_tool_count, do: @mcp_tool_count

  # ── Shared chrome for the two cloud-connector docs pages ──────────────
  # /docs/connect-chatgpt and /docs/connect-claude-ai hand-copied these three
  # blocks, so a change to the verify contract had to be made twice and the
  # copies were one edit from drifting. The vendor setup steps stay per-page;
  # only the product mechanics that must read identically live here.

  attr :sibling_label, :string, required: true, doc: "the OTHER cloud connector's name"
  attr :sibling_path, :string, required: true

  @doc "The local-clients cross-pointer both cloud-connector pages open with."
  def docs_cloud_connector_pointer(assigns) do
    ~H"""
    <p class="mt-6 text-base leading-7 text-zinc-400">
      Using Claude Code, Cursor, Claude Desktop, or a CLI instead? Those connect through the
      <.docs_inline_code>emisar-mcp</.docs_inline_code>
      stdio bridge (see <.link
        navigate={~p"/docs/connect-cli-agent"}
        class="text-brand-400 hover:text-brand-300"
      >Connect a CLI agent</.link>). For {@sibling_label}, see <.link
        navigate={@sibling_path}
        class="text-brand-400 hover:text-brand-300"
      >{@sibling_label}</.link>.
    </p>
    """
  end

  @doc "Shared cloud-connector prerequisites: runner, endpoint reachability, and signing limits."
  def docs_cloud_connector_prerequisites(assigns) do
    ~H"""
    <.docs_prerequisites>
      <:item>
        An account with at least one runner online. Otherwise the agent signs in fine and finds
        an empty catalog with nothing to call. New here? Run the
        <.link navigate={~p"/docs/quickstart"} class="text-brand-400 hover:text-brand-300">
          quickstart
        </.link>
        first, then come back to connect your LLM.
      </:item>
      <:item>
        A publicly reachable HTTPS server URL. The URL connection in these guides cannot reach
        localhost or a private network address. If you run emisar privately, use a
        <.link
          navigate={~p"/docs/connect-cli-agent"}
          class="text-brand-400 hover:text-brand-300"
        >local AI client</.link>
        that can reach it instead.
      </:item>
      <:item>
        Runners that do not require signed dispatch. Claude.ai and ChatGPT do not create emisar
        dispatch signatures, so a runner that requires one needs the
        <.link
          navigate={~p"/docs/connect-cli-agent"}
          class="text-brand-400 hover:text-brand-300"
        >local MCP bridge</.link>
        with a signing key and certificate instead.
      </:item>
    </.docs_prerequisites>
    """
  end

  @doc "The verify steps — one read-only action, then its audit receipt."
  def docs_cloud_connector_verify(assigns) do
    ~H"""
    <.docs_h2 id="verify">Verify the connection</.docs_h2>
    <ol class="mt-4 list-decimal space-y-3 pl-6 text-base text-zinc-300">
      <li>
        Ask the client to run <code>linux.uptime</code> on any one of the connected runners.
      </li>
      <li>Confirm that the client returns the action output.</li>
      <li>
        Open <a
          href={~p"/app/audit"}
          class="font-medium text-brand-300 underline decoration-brand-500/30 underline-offset-4 hover:text-brand-200"
        >Audit</a>. Confirm that the event records the client, runner, action, and reason.
      </li>
    </ol>
    """
  end

  # ── Sandbox risk copy shared with the Console ──────────────────────────
  # The Console's sandbox setup renders the same EmisarWeb.SandboxRisks with
  # its own components; only the docs styling lives here.

  attr :id, :string, required: true
  attr :sandbox, :string, required: true

  @doc "One sandbox's Limits & risks heading and list."
  def docs_sandbox_risks(assigns) do
    assigns = assign(assigns, :copy, SandboxRisks.fetch!(assigns.sandbox))

    ~H"""
    <.docs_h3 id={@id}>{@copy.title}</.docs_h3>
    <ul class="mt-4 list-disc space-y-3 pl-6 text-base leading-7 text-zinc-400">
      <li :for={risk <- @copy.risks}>
        <.docs_sandbox_segment :for={segment <- risk} segment={segment} />
      </li>
    </ul>
    """
  end

  attr :sandbox, :string, required: true

  @doc "One sandbox's rotation paragraph; the page supplies the heading."
  def docs_sandbox_rotation(assigns) do
    assigns = assign(assigns, :rotation, SandboxRisks.fetch!(assigns.sandbox).rotation)

    ~H"""
    <p class="mt-4 text-base leading-7 text-zinc-400">
      <.docs_sandbox_segment :for={segment <- @rotation} segment={segment} />
    </p>
    """
  end

  # One-line sigils on purpose: a heredoc's trailing newline would put a space
  # between a link and the full stop that follows it.
  attr :segment, :any, required: true

  defp docs_sandbox_segment(%{segment: {:code, code}} = assigns) do
    assigns = assign(assigns, :code, code)
    ~H"<.docs_inline_code>{@code}</.docs_inline_code>"
  end

  defp docs_sandbox_segment(%{segment: {:guide, label, anchor}} = assigns) do
    assigns = assign(assigns, label: label, href: "#" <> anchor)
    ~H|<a href={@href} class="text-brand-400 hover:text-brand-300">{@label}</a>|
  end

  defp docs_sandbox_segment(%{segment: {:link, label, url}} = assigns) do
    assigns = assign(assigns, label: label, href: url)
    ~H|<.link href={@href} class="text-brand-400 hover:text-brand-300">{@label}</.link>|
  end

  defp docs_sandbox_segment(%{segment: {:agents, label}} = assigns) do
    assigns = assign(assigns, :label, label)

    ~H|<a
  href={~p"/app/agents"}
  class="font-medium text-brand-300 underline decoration-brand-500/30 underline-offset-4 hover:text-brand-200"
>{@label}</a>|
  end

  defp docs_sandbox_segment(%{segment: text} = assigns) when is_binary(text) do
    ~H"{@segment}"
  end

  @doc "What the OAuth sign-in grants — membership-bound key, operator-scoped reach."
  def docs_cloud_connector_grants(assigns) do
    ~H"""
    <.docs_h2 id="sign-in-grants">What the sign-in grants</.docs_h2>
    <p class="mt-4 text-base leading-7 text-zinc-400">
      The consent screen mints a key bound to <em>your</em>
      membership. The connector acts as you. Every call is attributed to you and the agent you are using. It reaches
      only the runners and actions your own access already allows (<.link
        navigate={~p"/docs/agents-and-keys#no-scope"}
        class="text-brand-400 hover:text-brand-300"
      >how a key inherits its operator's scope</.link>). Revoke it any time from
      <strong>AI agents</strong>
      in the console, or from the connector settings in Claude or ChatGPT.
    </p>
    """
  end

  @plan_limits Enum.map(~w(free team enterprise), fn slug ->
                 plan = Emisar.Billing.plan(slug)

                 %{
                   name: plan.name,
                   runners: plan.runners_limit,
                   members: plan.members_limit,
                   retention_days: plan.audit_retention_days
                 }
               end)

  @doc """
  Each plan's limits, in plan order, from the billing catalog that enforces
  them. A reference table restating these by hand drifts the moment a limit
  moves; `:unlimited` renders through `plan_limit/1`.
  """
  def plan_limits, do: @plan_limits

  @doc "Renders one plan limit — an integer, or the word for no limit."
  def plan_limit(:unlimited), do: "Unlimited"
  def plan_limit(count) when is_integer(count), do: Integer.to_string(count)

  @demo_lines [
    # --- Host: install the runner (install.sh's real output), confirm it
    # connected, then follow its log so later runs stream in --------
    {1, "server", "srv-comment",
     "# nomad-hvn03 · Dell R640 · Pure FlashArray over iSCSI multipath · democratic-csi v1.9.5"},
    {2, "server", "srv-prompt",
     "curl -fsSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=emkey-enroll-… EMISAR_PACKS=linux-core,debugging,fs-search,docker,nomad bash"},
    {3, "server", "srv-install", "install target: linux/amd64 via systemd"},
    {4, "server", "srv-install", "latest release: runner-v#{@runner_current}"},
    {5, "server", "srv-ask",
     "install emisar runner-v#{@runner_current} to /usr/local/bin/emisar (and configure as a service)? [y/N] y"},
    {6, "server", "srv-install",
     "downloading emisar-#{@runner_current}-linux-amd64.tar.gz from Emisar release mirror"},
    {7, "server", "srv-install",
     "checksum signature verified  AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml"},
    {8, "server", "srv-install", "checksum verified  sha256:9f2c1e7b4a0d5c3e…"},
    {9, "server", "srv-install", "extracting"},
    {10, "server", "srv-install", "staging binary at /usr/local/bin/.emisar-stage.Qw3rTz/emisar"},
    {11, "server", "srv-install", "verified: emisar version #{@runner_current}"},
    {12, "server", "srv-install", "creating system user emisar"},
    {13, "server", "srv-install", "mkdir /etc/emisar"},
    {14, "server", "srv-install", "mkdir /var/lib/emisar"},
    {15, "server", "srv-install", "mkdir /var/log/emisar"},
    {16, "server", "srv-install", "installed binary to /usr/local/bin/emisar"},
    {17, "server", "srv-install", "installed pack linux-core (bundled)"},
    {18, "server", "srv-install", "installed pack debugging (bundled)"},
    {19, "server", "srv-install", "installed pack fs-search (registry)"},
    {20, "server", "srv-install", "installed pack docker (bundled)"},
    {21, "server", "srv-install", "installed pack nomad (registry)"},
    {22, "server", "srv-install", "writing pre-configured config to /etc/emisar/config.yaml"},
    {23, "server", "srv-install", "writing runner.env stub to /etc/emisar/runner.env"},
    {24, "server", "srv-install", "writing /etc/systemd/system/emisar.service"},
    {25, "server", "srv-install", "starting emisar.service"},
    {26, "server", "srv-install", "recorded installer ownership at /etc/emisar/install-receipt"},
    {27, "server", "srv-install", "installed emisar runner-v#{@runner_current}"},
    {28, "server", "srv-out", " "},
    {29, "server", "srv-out", "=============================================================="},
    {30, "server", "srv-out", "emisar runner-v#{@runner_current} installed."},
    {31, "server", "srv-out", " "},
    {32, "server", "srv-out", "Binary:   /usr/local/bin/emisar"},
    {33, "server", "srv-out", "Config:   /etc/emisar/config.yaml"},
    {34, "server", "srv-out", "Secrets:  /etc/emisar/runner.env   (chmod 600)"},
    {35, "server", "srv-out", "Data:     /var/lib/emisar"},
    {36, "server", "srv-out", "Logs:     /var/log/emisar/events.jsonl (security log)"},
    {37, "server", "srv-out", " "},
    {38, "server", "srv-out",
     "Pre-configured from install env (EMISAR_URL + EMISAR_ENROLLMENT_KEY)."},
    {39, "server", "srv-out",
     "Edit /etc/emisar/config.yaml to tighten runner.group / labels later."},
    {40, "server", "srv-out", " "},
    {41, "server", "srv-out", "The service is running. Check the runner connection:"},
    {42, "server", "srv-out", "  sudo /usr/local/bin/emisar status"},
    {43, "server", "srv-prompt", "sudo emisar status"},
    {44, "server", "srv-out", " "},
    {45, "server", "srv-out", "  ✓  connection    connected · heartbeat sent 3s ago"},
    {46, "server", "srv-out",
     "  ✓  catalog       5 packs · 191 actions advertised · all available"},
    {47, "server", "srv-out", "  ✓  process       PID 2214 · up 9s · 1 connection attempt(s)"},
    {48, "server", "srv-out", "  ✓  runs          0 in flight (last reported by the daemon)"},
    {49, "server", "srv-out", "  ✓  checks        7 local readiness checks passed"},
    {50, "server", "srv-out", " "},
    {51, "server", "srv-ok", "Runner is connected and healthy."},
    {52, "server", "srv-prompt", "sudo journalctl -u emisar -f -o cat"},
    {53, "server", "srv-log",
     "time=2026-10-28T13:41:06.873Z level=INFO msg=cloud.dial url=wss://emisar.dev/runner/socket/websocket external_id=nomad-hvn03"},
    {54, "server", "srv-log",
     "time=2026-10-28T13:41:07.412Z level=INFO msg=cloud.connected actions=191 packs=5 inflight_runs=0 requeued_starts=0 requeued_results=0"},

    # --- Claude Code: the alarm, then investigate through emisar -----
    {55, "llm", "cc-meta",
     "emisar MCP connected · #{@mcp_tool_count} tools · scoped to nomad-hvn03"},
    {56, "llm", "cc-user",
     "grafana shows the last 7 days of metrics flat — only the last 12 minutes are alive. the process is healthy and ingesting. where did 33 hours of data go?"},
    {57, "llm", "cc-spin", "Investigating"},
    {58, "llm", "cc-text",
     "A flat week with only the last 12 minutes alive means VictoriaMetrics restarted onto empty storage. So I'll follow the data: look at its volume, then the kernel log from when it was mounted, then the CSI driver that mounted it."},
    {59, "llm", "cc-tool",
     "emisar · fs.ls_long(path: \"…/vm-data\", reason: \"what's actually on the VictoriaMetrics volume?\")"},
    {60, "llm", "cc-result", "drwx------ 2 root root 16384 lost+found"},
    {61, "llm", "cc-result-cont",
     "# a brand-new, empty ext4 — born 30 minutes ago. The 33h of history isn't here."},
    {62, "llm", "cc-tool",
     "emisar · debugging.dmesg_tail(lines: 400, reason: \"what happened at mount time?\")"},
    {63, "llm", "cc-result",
     "13:11:03  device-mapper: multipath 254:3: queue_if_no_path enabled"},
    {64, "llm", "cc-result-cont",
     "13:11:09  EXT4-fs (dm-3): mounted a clean filesystem   # 6 seconds — with no active path"},
    {65, "llm", "cc-tool",
     "emisar · docker.logs(container: \"democratic-csi\", lines: 2000, reason: \"did the CSI driver format it?\")"},
    {66, "llm", "cc-result", "GetDiskFormat /dev/mapper/3624…265c → blkid output=\"\" (empty)"},
    {67, "llm", "cc-result-cont",
     "\"unformatted\" → mkfs.ext4 -F /dev/mapper/3624… → \"successfully formatted\"   # over a LIVE LUN"},
    {68, "llm", "cc-spin", "Analyzing"},
    {69, "llm", "cc-text",
     "Root cause: a multipath path-group race. On migration every path came up queue-ready but none active, so the first read returned empty — democratic-csi took \"empty\" for \"unformatted\" and reformatted the live LUN. It's the known CSI bug kubernetes#95183. VictoriaMetrics is overwriting the old blocks right now, so the first move is to stop the writes."},

    # --- Claude Code: stop the bleed — one approval -----------------
    {70, "llm", "cc-tool",
     "emisar · nomad.alloc_stop(alloc: \"a1b2c3d4\", reason: \"CSI reformatted a live LUN — halt writes to preserve recoverable blocks\")"},
    {71, "llm", "cc-pending",
     "⏸ pending approval — nomad.alloc_stop is high-risk; a human approves in the portal"},
    {72, "llm", "cc-spin-wait", "Waiting for approval"},
    {73, "llm", "cc-approved", "✓ approved by you · one use · audit event recorded"},

    # --- Host: the followed runner log shows the approved stop run ---
    {74, "server", "srv-log",
     "time=2026-10-28T13:47:02.114Z level=INFO msg=cloud.run_started request_id=req_7Hk2pQ9xWm4LsN1vT8cRaA action_id=nomad.alloc_stop"},
    {75, "server", "srv-log",
     "time=2026-10-28T13:47:02.497Z level=INFO msg=cloud.run_finished request_id=req_7Hk2pQ9xWm4LsN1vT8cRaA action_id=nomad.alloc_stop status=success exit_code=0 duration_ms=383 reason=\"\""},

    # --- Claude Code: verify the obvious fix in the source, then ship it
    {76, "llm", "cc-result", "alloc a1b2c3d4 stopped · writes halted · LUN frozen for forensics"},
    {77, "llm", "cc-text",
     "Writes are stopped. Now a durable fix — it goes in the infra repo, since a host change won't survive the next drain. The driver has a node.format.disabled flag that should prevent this; I'll check the source before relying on it."},
    {78, "llm", "cc-spin", "Checking the driver source"},
    {79, "llm", "cc-tool",
     "gh · democratic-csi/democratic-csi@v1.9.5 — read NodeStageVolume in src/driver/index.js"},
    {80, "llm", "cc-result",
     "async NodeStageVolume(call) { … await filesystem.formatDevice(device, fs_type) }"},
    {81, "llm", "cc-result-cont",
     "# formatDevice runs mkfs unconditionally, and nothing on this path reads node.format.disabled — it's a no-op in v1.9.5."},
    {82, "llm", "cc-text",
     "So the flag won't help. I'll shadow mkfs inside the CSI container so the driver can't reformat a live Pure LUN, and still set format.disabled (commented) so we pick up the upstream fix when it lands."},
    {83, "llm", "cc-tool",
     "git · open PR \"csi: guard against the driver reformatting live LUNs\""},
    {84, "llm", "cc-result", "1 file changed, 38 insertions(+)"},
    {85, "llm", "cc-diff-note", "@@ template local/driver-config.yaml @@"},
    {86, "llm", "cc-diff-ctx", "  node:"},
    {87, "llm", "cc-diff-add", "+    format:"},
    {88, "llm", "cc-diff-add",
     "+      # ignored by v1.9.5 (filesystem.formatDevice); kept for when upstream honors it"},
    {89, "llm", "cc-diff-add", "+      disabled: true"},
    {90, "llm", "cc-diff-note", "@@ task node · shadow mkfs before exec democratic-csi @@"},
    {91, "llm", "cc-diff-add",
     "+  for n in mkfs mkfs.ext4 mkfs.xfs …; do mv \"$d/$n\" \"$d/$n.real\"; cp guard \"$d/$n\"; done"},
    {92, "llm", "cc-diff-note", "@@ new file local/mkfs.guard @@"},
    {93, "llm", "cc-diff-add", "+  case \"$dev\" in /dev/*) ;; *) exec \"$real\" \"$@\" ;; esac"},
    {94, "llm", "cc-diff-add",
     "+  grep -qiE 'nvme|Pure|FlashArray' \"$sys/model\" || exec \"$real\" \"$@\"   # local disk → real mkfs"},
    {95, "llm", "cc-diff-add",
     "+  [ \"$(blkid -o value -s TYPE \"$dev\")\" = ext4 ] && exit 0   # re-attach → no-op"},
    {96, "llm", "cc-diff-add",
     "+  exit 64   # blank or unsure on a live Pure LUN → refuse, never mkfs"},
    {97, "llm", "cc-text",
     "33 hours of metrics are gone — overwritten before I caught the writes. The disk is frozen if you want to attempt recovery. The PR keeps format.disabled for when upstream honors it, and adds mkfs.guard so the driver can't mkfs a mounted Pure LUN. Review and merge before the next node drain."}
  ]

  # The /compare/copy-paste-ai-ops pair: the same 502 on edge-sfo-03, fixed
  # twice. Copy-paste: you ssh in from your laptop, carry the logs into Claude
  # and the command and its output back, so the replay keeps hopping between
  # the host and Claude (`[Pasted text #N +M lines]` is how Claude Code shows
  # a paste; `demo_line` sets it apart). With emisar: Claude calls the linux
  # pack's actions and the output returns to the chat, so the replay never
  # leaves the claude tab. Both show the same host state: Go's net/http accept
  # loop out of file descriptors, then the restarted unit.
  @copy_paste_demo_lines [
    {1, "server", "srv-comment", "# api on edge-sfo-03 is returning 502s"},
    {2, "server", "srv-local-prompt", "ssh edge-sfo-03"},
    {3, "server", "srv-log", "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)"},
    {4, "server", "srv-log", "Last login: Wed Oct 28 09:12:44 2026 from 10.0.4.17"},
    {5, "server", "srv-prompt", "sudo journalctl -u api -n 4"},
    {6, "server", "srv-log",
     "Oct 28 14:02:09 edge-sfo-03 api[1423]: http: Accept error: accept tcp [::]:8080: accept4: too many open files; retrying in 1s"},
    {7, "server", "srv-log",
     "Oct 28 14:02:10 edge-sfo-03 api[1423]: http: Accept error: accept tcp [::]:8080: accept4: too many open files; retrying in 1s"},
    {8, "server", "srv-log",
     "Oct 28 14:02:11 edge-sfo-03 api[1423]: http: Accept error: accept tcp [::]:8080: accept4: too many open files; retrying in 1s"},
    {9, "server", "srv-log",
     "Oct 28 14:02:12 edge-sfo-03 api[1423]: http: Accept error: accept tcp [::]:8080: accept4: too many open files; retrying in 1s"},
    {10, "llm", "cc-user",
     "api on edge-sfo-03 is returning 502s. logs: [Pasted text #1 +4 lines]"},
    {11, "llm", "cc-spin", "Analyzing"},
    {12, "llm", "cc-text",
     "api has run out of file descriptors, so it can't accept new connections. A restart clears that for now. Run this on edge-sfo-03 and paste the output:"},
    {13, "llm", "cc-code", "sudo systemctl restart api && systemctl status api"},
    {14, "server", "srv-prompt", "sudo systemctl restart api && systemctl status api"},
    {15, "server", "srv-log", "● api.service - API server"},
    {16, "server", "srv-log",
     "     Loaded: loaded (/etc/systemd/system/api.service; enabled; preset: enabled)"},
    {17, "server", "srv-log",
     "     Active: active (running) since Wed 2026-10-28 14:03:40 UTC; 1s ago"},
    {18, "server", "srv-log", "   Main PID: 2210 (api)"},
    {19, "llm", "cc-user", "done: [Pasted text #2 +4 lines]"},
    {20, "llm", "cc-spin", "Analyzing"},
    {21, "llm", "cc-text",
     "api is back up. The leak will come back, so the code still needs a fix."}
  ]

  # Each call and result fits one line of the half-width window; long
  # output is abbreviated with "…" the way the home demo does.
  @with_emisar_demo_lines [
    {1, "llm", "cc-meta", "emisar MCP connected · scoped to edge-sfo-03"},
    {2, "llm", "cc-user", "api on edge-sfo-03 is returning 502s"},
    {3, "llm", "cc-spin", "Investigating"},
    {4, "llm", "cc-tool", "emisar · linux.journalctl(unit: \"api\")"},
    {5, "llm", "cc-result", "api[1423]: … accept4: too many open files"},
    {6, "llm", "cc-result-cont", "… +213 lines (ctrl+r to expand)"},
    {7, "llm", "cc-spin", "Analyzing"},
    {8, "llm", "cc-text",
     "api has run out of file descriptors, so it can't accept new connections. A restart clears that for now."},
    {9, "llm", "cc-tool", "emisar · linux.systemctl_restart(unit: \"api\")"},
    {10, "llm", "cc-result", "succeeded · exit 0 · 1.2s"},
    {11, "llm", "cc-tool", "emisar · linux.systemctl_status(unit: \"api\")"},
    {12, "llm", "cc-result", "Active: active (running) since 14:03:40; 1s ago"},
    {13, "llm", "cc-result-cont", "… +14 lines (ctrl+r to expand)"},
    {14, "llm", "cc-text",
     "api is back up. The leak will come back, so the code still needs a fix."}
  ]

  # The /compare/raw-ssh-for-ai pair: the same rollback of a bad deploy,
  # once through Claude Code's Bash tool over SSH and once through emisar.
  # Over SSH, one "don't ask again" answer covers every later ssh command,
  # including a read of the service's .env; through emisar, Claude calls the
  # nomad pack's job_history (low) and job_revert (high), and only the
  # revert waits for an approval of that one run.
  @raw_ssh_demo_lines [
    {1, "llm", "cc-user",
     "api on nomad-prod-1 is throwing 502s since the 14:00 deploy. roll it back"},
    {2, "llm", "cc-spin", "Investigating"},
    {3, "llm", "cc-tool", "Bash(ssh nomad-prod-1 'nomad job history api')"},
    {4, "llm", "cc-permit",
     "Do you want to proceed? ❯ Yes, and don't ask again for ssh commands"},
    {5, "llm", "cc-result", "Version     = 18"},
    {6, "llm", "cc-result-cont", "Stable      = false"},
    {7, "llm", "cc-result-cont", "… +10 lines (ctrl+r to expand)"},
    {8, "llm", "cc-text",
     "v18 went out at 14:00 and isn't stable. I'll check whether it changed the service's config."},
    {9, "llm", "cc-tool", "Bash(ssh nomad-prod-1 'cat /srv/api/.env')"},
    {10, "llm", "cc-result", "API_PORT=8080"},
    {11, "llm", "cc-leak", "DB_PASSWORD=x7Kq2vLp9mWd"},
    {12, "llm", "cc-result-cont", "… +4 lines (ctrl+r to expand)"},
    {13, "llm", "cc-text",
     "The config didn't change, so the new code is the likely cause. Rolling back to v17."},
    {14, "llm", "cc-tool", "Bash(ssh nomad-prod-1 'nomad job revert api 17')"},
    {15, "llm", "cc-result", "==> 2026-10-28T14:21:07Z: Monitoring evaluation \"9c1f2a3b\""},
    {16, "llm", "cc-result-cont", "… +6 lines (ctrl+r to expand)"},
    {17, "llm", "cc-text",
     "Rolled back to v17. The 502s should clear as the new allocations start."}
  ]

  @ssh_emisar_demo_lines [
    {1, "llm", "cc-meta", "emisar MCP connected · scoped to nomad-prod-1"},
    {2, "llm", "cc-user",
     "api on nomad-prod-1 is throwing 502s since the 14:00 deploy. roll it back"},
    {3, "llm", "cc-spin", "Investigating"},
    {4, "llm", "cc-tool", "emisar · nomad.job_history(job: \"api\")"},
    {5, "llm", "cc-result", "Version     = 18"},
    {6, "llm", "cc-result-cont", "Stable      = false"},
    {7, "llm", "cc-result-cont", "… +10 lines (ctrl+r to expand)"},
    {8, "llm", "cc-text",
     "v18 went out at 14:00 and isn't stable; v17 was the last stable version. Rolling back to it."},
    {9, "llm", "cc-tool", "emisar · nomad.job_revert(job: \"api\", version: 17)"},
    {10, "llm", "cc-pending",
     "⏸ pending approval — nomad.job_revert is high-risk; a human approves in the portal"},
    {11, "llm", "cc-spin-wait", "Waiting for approval"},
    {12, "llm", "cc-approved", "✓ approved by you · one use · audit event recorded"},
    {13, "llm", "cc-result", "==> 2026-10-28T14:21:07Z: Monitoring evaluation \"9c1f2a3b\""},
    {14, "llm", "cc-result-cont", "… +6 lines (ctrl+r to expand)"},
    {15, "llm", "cc-text",
     "Rolled back to v17. The 502s should clear as the new allocations start."}
  ]

  # Each script names its host tab, the shell prompts its prompt lines show
  # (keyed by line kind), the footer caption, and whether Claude's turns are
  # set apart by a blank line (the short compare transcripts are). A script
  # with no "server" lines renders the claude tab alone.
  defp demo_script(:incident) do
    %{
      host: "nomad-hvn03",
      prompts: %{"srv-prompt" => "ops@nomad-hvn03:~$ "},
      spaced: true,
      label: "emisar demo",
      caption:
        "The agent used fs, debugging, docker, and nomad packs from the catalog. Only the high-risk action was paused for human approval.",
      lines: @demo_lines
    }
  end

  defp demo_script(:copy_paste) do
    %{
      host: "edge-sfo-03",
      prompts: %{"srv-local-prompt" => "ops@laptop:~$ ", "srv-prompt" => "ops@edge-sfo-03:~$ "},
      spaced: true,
      label: "Copy-paste demo",
      caption: "Logs, the command, and its output all pass through your clipboard.",
      lines: @copy_paste_demo_lines
    }
  end

  defp demo_script(:with_emisar) do
    %{
      host: "edge-sfo-03",
      prompts: %{},
      spaced: true,
      label: "emisar demo",
      caption: "Claude calls emisar actions. Nothing passes through your clipboard.",
      lines: @with_emisar_demo_lines
    }
  end

  defp demo_script(:raw_ssh) do
    %{
      host: "nomad-prod-1",
      prompts: %{},
      spaced: true,
      label: "Raw SSH demo",
      caption: "One answer let the agent run any ssh command. The password is now in the chat.",
      lines: @raw_ssh_demo_lines
    }
  end

  defp demo_script(:ssh_emisar) do
    %{
      host: "nomad-prod-1",
      prompts: %{},
      spaced: true,
      label: "emisar demo",
      caption: "Each call is a declared action. The revert waited for your approval of that run.",
      lines: @ssh_emisar_demo_lines
    }
  end

  attr :script, :atom,
    default: :incident,
    values: [:incident, :copy_paste, :with_emisar, :raw_ssh, :ssh_emisar],
    doc: "which transcript to play"

  attr :class, :any, default: "mx-auto mt-16 max-w-4xl", doc: "placement and width"

  @doc """
  Interactive "watch emisar work" terminal. The home page plays the
  `:incident`; /compare/copy-paste-ai-ops plays `:copy_paste` beside
  `:with_emisar`, and /compare/raw-ssh-for-ai plays `:raw_ssh` beside
  `:ssh_emisar`. The full transcript is server-rendered in two panes (one
  per tab) so no-JS visitors and crawlers get the whole story and the tabs
  degrade to a readable, stacked transcript. `assets/js/emisar_demo.js`
  enhances every instance into a tabbed, typed replay with Claude-style
  spinners (and honors `prefers-reduced-motion`). CSP-safe — no inline script.
  """
  def emisar_demo(assigns) do
    script = demo_script(assigns.script)

    assigns =
      assigns
      |> assign(:host, script.host)
      |> assign(:prompts, script.prompts)
      |> assign(:spaced, script.spaced)
      |> assign(:label, script.label)
      |> assign(:caption, script.caption)
      |> assign(
        :server_lines,
        Enum.filter(script.lines, fn {_, tab, _, _} -> tab == "server" end)
      )
      |> assign(:llm_lines, Enum.filter(script.lines, fn {_, tab, _, _} -> tab == "llm" end))

    ~H"""
    <div
      data-emisar-demo
      class={[
        "overflow-hidden rounded-xl border border-zinc-800 bg-[#0c0c0e] shadow-2xl shadow-brand-950/40 ring-1 ring-white/5",
        @spaced && "demo-spaced",
        @class
      ]}
    >
      <div class="flex items-center gap-4 border-b border-zinc-800/80 bg-zinc-950/60 px-4 py-2.5">
        <div class="flex items-center gap-1.5">
          <span class="h-3 w-3 rounded-full bg-[#ff5f57]"></span>
          <span class="h-3 w-3 rounded-full bg-[#febc2e]"></span>
          <span class="h-3 w-3 rounded-full bg-[#28c840]"></span>
        </div>
        <div class="flex items-center gap-1" role="tablist" aria-label={@label}>
          <button
            :if={@server_lines != []}
            type="button"
            role="tab"
            data-demo-tab="server"
            aria-selected="true"
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <.icon name="infrastructure.host" class="h-3.5 w-3.5" /> {@host}
          </button>
          <button
            type="button"
            role="tab"
            data-demo-tab="llm"
            aria-selected={to_string(@server_lines == [])}
            class="inline-flex items-center gap-1.5 rounded-md px-2.5 py-1 font-mono text-xs text-zinc-500 transition hover:text-zinc-300 aria-selected:bg-zinc-800/80 aria-selected:text-zinc-100"
          >
            <.icon name="product.agent" class="h-3.5 w-3.5 text-[#d97757]" /> claude
          </button>
        </div>
      </div>

      <div
        data-demo-screen
        class="h-[26rem] overflow-y-auto px-5 py-4 font-mono text-[12.5px] leading-[1.7] [scrollbar-width:thin]"
      >
        <div :if={@server_lines != []} data-demo-pane="server">
          <.demo_line
            :for={{seq, tab, kind, text} <- @server_lines}
            seq={seq}
            tab={tab}
            kind={kind}
            text={text}
            prompts={@prompts}
          />
        </div>
        <div data-demo-pane="llm" hidden={@server_lines != []}>
          <.demo_line
            :for={{seq, tab, kind, text} <- @llm_lines}
            seq={seq}
            tab={tab}
            kind={kind}
            text={text}
            prompts={@prompts}
          />
        </div>
      </div>

      <div class="flex items-center justify-between border-t border-zinc-800/80 bg-zinc-950/60 px-4 py-2">
        <p class="text-[11px] text-zinc-500">
          {@caption}
        </p>
        <button
          type="button"
          data-demo-replay
          class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px] font-medium text-brand-300 transition hover:text-brand-200"
        >
          <.icon name="action.replay" class="h-3.5 w-3.5" /> Replay
        </button>
      </div>
    </div>
    """
  end

  attr :seq, :integer, required: true
  attr :tab, :string, required: true
  attr :kind, :string, required: true
  attr :text, :string, required: true
  attr :prompts, :map, required: true, doc: "shell prompt per prompt-line kind"

  # Spinner lines are JS-only — render them hidden so no-JS/crawlers skip
  # them. phx-no-format keeps {@text} tight against the tags (otherwise the
  # formatter reflows it and the indentation leaks into the rendered text,
  # which the typing animation's textContent read would then pick up). The
  # shell prompt rides `data-prompt` for the CSS ::before, out of textContent
  # for the same reason. A trailing paste token renders as its own chip,
  # which the replay drops in whole after typing the words before it.
  defp demo_line(assigns) do
    {text, paste} = split_paste(assigns.text)
    assigns = assign(assigns, text: text, paste: paste)

    ~H"""
    <div
      data-demo-line
      data-tab={@tab}
      data-kind={@kind}
      data-seq={@seq}
      data-prompt={@prompts[@kind]}
      class={["demo-line", "demo-#{@kind}"]}
      hidden={@kind in ["cc-spin", "cc-spin-wait"]}
      phx-no-format
    >{@text}<span :if={@paste} class="demo-paste">{@paste}</span></div>
    """
  end

  defp split_paste(text) do
    case Regex.run(~r/^(.*?)(\[Pasted text #\d+ \+\d+ lines\])$/, text) do
      [_, before, paste] -> {before, paste}
      nil -> {text, nil}
    end
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
            <article class="text-base text-zinc-400 [&_h2]:mb-5 [&_h2]:mt-14 [&_h2]:scroll-mt-24 [&_h2]:border-t [&_h2]:border-zinc-900 [&_h2]:pt-14 [&_h2]:text-2xl [&_h2]:font-bold [&_h2]:tracking-tight [&_h2]:text-balance [&_h2]:text-zinc-50 [&>h2:first-of-type]:mt-0 [&>h2:first-of-type]:border-t-0 [&>h2:first-of-type]:pt-0 [&_p]:my-7 [&_p]:leading-8 [&_p]:text-zinc-400 [&_strong]:font-semibold [&_strong]:text-zinc-100 [&_ul]:my-7 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_li]:text-zinc-400 [&_li]:marker:text-zinc-500 [&_a]:font-medium [&_a]:text-brand-300 [&_a:hover]:text-brand-200 [&_code]:rounded-sm [&_code]:bg-zinc-900 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.85em] [&_code]:text-zinc-300">
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
          <p class="mt-6 text-sm text-zinc-400">{@date} &middot; {@read_time}</p>
        </div>
      </header>

      <section class="py-14 sm:py-16">
        <div class="mx-auto max-w-3xl px-6 lg:px-8">
          <article class="text-base [&_blockquote]:my-6 [&_blockquote]:border-l-2 [&_blockquote]:border-brand-500/40 [&_blockquote]:pl-5 [&_blockquote]:text-zinc-300 [&_code]:rounded-sm [&_code]:bg-zinc-900 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.85em] [&_code]:text-zinc-300 [&_h2]:mb-5 [&_h2]:mt-14 [&_h2]:scroll-mt-24 [&_h2]:border-t [&_h2]:border-zinc-900 [&_h2]:pt-12 [&_h2]:text-2xl [&_h2]:font-bold [&_h2]:tracking-tight [&_h2]:text-balance [&_h2]:text-zinc-50 [&>h2:first-of-type]:mt-0 [&>h2:first-of-type]:border-t-0 [&>h2:first-of-type]:pt-0 [&_h3]:mb-3 [&_h3]:mt-10 [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:text-zinc-100 [&_p]:my-6 [&_p]:leading-8 [&_p]:text-zinc-400 [&_strong]:font-semibold [&_strong]:text-zinc-100 [&_ul]:my-6 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5 [&_ol]:my-6 [&_ol]:list-decimal [&_ol]:space-y-2 [&_ol]:pl-5 [&_li]:text-zinc-400 [&_li]:marker:text-zinc-500 [&_a]:font-medium [&_a]:text-brand-300 [&_a:hover]:text-brand-200">
            {render_slot(@inner_block)}
          </article>
        </div>
      </section>

      <.marketing_cta
        headline="The best way to give your AI agents access to production."
        subcopy="Connect your agent to the tools you run. Set the policy; emisar checks each request before it runs."
        secondary_label="Follow the quickstart"
        secondary_path={~p"/docs/quickstart"}
      />

      <.marketing_footer />
    </div>
    """
  end

  @doc """
  The request-path figure in the technical guide. The AI agent calls the hosted control plane
  over MCP, and the runner on the customer's server dials out to it before running declared
  actions against local services. The network arrows point from the side that opens the
  connection. Stacks vertically below `md`.
  """
  attr :class, :string, default: "my-10"

  def request_path_diagram(assigns) do
    ~H"""
    <figure class={@class}>
      <div class="flex flex-col md:grid md:py-3 md:pr-3 md:grid-cols-[minmax(0,1fr)_48px_minmax(0,1fr)_112px_minmax(0,1fr)_48px_minmax(0,1fr)]">
        <.diagram_node title="AI agent" items={["Claude", "ChatGPT", "Cursor"]} />
        <.diagram_link direction={:forward} labels={["MCP"]} />
        <.diagram_node title="Control plane" items={["Identity", "Policy", "Approvals", "Audit"]} />
        <.diagram_link direction={:back} labels={["outbound", "WebSocket"]} crosses_boundary />
        <div class="relative -mx-3 flex flex-col rounded-xl border border-dashed border-zinc-700 p-[11px] md:col-span-3 md:-m-3 md:grid md:grid-cols-[minmax(0,1fr)_48px_minmax(0,1fr)]">
          <span class="absolute -top-2.5 right-[18px] bg-zinc-950 px-1.5 text-[13px]/5 text-zinc-400 md:right-auto md:left-[18px]">
            Your server
          </span>
          <.diagram_node title="Runner" items={["Pack hash", "Local rules", "Redaction", "Journal"]} />
          <.diagram_link direction={:forward} />
          <.diagram_node title="Services" items={["Postgres", "nginx", "Kubernetes"]} />
        </div>
      </div>
      <figcaption class="mt-6 max-w-3xl text-sm/6 text-zinc-400">
        The control plane is hosted by emisar. The runner opens the TLS connection to it, so your
        server needs no inbound port for emisar. Requests and results travel both ways over that connection.
      </figcaption>
    </figure>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  # Items read as a comma list on phones and as a column from md up.
  # phx-no-format keeps each item tight against its separator.
  defp diagram_node(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-zinc-900/50 p-3">
      <span class="block whitespace-nowrap text-sm/5 font-semibold text-zinc-100">{@title}</span>
      <span class="mt-1 block text-[13px]/5 text-zinc-400 md:mt-2">
        <span :for={{item, index} <- Enum.with_index(@items)} class="md:block" phx-no-format>{item}<span :if={index < length(@items) - 1} class="md:hidden">, </span></span>
      </span>
    </div>
    """
  end

  attr :direction, :atom, required: true, values: [:forward, :back]
  attr :labels, :list, default: []
  attr :crosses_boundary, :boolean, default: false

  # A 1px shaft with a 6x9 arrowhead: vertical below md, horizontal from md up.
  # From md the boxes are 134px tall, so the shaft at 66px sits in their middle
  # and the label block ends at 61px, the bottom of the first list row, which
  # puts every label line on a baseline with the box text beside it. On phones a
  # shaft that crosses the server boundary runs through its 12px inset, so it
  # still stops 4px short of the next box like the others.
  defp diagram_link(assigns) do
    ~H"""
    <div class="relative h-12 md:h-auto">
      <span
        aria-hidden="true"
        class={[
          "absolute left-[13px] top-1 border-l border-zinc-600",
          if(@crosses_boundary, do: "-bottom-2", else: "bottom-1"),
          "md:left-1 md:right-1 md:top-[66px] md:bottom-auto md:border-l-0 md:border-t"
        ]}
      ></span>
      <svg
        aria-hidden="true"
        viewBox="0 0 6 9"
        class={[
          "absolute left-[10.5px] h-[9px] w-[6px] text-zinc-500 md:top-[62px]",
          if(@direction == :forward,
            do: "bottom-[2.5px] rotate-90 md:left-auto md:right-1 md:bottom-auto md:rotate-0",
            else: "top-[2.5px] -rotate-90 md:left-1 md:rotate-180"
          )
        ]}
      >
        <path d="M0 0L6 4.5L0 9Z" fill="currentColor" />
      </svg>
      <span
        :if={@labels != []}
        class="absolute left-[29px] top-1/2 -translate-y-1/2 whitespace-nowrap text-[13px]/5 text-zinc-400 md:hidden"
      >
        {Enum.join(@labels, " ")}
      </span>
      <span
        :if={@labels != []}
        class={[
          "absolute inset-x-0 top-0 hidden h-[61px] flex-col items-center justify-end text-[13px]/5 text-zinc-400 md:flex",
          @crosses_boundary && "md:pr-3"
        ]}
      >
        <span :for={label <- @labels} class="[&:not(:last-child)]:mb-2">{label}</span>
      </span>
    </div>
    """
  end
end
