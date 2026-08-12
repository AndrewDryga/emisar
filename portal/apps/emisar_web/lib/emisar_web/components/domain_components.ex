defmodule EmisarWeb.DomainComponents do
  @moduledoc """
  Console components that know an emisar domain concept — a run row, a risk
  tier, a runner's connection state, an install wizard, a pack version.

  Split out of CoreComponents. The distinction that matters: a primitive there
  takes classes and slots and knows nothing about emisar, while these map domain
  state to tone and copy. That is the line design-console-ux draws, and it was
  invisible while all four audiences lived in one 6,836-line file.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents
  alias Emisar.Runs
  alias EmisarWeb.{TimeHelpers, UrlHelpers}

  @doc """
  Banner shown above a billing surface when the account's Paddle subscription
  needs attention (past_due / paused / canceled). Healthy/nil/unknown status →
  renders nothing. Shared by the billing page and the dashboard so the copy +
  severity live in one place.

  Copy is purely informational — emisar does NOT gate features on subscription
  status, so it must never imply lost access (that would be a promise the code
  doesn't keep; if enforcement is ever wired, revisit the wording). Pass a
  `:cta` slot for the "Manage billing" affordance — a portal button on the
  billing page, a link to it on the dashboard — and omit it where the viewer
  can't manage billing.

      <.subscription_banner status={@summary.subscription_status}>
        <:cta :if={Billing.subject_can_manage_billing?(@current_subject)}>…</:cta>
      </.subscription_banner>
  """
  attr :status, :any, default: nil
  attr :class, :any, default: nil
  slot :cta

  def subscription_banner(assigns) do
    assigns = assign(assigns, :alert, subscription_alert(assigns.status))

    ~H"""
    <.callout
      :if={@alert}
      tone={@alert.tone}
      icon="hero-exclamation-triangle"
      title={@alert.title}
      class={@class}
    >
      {@alert.body}
      <:action :if={@cta != []}>{render_slot(@cta)}</:action>
    </.callout>
    """
  end

  # Maps a Paddle subscription status to a banner. active/trialing/nil are
  # healthy (no banner); past_due is the loud "fix your card" case; paused and
  # canceled are amber FYIs. An unknown status we don't model gets no banner —
  # don't alarm on a state we can't explain (Paddle owns the value space; see
  # Subscription.Changeset). Copy is advisory only — emisar does not gate on
  # subscription status, so it must not imply lost access.
  defp subscription_alert("past_due"),
    do: %{
      tone: :rose,
      title: "Payment past due",
      body: "Your last payment failed — update your card so the next charge goes through."
    }

  defp subscription_alert("paused"),
    do: %{
      tone: :amber,
      title: "Subscription paused",
      body: "Resume it from the billing portal when you're ready."
    }

  defp subscription_alert("canceled"),
    do: %{
      tone: :amber,
      title: "Subscription canceled",
      body: "Resubscribe from billing to start a new subscription."
    }

  defp subscription_alert(_), do: nil

  @doc """
  A compact run-summary row — the action_id (mono), an optional target-runner +
  relative time, and the run's status badge — linking to the run. Used by the
  "recent runs" lists. Pass `show_runner` where the target isn't already implied
  by the surrounding page (the dashboard); omit it on a runner's own page.
  `show_source` adds the human-vs-LLM origin badge — the product's thesis in
  one glyph — where the digest doesn't have a Source column.
  """
  attr :run, :map, required: true
  attr :show_runner, :boolean, default: false
  attr :show_source, :boolean, default: false
  attr :current_account, :map, required: true

  attr :padding, :string,
    default: "px-5 py-3",
    doc: "row inset — a canvas-naked list passes a flush variant"

  def run_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
      class={[
        "flex items-center gap-3 rounded-md transition hover:bg-white/[0.04]",
        @padding
      ]}
    >
      <div class="min-w-0 flex-1">
        <%!-- The action id is the run's identity — on a phone it wraps to show
             in full rather than clipping; the wider desktop row still truncates
             to keep the list scannable. dotted_mono breaks at the id's dots,
             never mid-token ("caddy.reverse_proxy_upstr/eams" read as broken). --%>
        <div class="break-words font-mono text-sm text-zinc-200 sm:truncate">
          <.dotted_mono value={@run.action_id} />
        </div>
        <%!-- Attribution rides the meta line — the accountable HUMAN plus the
             channel: "by maya@… via portal", "by jordan@… via Claude Code -
             on-call" (an MCP run's human is its key's owner). No icon, no
             column — the digest row is content left, status right. --%>
        <div class="truncate text-xs text-zinc-400">
          <span :if={@show_runner && @run.runner}>{"on #{@run.runner.name} · "}</span>
          <TimeHelpers.local_time
            id={"digest-run-#{@run.id}"}
            value={@run.inserted_at}
            mode={:relative}
          />
          <span :if={@show_source && run_attribution(@run)}>· {run_attribution(@run)}</span>
        </div>
      </div>
      <%!-- Status hugs the right edge — flush with "View all" and the content
           column. A fixed-width column left it floating ~40px in from the edge,
           reading unanchored; a single trailing status reads cleanest against
           the edge. --%>
      <span class="shrink-0">
        <.status_badge status={@run.status} />
      </span>
    </.link>
    """
  end

  # "by <who>" (+ " via <agent>" for MCP) — who is the accountable HUMAN by
  # NAME (email fallback): the requesting user, or an MCP run's key owner.
  # "via portal" is the default channel and says nothing, so it's dropped;
  # the MCP agent name IS the signal (human vs agent origin) and stays. A run
  # with no recorded human (legacy rows, the runbook engine) shows only its
  # channel; nil hides the segment entirely. Runs.run_who_via/1 is the shared
  # who/via projection (also feeds the runs list + run detail).
  defp run_attribution(run) do
    case Runs.run_who_via(run) do
      {nil, nil} -> nil
      {who, nil} -> "by #{who}"
      {nil, channel} -> "via #{channel}"
      {who, channel} -> "by #{who} via #{channel}"
    end
  end

  @doc """
  The dispatch ORIGIN of a run — a small leading icon + the actor label on one
  truncating line. The ICON (not color) distinguishes an LLM/MCP-dispatched run
  (a bolt — the one an operator scans for) from an operator (a person), a runbook,
  or a schedule, so agent-origin is pre-attentive without spending the
  emerald-means-allowed semantic on it (who dispatched is metadata, not an
  outcome). The canonical origin shape — reuse it instead of re-pairing an icon
  with an actor label. The caller caps the width (`max-w-*`) where the column is
  tight; the label always stays one line.

      <.source_badge
        source={run.source}
        label={accountable_actor_label(Runs.run_who_via(run))}
        class="max-w-[12rem] text-xs"
      />
  """
  attr :source, :any,
    required: true,
    doc: "the run's `source` enum — :operator/:mcp/:runbook"

  attr :label, :string,
    required: true,
    doc: "the actor label, e.g. `accountable_actor_label(Runs.run_who_via(run))`"

  attr :class, :string, default: nil

  def source_badge(assigns) do
    assigns = assign(assigns, :source_tooltip, source_tooltip(assigns.source))

    ~H"""
    <span class={["inline-flex min-w-0 items-center gap-1.5 text-zinc-400", @class]}>
      <.tooltip
        text={@source_tooltip}
        aria_label={@source_tooltip}
        class="shrink-0"
      >
        <.icon name={source_icon(@source)} class="h-3.5 w-3.5 text-zinc-500" />
      </.tooltip>
      <span class="truncate" title={@label}>{@label}</span>
    </span>
    """
  end

  defp source_icon(:mcp), do: "hero-bolt"

  defp source_icon(:runbook), do: "hero-book-open"

  defp source_icon(_operator), do: "hero-user"

  defp source_tooltip(:mcp), do: "Dispatched via MCP"

  defp source_tooltip(:runbook), do: "Dispatched by a runbook"

  defp source_tooltip(_operator), do: "Dispatched by an operator"

  @doc """
  A runner's connection `status_badge`, toned to caution when the runner is up
  but on an unsupported version. "connected" stays the word — the primary fact
  is that it's reachable (and, warn-only by default, still dispatching) — while
  the amber tone plus the rose version chip beside it flag that it needs
  upgrading. Below-minimum is advisory on a runner, unlike a hard-blocked MCP
  bridge (which the agents page reads as "unsupported" outright), so here we
  degrade the tone, never the word.
  """
  attr :state, :atom, required: true, values: [:online, :offline, :disabled, :pending]
  attr :version, :string, default: nil
  attr :class, :string, default: ""

  def runner_status_badge(assigns) do
    ~H"""
    <.status_badge
      status={connection_status(@state)}
      tone={runner_status_tone(@state, @version)}
      class={@class}
    />
    """
  end

  # Only an ONLINE runner earns the caution recolor: offline/pending already
  # read amber and disabled reads neutral, so a stale version adds no new alarm
  # there — and nil lets the badge keep the word's own tone.
  defp runner_status_tone(:online, version) do
    if Emisar.Compat.runner_status(version) == :unsupported, do: :amber
  end

  defp runner_status_tone(_state, _version), do: nil

  @doc """
  A quiet frame for a user-authored artifact that must remain visually distinct
  from the page controls around it, such as runbook operator instructions.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def artifact_panel(assigns) do
    ~H"""
    <article class={[
      "min-w-0 overflow-hidden rounded-xl border border-zinc-800/70 p-5",
      @class
    ]}>
      {render_slot(@inner_block)}
    </article>
    """
  end

  @doc """
  Plan-gate note for a documented feature: a quiet trailing sentence — "Only
  available on <tier>" — that goes at the END of the feature's paragraph (not a
  badge by the heading), the tier name linking to pricing so a reader on a lower
  plan sees it's not on theirs. `tier: :team` → Team and Enterprise;
  `tier: :enterprise` → Enterprise only.

  Pass `link={false}` for the compact, non-linking tag used INSIDE another anchor
  (a docs-index card) — anchors can't nest.

      <p>… what the feature does. <.plan_note tier={:enterprise} /></p>
  """
  attr :tier, :atom, required: true, values: [:team, :enterprise]
  attr :link, :boolean, default: true
  attr :class, :string, default: nil

  def plan_note(%{link: false} = assigns) do
    ~H"""
    <span title={plan_note_title(@tier)} class={["text-xs font-medium text-amber-400/70", @class]}>
      {plan_note_label(@tier)}
    </span>
    """
  end

  def plan_note(assigns) do
    ~H"""
    <span class={["text-zinc-400", @class]}>
      Only available on <.link
        href={~p"/pricing"}
        title={plan_note_title(@tier)}
        class="font-medium text-amber-400/80 underline decoration-amber-400/25 underline-offset-2 transition-colors hover:text-amber-300 hover:decoration-amber-400/60"
      >{plan_note_label(@tier)}</.link>.
    </span>
    """
  end

  defp plan_note_label(:team), do: "Team & Enterprise"

  defp plan_note_label(:enterprise), do: "Enterprise"

  defp plan_note_title(:team), do: "Available on the Team and Enterprise plans — see pricing"

  defp plan_note_title(:enterprise), do: "Available on the Enterprise plan — see pricing"

  @doc """
  Self-reported MCP client metadata — the operator-configured key/value map an
  MCP caller sends so its Emisar activity can be correlated with the customer's
  own MDM / EDR / device inventory. Rendered as a labeled definition list and
  explicitly marked self-reported, so it is never mistaken for verified device
  posture. Renders nothing when there is no metadata.

      <.mcp_client_metadata metadata={@run.mcp_client_metadata} />
  """
  attr :metadata, :map, default: %{}
  attr :class, :string, default: nil

  def mcp_client_metadata(assigns) do
    ~H"""
    <section :if={is_map(@metadata) and @metadata != %{}} class={@class}>
      <.section_header title="Client metadata">
        <:subtitle>
          Self-reported by the MCP client for correlation — not verified device posture.
        </:subtitle>
      </.section_header>
      <dl class="grid grid-cols-1 gap-x-10 gap-y-3 sm:grid-cols-2">
        <div :for={{key, value} <- Enum.sort(@metadata)} class="min-w-0">
          <dt
            class="truncate font-mono text-[11px] uppercase tracking-wide text-zinc-400"
            title={key}
          >
            {key}
          </dt>
          <dd class="mt-0.5 truncate text-sm text-zinc-200" title={to_string(value)}>{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  @doc """
  A compound identity as a two-half tag: the CATEGORY muted on the left, the
  specific VALUE brighter on the right, split by a divider. Use it wherever an
  identity only reads correctly as a pair — a runner's group + name, a grant's
  `group`/`runner`/`pack` + the thing it names. A single-value label stays a
  `<.chip>`; a pair crammed into one chip as `"Group: x"` is the shape this
  replaces. Informative, so it stays zinc even inside a rose block.

      <.identity_tag category="group" value="va1-cassandra" />
      <.identity_tag category={runner.group} value={runner.name} />
      <.identity_tag category="runner" title={runner_id}>
        <.removed_runner runner_id={runner_id} />
      </.identity_tag>
  """
  attr :category, :string, required: true
  attr :value, :string, default: nil, doc: "the value half; omit when passing a slot"
  attr :class, :string, default: nil
  attr :rest, :global, doc: "extra attributes (e.g. title for the full id)"
  slot :inner_block

  def identity_tag(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-stretch overflow-hidden rounded font-mono text-[11px] ring-1 ring-zinc-700/60",
        @class
      ]}
      {@rest}
    >
      <span class="bg-zinc-800/50 px-1.5 py-0.5 text-zinc-400">{@category}</span>
      <span class="border-l border-zinc-700/60 px-1.5 py-0.5 text-zinc-300">
        {@value}{render_slot(@inner_block)}
      </span>
    </span>
    """
  end

  @doc """
  The honest label for a run's runner after the runner row itself was removed —
  unlinked, because its detail route can only land on "Runner not found.", with
  the full runner id preserved in the `title` for forensics.

      <.removed_runner runner_id={run.runner_id} />
  """
  attr :runner_id, :string, default: nil
  attr :class, :string, default: nil

  def removed_runner(assigns) do
    ~H"""
    <span class={["truncate", @class]} title={@runner_id}>Removed runner</span>
    """
  end

  @doc """
  A stale-version warning chip for a runner or the emisar-mcp bridge, driven by
  the `Emisar.Compat` policy. Renders nothing for a current (`:supported`) or
  unparseable/missing (`:unknown`) version; an amber "outdated" chip below the
  recommended line; a rose "unsupported" chip below the minimum. The visible
  label carries the state (never hover-only) and the tooltip title adds the
  minimum-version detail.

      <.version_chip kind={:runner} version={runner.runner_version} />
  """
  attr :kind, :atom, required: true, values: [:runner, :mcp]
  attr :version, :string, default: nil

  attr :id, :string,
    default: nil,
    doc: "unique tooltip id — pass a per-row id where the chip repeats"

  attr :class, :string, default: nil

  def version_chip(assigns) do
    assigns = assign(assigns, :status, version_status(assigns.kind, assigns.version))

    ~H"""
    <.tooltip
      :if={@status in [:outdated, :unsupported]}
      id={@id}
      text={version_chip_title(@kind, @status, @version)}
      aria_label={@status == :outdated && version_chip_title(@kind, @status, @version)}
      align={:responsive}
      class={@class}
    >
      <%!-- Below the minimum is a blocked state and keeps the labelled warning
           chip. Merely behind the current release still runs and dispatches
           fine, so it is quiet chrome — one arrow beside the version that
           explains itself on hover or focus, never a badge shouting beside the
           host's name (the Packs page words the same fact the same way). --%>
      <.chip :if={@status == :unsupported} tone={:rose} icon="hero-exclamation-triangle">
        unsupported
      </.chip>
      <.icon
        :if={@status == :outdated}
        name="hero-arrow-up-circle"
        class="h-3.5 w-3.5 text-zinc-500"
      />
    </.tooltip>
    """
  end

  defp version_status(:runner, version), do: Emisar.Compat.runner_status(version)

  defp version_status(:mcp, version), do: Emisar.Compat.mcp_status(version)

  defp version_chip_title(:runner, :unsupported, _version) do
    "Below the minimum runner version #{Emisar.Compat.runner_minimum()} — upgrade this runner."
  end

  # Names the release the operator would get and the one they are on, the way
  # an update prompt should — never the requirement string that decided it.
  defp version_chip_title(:runner, :outdated, version) do
    "Runner #{Emisar.Compat.runner_target()} is available#{version_from(version)}. " <>
      "Re-run the installer on this host to update; it keeps the configuration and restarts the service."
  end

  defp version_chip_title(:mcp, :unsupported, _version) do
    "Below the minimum emisar-mcp version #{Emisar.Compat.mcp_minimum()} — upgrade the bridge."
  end

  defp version_chip_title(:mcp, :outdated, version) do
    "emisar-mcp #{Emisar.Compat.mcp_target()} is available#{version_from(version)}. " <>
      "Re-run the installer on that machine, then restart its LLM client."
  end

  defp version_from(version) when is_binary(version) and version != "",
    do: "; this one is on #{version}"

  defp version_from(_version), do: ""

  @doc """
  Actionable upgrade instructions for stale runner or emisar-mcp versions.
  Renders one notice for all stale versions passed by a list page, or for the
  single version on a detail page. Current and unknown versions render nothing.

      <.version_upgrade_notice
        id="runner-upgrade"
        kind={:runner}
        versions={Enum.map(runners, & &1.runner_version)}
        base_url={base_url}
      />
  """
  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:runner, :mcp]
  attr :versions, :list, required: true
  attr :base_url, :string, required: true

  attr :scope, :atom,
    default: :list,
    values: [:list, :single],
    doc: "`:list` scopes the count to \"on this page\"; `:single` is one entity's own detail page"

  attr :class, :string, default: nil

  def version_upgrade_notice(assigns) do
    statuses = Enum.map(assigns.versions, &version_status(assigns.kind, &1))
    status = version_upgrade_status(statuses)
    unsupported_count = Enum.count(statuses, &(&1 == :unsupported))
    outdated_count = Enum.count(statuses, &(&1 == :outdated))
    affected_count = unsupported_count + outdated_count

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:affected_count, affected_count)
      |> assign(:unsupported_count, unsupported_count)
      |> assign(:outdated_count, outdated_count)
      |> assign(:command, version_upgrade_command(assigns.kind, assigns.base_url))

    ~H"""
    <%!-- Amber only when something is actually below the supported range. An
         update that has merely shipped is a convenience: what is installed still
         runs and dispatches, so the notice stays neutral rather than putting the
         page into a warning state nobody needs to act on today. --%>
    <.callout
      :if={@status in [:outdated, :unsupported]}
      id={@id}
      tone={(@status == :unsupported && :amber) || :neutral}
      icon="hero-cloud-arrow-down"
      title={version_upgrade_title(@kind, @status, @affected_count)}
      class={@class}
    >
      <div class="space-y-4">
        <p>{version_upgrade_message(@kind, @scope, @unsupported_count, @outdated_count)}</p>
        <.code_line
          id={"#{@id}-command"}
          value={@command}
        />
      </div>
    </.callout>
    """
  end

  defp version_upgrade_status(statuses) do
    cond do
      :unsupported in statuses -> :unsupported
      :outdated in statuses -> :outdated
      true -> :supported
    end
  end

  defp version_upgrade_title(:runner, :unsupported, 1), do: "Runner update required"

  defp version_upgrade_title(:runner, :unsupported, count),
    do: "#{count} runners need an update"

  defp version_upgrade_title(:runner, :outdated, 1), do: "Runner update available"

  defp version_upgrade_title(:runner, :outdated, count),
    do: "Updates available for #{count} runners"

  defp version_upgrade_title(:mcp, :unsupported, _count), do: "MCP bridge update required"

  defp version_upgrade_title(:mcp, :outdated, _count), do: "MCP bridge update available"

  # `:single` scope — the runner's own detail page: the notice describes THIS
  # runner, so it never scopes a count to "on this page".
  defp version_upgrade_message(:runner, :single, unsupported, _outdated) when unsupported > 0 do
    "This runner is below the supported range (#{Emisar.Compat.runner_minimum()}). " <>
      "Run the command on its host. The installer preserves its configuration and restarts the service."
  end

  defp version_upgrade_message(:runner, :single, 0, _outdated) do
    "This runner is behind #{Emisar.Compat.runner_target()}. " <>
      "Run the command on its host. The installer preserves its configuration and restarts the service."
  end

  # `:list` scope — the notice sits above a paginated list, so it scopes the
  # count to "on this page" (never "this runner", which reads as one entity when
  # the page holds many). Parallels the agents-list bridge copy below.
  defp version_upgrade_message(:runner, :list, unsupported_count, 0) do
    "#{runner_count_phrase(unsupported_count)} below the supported range " <>
      "(#{Emisar.Compat.runner_minimum()}). Run the command once on each affected host; " <>
      "the installer preserves its configuration and restarts the service."
  end

  defp version_upgrade_message(:runner, :list, 0, outdated_count) do
    "#{runner_count_phrase(outdated_count)} behind #{Emisar.Compat.runner_target()}. " <>
      "Run the command once on each affected host; " <>
      "the installer preserves its configuration and restarts the service."
  end

  defp version_upgrade_message(:runner, :list, unsupported_count, outdated_count) do
    "On this page, #{version_count_label(unsupported_count, "runner")} below the supported " <>
      "range (#{Emisar.Compat.runner_minimum()}) and " <>
      "#{version_count_label(outdated_count, "runner")} behind #{Emisar.Compat.runner_target()}. " <>
      "Run the command once on each affected host; " <>
      "the installer preserves its configuration and restarts the service."
  end

  # MCP agents render only as a page-scoped list (there is no per-agent detail
  # view), so the bridge copy always scopes to "on this page" — scope-agnostic.
  defp version_upgrade_message(:mcp, _scope, unsupported_count, 0) do
    "#{unsupported_count} #{agent_count_label(unsupported_count)} on this page last connected through a bridge below " <>
      "the supported range (#{Emisar.Compat.mcp_minimum()}). Run the command once on each " <>
      "affected machine, then restart its LLM client."
  end

  defp version_upgrade_message(:mcp, _scope, 0, outdated_count) do
    "#{outdated_count} #{agent_count_label(outdated_count)} on this page last connected through a bridge behind " <>
      "#{Emisar.Compat.mcp_target()}. Run the command once on " <>
      "each affected machine, then restart its LLM client."
  end

  defp version_upgrade_message(:mcp, _scope, unsupported_count, outdated_count) do
    "On this page, #{version_count_label(unsupported_count, "agent")} last connected through " <>
      "a bridge below the supported range (#{Emisar.Compat.mcp_minimum()}) and " <>
      "#{version_count_label(outdated_count, "agent")} behind #{Emisar.Compat.mcp_target()}. " <>
      "Run the command once on each affected machine, then restart its LLM client."
  end

  defp version_count_label(1, noun), do: "1 #{noun} is"

  defp version_count_label(count, noun), do: "#{count} #{noun}s are"

  defp version_upgrade_command(:runner, base_url),
    do: "curl -sSL #{String.trim_trailing(base_url, "/")}/install.sh | sudo bash"

  defp version_upgrade_command(:mcp, base_url), do: UrlHelpers.mcp_install_command(base_url)

  @doc """
  Install-a-runner wizard — the standalone `/app/runners/install` page and
  the runners-list empty state. The caller pre-mints the install command and
  passes it as a string (or `:mint_failed` to render the fallback); after a
  grace period with no runner it flips `show_troubleshooting` to reveal a
  checklist (the host must reach `base_url`).

      <.install_wizard install_command={@install_command} />
  """
  attr :install_command, :any, required: true
  attr :base_url, :string, default: nil
  attr :show_troubleshooting, :boolean, default: false
  attr :keys_path, :string, default: "/app/runners/keys"
  # The multi-use pointer targets a manage-only page — hide it for callers
  # whose subject can't open it (an in-product link must never 404).
  attr :show_keys_link, :boolean, default: true

  def install_wizard(assigns) do
    ~H"""
    <%!-- CONTENT ON CANVAS, task + rail: the left column follows the
         operator's own timeline — act (command + credential), wait (the live
         ping line), recover (troubleshooting, revealed in place) — then the
         script's trust facts as reference; the READING (what's a runner,
         resources) is a right rail at xl, stacking below when the work canvas
         cannot keep the primary task wider than the rail. Columns
         separate by AIR alone — hairlines are row-lattice grammar, never
         section chrome (vertical rules belong to the shell). ONE type
         ladder — section_header 16 / body 14 / meta 12; never an uppercase
         eyebrow as a section title. The command is the only contained
         artifact; amber is reserved for the ONE overdue state — the
         credential note and the normal wait stay neutral/brand. --%>
    <div>
      <p class="text-sm leading-relaxed text-zinc-400">
        Two minutes — pick a Linux or macOS host, paste the one-liner.
      </p>

      <div class="mt-8 xl:grid xl:grid-cols-[minmax(0,1fr)_22rem] xl:gap-x-12">
        <div>
          <%= cond do %>
            <% is_binary(@install_command) -> %>
              <div class="space-y-8">
                <section>
                  <.section_header title="Run this on the host" />
                  <%!-- Copy carries the literal string, including its leading
                       HISTCONTROL space; the compact preview deliberately clips. --%>
                  <.code_line
                    id="runner-install-command"
                    value={@install_command}
                    prompt
                    class="mt-3"
                  />
                  <%!-- Right where the odd first character raises the question. --%>
                  <p class="mt-2 text-xs text-zinc-400">
                    The leading space keeps the key out of your shell history.
                  </p>
                  <%!-- The one-liner embeds a single-use enrollment key shown
                       only here. Keeping it out of chat/tickets is an operator
                       action — but the note is a permanent property of the
                       command, not an exceptional state, so the spine stays
                       NEUTRAL: amber on this page belongs to the overdue
                       escalation alone. --%>
                  <.event_block
                    icon="hero-key"
                    tone={:neutral}
                    title="Live credential — won't be shown again"
                    class="mt-5"
                  >
                    <:body>
                      The command runs with <code class="font-mono text-zinc-300">sudo</code>
                      and carries a <span class="font-medium text-zinc-200">one-time</span>
                      key: it enrolls exactly one host, then expires. Treat it like a password —
                      paste it straight onto the host, never into a chat or ticket.
                    </:body>
                  </.event_block>
                </section>

                <%!-- The page's live status — the naked dot-led wait line
                     (the wait-room grammar sso_pending copies), directly
                     under the act it follows so the operator's eye never has
                     to jump static content to find the page's one live
                     element. Waiting is this page's NORMAL state: a quiet
                     brand ping (channel open, listening), never an alert. --%>
                <div>
                  <div class="flex items-start gap-3">
                    <%!-- mt-[6px]: optically centers the 10px dot on the first
                         text line (text-sm/relaxed ≈ 23px line box). --%>
                    <.status_dot tone={:brand} ping size={:lg} class="mt-[6px]" />
                    <p class="text-sm leading-relaxed text-zinc-400">
                      <span class="font-medium text-zinc-300">Waiting for a runner to connect</span>
                      — this page advances on its own; you can leave, and the runner will appear in
                      Runners either way.
                    </p>
                  </div>

                  <%!-- After the grace period with no join (the install
                       page's watchdog flips show_troubleshooting) the likely
                       funnel failure is a wrong/truncated key, :443
                       firewalled, or a non-systemd host. Escalates HERE —
                       beside the wait line the operator is already watching —
                       and only THIS overdue state wears amber. --%>
                  <.event_block
                    :if={@show_troubleshooting}
                    icon="hero-signal"
                    tone={:amber}
                    title="Not seeing it yet?"
                    class="mt-5"
                  >
                    <:body>Check the host:</:body>
                    <.steps class="mt-3">
                      <:step>
                        It can reach <code class="font-mono text-zinc-300">{@base_url}</code>
                        over outbound HTTPS (nothing needs to listen on it).
                      </:step>
                      <:step>
                        You ran the whole line with <code class="font-mono text-zinc-300">sudo</code>
                        and the key wasn't truncated on paste.
                      </:step>
                      <:step>
                        It runs systemd — watch the runner's own logs with <code class="font-mono text-zinc-300">journalctl -u emisar -f</code>.
                      </:step>
                    </.steps>
                  </.event_block>
                </div>

                <%!-- Reference, not task — reads AFTER the wait line so the
                     act→wait pair stays adjacent; a first-run skeptic scans
                     here before pasting. --%>
                <section>
                  <.section_header title="What the script does" />
                  <ul class="space-y-2.5 text-sm leading-relaxed text-zinc-400">
                    <%!-- mt-[3px]: optically centers the 14px check on the first
                         text line (mt-0.5 sat visibly high). --%>
                    <li class="flex items-start gap-2.5">
                      <.icon
                        name="hero-check"
                        class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400"
                      />
                      <span>Verifies the download's SHA-256 before running anything</span>
                    </li>
                    <li class="flex items-start gap-2.5">
                      <.icon
                        name="hero-check"
                        class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400"
                      />
                      <span>
                        Runs the runner as a dedicated
                        <code class="font-mono text-zinc-300">emisar</code>
                        user (not root) under a systemd unit
                      </span>
                    </li>
                    <li class="flex items-start gap-2.5">
                      <.icon
                        name="hero-check"
                        class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400"
                      />
                      <span>Only dials out — nothing listens on the host</span>
                    </li>
                  </ul>
                  <div class="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-sm font-medium">
                    <.link
                      href="/install.sh"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="text-brand-400 hover:text-brand-300"
                    >
                      It's a plain shell script — read it first&nbsp;→
                    </.link>
                    <.link
                      href={~p"/trust" <> "#release-integrity"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="text-brand-400 hover:text-brand-300"
                    >
                      Verify the release's provenance&nbsp;→
                    </.link>
                  </div>
                </section>
              </div>
            <% @install_command == :mint_failed -> %>
              <.event_block
                icon="hero-exclamation-triangle"
                tone={:rose}
                title="Could not create the install command"
              >
                <:body>
                  Open
                  <.link navigate={@keys_path} class="font-medium text-brand-400 hover:text-brand-300">
                    Runners → Enrollment keys
                  </.link>
                  and create one manually, or refresh this page to try again.
                </:body>
              </.event_block>
            <% true -> %>
              <div class="flex items-center gap-3 text-sm text-zinc-400">
                <span class="hero-arrow-path h-4 w-4 animate-spin"></span>
                Generating your install command…
              </div>
          <% end %>
        </div>

        <%!-- The reading rail — what a runner is + the other ways in (docs,
             multi-use keys, packs), true for every wizard state (a failed
             mint still deserves the manual-install door). Quiet rows on the
             canvas, never island cards competing with the task. --%>
        <aside class="mt-10 space-y-8 xl:mt-0">
          <%!-- Beginner framing first — someone installing their first runner
               needs "what is this and why" before "what the script does". --%>
          <section>
            <%!-- Rail heading matches the shared `docs_rail` (text-sm, zinc-200),
                 NOT the canvas `section_header` (16px display) — so "What's a
                 runner?" reads identically here and on the Runners list rail. --%>
            <h3 class="mb-3 text-sm font-semibold text-zinc-200">What's a runner?</h3>
            <div class="space-y-3 text-sm leading-relaxed text-zinc-400">
              <p>
                A runner is the small <span class="text-zinc-200">emisar agent</span>
                you're installing here — a service on this host that carries out actions for you.
              </p>
              <p>
                The cloud never touches your hosts directly. It dispatches a gated, audited action
                to the runner, which runs only the vetted actions in its trusted packs and reports
                back — no inbound access, no SSH keys handed out.
              </p>
              <p>
                Install one on each host you want to operate. Once it connects it appears on the
                Runners page, ready to receive actions.
              </p>
            </div>
          </section>

          <section>
            <h3 class="mb-3 text-sm font-semibold text-zinc-200">Resources</h3>
            <ul class="divide-y divide-zinc-800/70 border-t border-zinc-800/70">
              <li>
                <.link
                  href={~p"/docs/host-install"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Full host install</div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  href={~p"/docs/containers"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Containers</div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  href={~p"/docs/kubernetes"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Kubernetes</div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  href={~p"/docs/nomad"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Nomad</div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  href={~p"/docs/autoscaling-fleets"}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Autoscaling fleets</div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <%!-- The docs rows above cover image-bake/cloud-init; this is
                   its in-product twin — those paths need a multi-use key,
                   not the one-shot key baked into the command. Routing for a
                   different journey lives HERE, off the act→wait timeline. --%>
              <li :if={@show_keys_link}>
                <.link
                  navigate={@keys_path}
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Enrollment keys</div>
                    <div class="mt-0.5 text-xs text-zinc-400">
                      Mint a multi-use key for cloud-init fleets and baked images.
                    </div>
                  </div>
                  <.icon
                    name="hero-arrow-right"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  navigate="/packs"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Pack registry</div>
                    <div class="mt-0.5 text-xs text-zinc-400">
                      Browse linux-core, cassandra, showcase. Install snippets included.
                    </div>
                  </div>
                  <.icon
                    name="hero-arrow-right"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
              <li>
                <.link
                  href="https://github.com/andrewdryga/emisar/tree/main/skills"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="group -mx-3 flex items-center gap-4 rounded-lg px-3 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="text-sm font-medium text-zinc-100">Use your coding agent</div>
                    <div class="mt-0.5 text-xs text-zinc-400">
                      The install-emisar skill walks Claude Code or Codex through this setup.
                    </div>
                  </div>
                  <.icon
                    name="hero-arrow-top-right-on-square"
                    class="h-4 w-4 shrink-0 text-zinc-500 transition-colors group-hover:text-brand-400"
                  />
                </.link>
              </li>
            </ul>
          </section>
        </aside>
      </div>
    </div>
    """
  end

  @doc """
  "A runner is offline" notice — a `hero-signal-slash` block whose colour
  encodes SEVERITY, the one place that convention lives so it can't drift:

    * `:info` (zinc) — informational, nothing's wrong (e.g. "you can still
      dispatch; the run queues until it reconnects").
    * `:caution` (amber) — this run/action may be affected.
    * `:critical` (rose) — the whole fleet is down; nothing can dispatch.

      <.offline_notice severity={:caution} title="Queued — runner offline">
        Waiting for {name} to reconnect before this run can dispatch.
        <:action><.link navigate={~p"/app/\#{@current_account}/runners"}>View runners</.link></:action>
      </.offline_notice>
  """
  attr :severity, :atom, default: :caution, values: [:info, :caution, :critical]
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :action

  # `:info` is a posture FACT (dispatch still works) — the naked note grammar,
  # per §8.1's callout-vs-note line; caution/critical are interruptions that
  # earn the box.
  def offline_notice(%{severity: :info} = assigns) do
    ~H"""
    <.status_note icon="hero-signal-slash" tone={:neutral} title={@title} class={@class}>
      {render_slot(@inner_block)}
    </.status_note>
    """
  end

  def offline_notice(assigns) do
    assigns = assign(assigns, :tone, offline_tone(assigns.severity))

    ~H"""
    <.callout tone={@tone} icon="hero-signal-slash" title={@title} class={@class}>
      {render_slot(@inner_block)}
      <:action :if={@action != []}>{render_slot(@action)}</:action>
    </.callout>
    """
  end

  # The severity → tone convention this wrapper exists to encode: caution
  # names an affected run/action; critical means the whole fleet is down.
  # (`:info` never reaches here — it renders as the naked note above.)
  defp offline_tone(:caution), do: :amber

  defp offline_tone(:critical), do: :rose

  @doc """
  Risk pill — used on action descriptors. Colours mirror the runner's
  declared risk level (`low|medium|high|critical`); takes the risk as a
  string (pack-manifest data) or an Ecto.Enum atom (catalog rows).
  """
  attr :risk, :any, required: true
  attr :class, :string, default: nil

  def risk_pill(assigns) do
    assigns = assign(assigns, :risk, to_string(assigns.risk))

    ~H"""
    <span
      title={risk_title(@risk)}
      class={[
        "rounded px-2 py-0.5 text-xs font-semibold uppercase tracking-wider ring-1 ring-inset",
        risk_classes(@risk),
        @class
      ]}
    >
      {@risk}
    </span>
    """
  end

  # The severity scale spelled out on hover, so a non-expert approver knows what
  # "HIGH" means and that CRITICAL is above it (the lexicon a single word can't carry).
  defp risk_title("low"), do: "Low — read-only or trivially reversible"

  defp risk_title("medium"), do: "Medium — changes state, easily reversible"

  defp risk_title("high"), do: "High — service-affecting"

  defp risk_title("critical"), do: "Critical — data loss or irreversible"

  defp risk_title(_), do: nil

  # Risk is a SEVERITY ramp, not a policy outcome: low is the quiet neutral floor,
  # NOT brand-green — green means "the gate allowed this", and a risk tier has had
  # no decision. So it climbs neutral → amber → rose → deeper-rose, and the policy
  # editor's tier cards (`tier_border/tier_dot`) mirror it exactly.
  defp risk_classes("low"), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"

  defp risk_classes("medium"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"

  defp risk_classes("high"), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"

  defp risk_classes("critical"), do: "bg-rose-600/15 text-rose-200 ring-rose-500/40"

  defp risk_classes(_), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"

  @doc """
  "expires in 3h" badge for a held approval request, rendered from the
  lifecycle facts `Approvals.request_facts/2` projects — this component reads
  no clock, so every row of one page agrees about a deadline. Amber when under
  two hours remain so an approver can triage by urgency (the requester's run
  auto-cancels at expiry). Renders nothing without an expiry.

      <.approval_expiry
        id={"expiry-\#{@request.id}"}
        expires_at={@facts.expires_at}
        expired?={@facts.expired?}
        expires_in_seconds={@facts.expires_in_seconds}
      />
  """
  attr :expires_at, :any, default: nil
  # Required, not defaulted: what a deadline MEANS is Approvals' to decide, so a
  # caller that forgets these facts must fail to compile rather than render a
  # silently never-expired badge.
  attr :expired?, :boolean, required: true
  # Seconds left on the deadline, clamped at 0 by Approvals — the urgency tone
  # reads from this rather than diffing the timestamp here.
  attr :expires_in_seconds, :integer, required: true
  attr :class, :string, default: nil

  attr :id, :string,
    default: nil,
    doc:
      "Row-stable id threaded to the inner <.local_time> for list rows (e.g. id={\"expiry-\#{request.id}\"})."

  # tabular-nums: the relative countdown ticks live, so its digits must not
  # change the badge's width under it.
  def approval_expiry(assigns) do
    ~H"""
    <span
      :if={@expires_at}
      title={expiry_title(@expired?)}
      class={[
        "inline-flex items-center gap-1 text-xs tabular-nums",
        expiry_class(@expires_in_seconds),
        @class
      ]}
    >
      <%!-- Past tense once it's lapsed ("expired 2m ago") so an at-the-wire
           approval isn't an ambiguous static "expires just now"; {" "} is a
           literal space HEEx won't trim. The title states the on-expiry behavior;
           the LocalTime hook carries the absolute time on hover. --%>
      <.icon name={if @expired?, do: "hero-no-symbol", else: "hero-clock"} class="h-3 w-3" />
      {if @expired?, do: "expired", else: "expires"}{" "}<TimeHelpers.local_time
        id={@id}
        value={@expires_at}
        mode={:relative}
      />
    </span>
    """
  end

  defp expiry_title(true),
    do: "Expired without a decision — it was auto-denied; the action won't run."

  defp expiry_title(false),
    do: "If no one decides by then, it's auto-denied — the action won't run."

  # Under two hours left → amber: an approval lapsing soon needs to stand out
  # in the queue. At or past the deadline (the sweeper hasn't cancelled it yet)
  # is moot, not urgent — keep it muted.
  defp expiry_class(seconds) when is_integer(seconds) and seconds > 0 and seconds <= 7200,
    do: "text-amber-400"

  defp expiry_class(_seconds), do: "text-zinc-400"

  @doc """
  A bounded, static preview of the command and tail output for an action run.
  The optional command must be the runner-reported redacted command; callers
  never reconstruct it from arguments. Pass events in chronological order
  (oldest→newest). Earlier output is omitted once `max_chars` is reached.
  """
  attr :command, :string, default: nil
  attr :command_truncated?, :boolean, default: false
  attr :events, :list, required: true
  attr :label, :string, default: "Command and output"
  attr :max_chars, :integer, default: 32_000
  attr :class, :string, default: nil

  def output_preview(assigns) do
    {rows, output_truncated?} = bounded_output_rows(assigns.events, assigns.max_chars)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:output_truncated?, output_truncated?)

    ~H"""
    <pre
      :if={is_binary(@command) or @rows != []}
      tabindex="0"
      aria-label={@label}
      class={[
        "overflow-auto whitespace-pre font-mono text-xs leading-relaxed text-zinc-300 [font-variant-ligatures:none]",
        @class
      ]}
    ><span :if={is_binary(@command)}><span class="select-none text-zinc-500">$ </span>{@command}<span :if={@command_truncated?} class="text-zinc-500"> …</span>
    </span><span :if={@output_truncated?} class="text-zinc-500">… earlier output omitted …
    </span><span :for={row <- @rows} class={row.stream == "stderr" && "text-rose-300"}>{row.chunk}</span></pre>
    """
  end

  defp bounded_output_rows(events, max_chars) do
    {rows, _remaining, truncated?} =
      events
      |> Enum.reverse()
      |> Enum.reduce({[], max(max_chars, 0), false}, fn event, {rows, remaining, truncated?} ->
        chunk = event_chunk(event)

        cond do
          chunk == "" ->
            {rows, remaining, truncated?}

          remaining == 0 ->
            {rows, remaining, true}

          String.length(chunk) <= remaining ->
            row = %{stream: event.stream, chunk: chunk}
            {[row | rows], remaining - String.length(chunk), truncated?}

          true ->
            row = %{stream: event.stream, chunk: String.slice(chunk, -remaining, remaining)}
            {[row | rows], 0, true}
        end
      end)

    {rows, truncated?}
  end

  # "1 runner on this page is" / "3 runners on this page are" — the count-scoped,
  # number-agreed subject for a list-level runner upgrade notice.
  defp runner_count_phrase(1), do: "1 runner on this page is"

  defp runner_count_phrase(count), do: "#{count} runners on this page are"

  defp agent_count_label(1), do: "agent"

  defp agent_count_label(_count), do: "agents"
end
