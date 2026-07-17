defmodule EmisarWeb.AuditDetailLive do
  @moduledoc """
  Single audit event detail view. Shareable URL for incident response:
  paste `/app/audit/:id` into a Slack thread, post in a postmortem.

  Renders every field on the event: when, type, actor + subject (with
  links into their detail pages when one exists), IP, user agent,
  request id, and the full payload as pretty JSON.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Audit, Runners, Runs}
  alias EmisarWeb.{AuditSummary, UserAgent}

  def mount(%{"id" => id}, _session, socket) do
    case Audit.fetch_event_by_id(id, socket.assigns.current_subject) do
      {:ok, event} ->
        refs = Audit.resolve_references([event])

        {:ok,
         socket
         |> assign(:page_title, "Audit · #{event.event_type}")
         |> assign(:event, event)
         |> assign(:refs, refs)
         |> assign(:subject_runner, subject_runner(event, socket.assigns.current_subject))
         |> assign(:target_run, target_run(event, socket.assigns.current_subject))}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Audit event not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/audit")}
    end
  end

  # The runner an action_run executed on, for HISTORICAL rows only — run
  # events now target the runner directly and this stays nil. nil unless the
  # target is a run still readable in the caller's account; the run fetch is
  # subject-gated, so cross-account ids resolve to nil rather than leaking.
  defp subject_runner(%{target_kind: "action_run", target_id: id}, %{} = subject)
       when is_binary(id) do
    case Runs.fetch_run_by_id(id, subject, preload: [:runner]) do
      {:ok, %{runner: %Runners.Runner{} = runner}} -> runner
      _ -> nil
    end
  end

  defp subject_runner(_event, _subject), do: nil

  # The inverse for the CURRENT run-event shape (target = the runner, the run
  # in `payload.run_id`): the Target card links back to the run. Same
  # subject-gated fetch — a cross-account or deleted run resolves to nil.
  defp target_run(%{target_kind: "runner", payload: %{} = payload}, %{} = subject) do
    case payload["run_id"] || payload[:run_id] do
      id when is_binary(id) ->
        case Runs.fetch_run_by_id(id, subject) do
          {:ok, run} -> run
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp target_run(_event, _subject), do: nil

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
      width={:table}
    >
      <:title>
        <%!-- No leading status dot — a lone colored bullet before the title read
             as an orphan decoration. The event name carries the outcome; the
             audit LIST keeps the per-row dot where scanning actually happens. --%>
        <.detail_header back="Audit log" navigate={~p"/app/#{@current_account}/audit"}>
          <span class="font-semibold">{format_event_type(@event.event_type)}</span>
          <span class="ml-2 font-mono text-xs font-normal text-zinc-400">{@event.event_type}</span>
        </.detail_header>
      </:title>
      <% posture = parse_client_posture(@event.user_agent) %>

      <%!-- The page owns its rhythm (§3.3): ONE space-y-12 child; the EVENT
           RECORD block groups the naked meta row with the actor→target pair
           and the summary chips — they're all facets of one event. --%>
      <div class="mt-4 space-y-12">
        <div>
          <%!-- Event facts on the CANVAS — when it occurred, where from,
               request id (the MCP client rides the Actor cluster: it describes
               who acted, not the event). --%>
          <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
            <%!-- wrap: forensic precision must survive a phone — the timestamp takes
             the full row and wraps rather than clipping (it isn't copy-backed). --%>
            <.meta_field label="When" wrap>
              <.local_time
                value={@event.occurred_at}
                mode={:forensic}
                class="text-sm leading-5 tabular-nums text-zinc-300"
              />
            </.meta_field>
            <%!-- The event's own id — its permalink identity. It used to hide in the
             payload panel's annotation; here it's a first-class, copyable field
             an incident responder can paste into a ticket. --%>
            <%!-- wrap: the event id is a UUID you copy off a forensic page — it takes
             the full row and wraps so it never clips (and its copy button never
             shears off the cell edge). --%>
            <.meta_field label="Event ID" wrap>
              <.copyable_id value={@event.id} class="text-sm leading-5 text-zinc-300" />
            </.meta_field>
            <.meta_field label="IP address">
              <.copyable_id
                :if={@event.ip_address}
                value={@event.ip_address}
                class="text-sm leading-5 text-zinc-300"
              />
              <span :if={!@event.ip_address} class="text-sm leading-5 text-zinc-500">—</span>
            </.meta_field>
            <.meta_field label="Request ID" wrap>
              <.copyable_id
                :if={@event.request_id}
                value={@event.request_id}
                class="text-sm leading-5 text-zinc-300"
              />
              <span :if={!@event.request_id} class="text-sm leading-5 text-zinc-500">—</span>
            </.meta_field>
          </div>

          <%!-- Actor → Target, NAKED clusters (no cards): the arrow draws the
               relationship between two aligned record stacks. The actor track
               is bounded so a long MCP posture row cannot push the arrow across
               the page; below lg the records stack instead of becoming cramped. --%>
          <div class="mt-8 grid grid-cols-1 gap-8 lg:grid-cols-[minmax(18rem,24rem)_auto_minmax(0,1fr)] lg:items-start lg:gap-x-12">
            <.entity_card
              role="Actor"
              kind={@event.actor_kind}
              id={@event.actor_id}
              label={@event.actor_label}
              refs={@refs}
              current_account={@current_account}
              user_agent={@event.user_agent}
              auth_method={@event.auth_method}
              mfa={@event.mfa}
              mcp_client={if posture.bridge?, do: posture.client}
              mcp_client_host={if posture.bridge?, do: posture.host}
              mcp_client_os={if posture.bridge?, do: posture.os}
            />
            <div class="hidden flex-none items-center pt-7 lg:flex">
              <.icon name="hero-arrow-right" class="h-5 w-5 text-zinc-700" />
            </div>
            <%!-- A self-action (a sign-in, a runner connect) acts on itself. Restating
             the actor byte-for-byte beside itself is noise — say "same as actor". --%>
            <.entity_card
              role="Target"
              self?={
                not is_nil(@event.actor_kind) and @event.actor_kind == @event.target_kind and
                  @event.actor_id == @event.target_id
              }
              kind={@event.target_kind}
              id={@event.target_id}
              label={@event.target_label}
              refs={@refs}
              current_account={@current_account}
              runner={@subject_runner}
              run={@target_run}
            />
          </div>

          <%!-- At-a-glance summary chips — the "interesting fact" pulled from
               the payload (via, role from→to, count, etc.), a NAKED key+chips
               row. Hidden when the event type has no special summary. --%>
          <div
            :if={AuditSummary.summary_pairs(@event) != []}
            class="mt-8 flex flex-wrap items-center gap-2"
          >
            <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
              Summary
            </span>
            <.chip :for={pair <- AuditSummary.summary_pairs(@event)}>
              <span class="font-mono text-zinc-400">{elem(pair, 0)}:</span>
              <span class="text-zinc-200">{elem(pair, 1)}</span>
            </.chip>
          </div>
        </div>

        <%!-- Self-reported MCP client metadata pulled from the run payload —
           labeled as self-reported, never verified posture. Renders nothing
           when the event carries none. --%>
        <.mcp_client_metadata metadata={@event.payload["mcp_client_metadata"] || %{}} />

        <%!-- Policy-update diff — special-case rendering for the one
           event type where the payload diff is the whole reason
           anyone opens the page. Falls through to plain JSON below
           for everything else. --%>
        <.policy_changes
          :if={@event.event_type == "policy.updated" and is_map(@event.payload)}
          changes={@event.payload["changes"] || %{}}
        />

        <%!-- Payload — primary content on the page. Wide and tall,
           terminal-style for the JSON; copy grabs the rendered JSON
           (innerText) so an operator can paste it into a ticket/grep. --%>
        <%!-- Event id moved up to a meta field; the payload panel just labels its
           copy for what it grabs — the rendered JSON, ready to paste. --%>
        <.code_panel
          id="audit-payload-json"
          label="Payload"
          copy
          copy_label="Copy JSON"
          max_h="max-h-[60vh]"
          code={pretty_payload(@event.payload)}
        />
      </div>
    </.dashboard_shell>
    """
  end

  defp pretty_payload(nil), do: "{}"
  defp pretty_payload(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  defp pretty_payload(other), do: inspect(other)

  # -- policy.updated diff renderer ---------------------------------

  attr :changes, :map, required: true

  defp policy_changes(assigns) do
    defaults = assigns.changes["defaults"] || %{}
    overrides = assigns.changes["overrides"] || %{}

    assigns =
      assigns
      |> assign(:defaults_diff, defaults)
      |> assign(:added, overrides["added"] || [])
      |> assign(:removed, overrides["removed"] || [])
      |> assign(:changed, overrides["changed"] || [])

    ~H"""
    <section :if={@defaults_diff != %{} or @added != [] or @removed != [] or @changed != []}>
      <.section_header title="Changes" />
      <div class="space-y-5">
        <%= if @defaults_diff != %{} do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Tier defaults
            </p>
            <ul class="space-y-1 text-sm">
              <li
                :for={{tier, %{"from" => from, "to" => to}} <- @defaults_diff}
                class="flex items-center gap-2"
              >
                <span class="font-mono text-xs text-zinc-300">{tier}:</span>
                <code class="rounded bg-rose-500/10 px-1.5 py-0.5 text-[11px] text-rose-300">
                  {from || "—"}
                </code>
                <span class="text-zinc-500">→</span>
                <code class="rounded bg-brand-500/10 px-1.5 py-0.5 text-[11px] text-brand-300">
                  {to || "—"}
                </code>
              </li>
            </ul>
          </div>
        <% end %>

        <%= if @added != [] do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Added overrides ({length(@added)})
            </p>
            <ul class="space-y-1 text-xs">
              <li :for={ov <- @added} class="rounded bg-brand-500/[0.04] px-2 py-1">
                <code class="font-mono text-zinc-200">{ov["action"]}</code>
                <span class="text-zinc-500">→</span>
                <code class="font-mono text-brand-300">{ov["decision"]}</code>
                <span :if={ov["name"] && ov["name"] != ""} class="ml-2 text-zinc-400">
                  ({ov["name"]})
                </span>
              </li>
            </ul>
          </div>
        <% end %>

        <%= if @removed != [] do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Removed overrides ({length(@removed)})
            </p>
            <ul class="space-y-1 text-xs">
              <li :for={ov <- @removed} class="rounded bg-rose-500/[0.04] px-2 py-1">
                <code class="font-mono text-zinc-200">{ov["action"]}</code>
                <span class="text-zinc-500">→</span>
                <code class="font-mono text-rose-300">{ov["decision"]}</code>
              </li>
            </ul>
          </div>
        <% end %>

        <%= if @changed != [] do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Modified overrides ({length(@changed)})
            </p>
            <ul class="space-y-1 text-xs">
              <li :for={c <- @changed} class="rounded bg-amber-500/[0.04] px-2 py-1">
                <code class="font-mono text-zinc-200">{c["action"]}</code>:
                <code class="rounded bg-rose-500/10 px-1.5 py-0.5 text-rose-300">
                  {c["from"]["decision"]}
                </code>
                <span class="text-zinc-500">→</span>
                <code class="rounded bg-brand-500/10 px-1.5 py-0.5 text-brand-300">
                  {c["to"]["decision"]}
                </code>
              </li>
            </ul>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  # Actor/Target record — identity first, then one aligned definition list for
  # every forensic fact. Side-by-side with an arrow at lg+ so the reader sees
  # "this acted on that" without letting long provenance dictate the tracks.
  attr :role, :string, required: true
  attr :current_account, :map, required: true
  attr :self?, :boolean, default: false
  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}
  attr :user_agent, :string, default: nil
  attr :runner, :map, default: nil
  attr :run, :map, default: nil
  attr :mcp_client, :string, default: nil
  attr :mcp_client_host, :string, default: nil
  attr :mcp_client_os, :string, default: nil
  attr :auth_method, :string, default: nil
  attr :mfa, :boolean, default: nil

  defp entity_card(%{self?: true} = assigns) do
    ~H"""
    <div class="min-w-0" data-audit-entity={@role}>
      <.entity_heading role={@role} kind={@kind} />
      <p class="mt-2 text-sm text-zinc-400">
        same as actor <span class="text-zinc-400">(self)</span>
      </p>
    </div>
    """
  end

  defp entity_card(%{kind: nil} = assigns) do
    ~H"""
    <div class="min-w-0" data-audit-entity={@role}>
      <.entity_heading role={@role} />
      <p class="mt-2 text-sm text-zinc-400">— (not recorded)</p>
    </div>
    """
  end

  defp entity_card(assigns) do
    device = device_label(assigns.user_agent)

    mcp_client =
      [assigns.mcp_client, assigns.mcp_client_host, assigns.mcp_client_os]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    assigns = assign(assigns, device: device, mcp_client_label: mcp_client)

    ~H"""
    <div class="min-w-0" data-audit-entity={@role}>
      <.entity_heading role={@role} kind={@kind} />
      <div class="mt-2">
        <EmisarWeb.AuditLive.ref
          kind={@kind}
          id={@id}
          label={@label}
          refs={@refs}
          actor?={@role == "Actor"}
          current_account={@current_account}
        />
      </div>
      <%!-- One label/value grid owns every secondary fact. Every cell has a
           20px minimum row with a 4px gap; copy buttons can no longer make the
           ID row taller than the text-only rows below it. --%>
      <dl
        :if={@id || @runner || @run || @device || @auth_method || @mcp_client_label != ""}
        class="mt-3 grid grid-cols-[5.25rem_minmax(0,1fr)] gap-x-3 gap-y-1 text-xs leading-5"
        data-audit-facts
      >
        <dt :if={@id} class={entity_fact_label_class()}>ID</dt>
        <dd :if={@id} class={entity_fact_value_class()}>
          <.copyable_id value={@id} class="text-xs leading-5 text-zinc-300" />
        </dd>

        <dt :if={@runner} class={entity_fact_label_class()}>Runner</dt>
        <dd :if={@runner} class={entity_fact_value_class()}>
          <.link
            navigate={~p"/app/#{@current_account}/runners/#{@runner.id}"}
            class="text-brand-300 hover:text-brand-200"
          >
            {runner_label(@runner)}
          </.link>
        </dd>

        <dt :if={@run} class={entity_fact_label_class()}>Run</dt>
        <dd :if={@run} class={entity_fact_value_class()}>
          <.link
            navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
            class="text-brand-300 hover:text-brand-200"
          >
            {@run.action_id}
          </.link>
        </dd>

        <dt :if={@device} class={entity_fact_label_class()}>User agent</dt>
        <dd :if={@device} class={[entity_fact_value_class(), "truncate"]} title={@user_agent}>
          {@device}
        </dd>

        <dt :if={@auth_method} class={entity_fact_label_class()}>Sign-in</dt>
        <dd :if={@auth_method} class={entity_fact_centered_value_class()}>
          <span>{auth_method_label(@auth_method)}</span>
          <.chip :if={@mfa == true} tone={:brand}>2FA</.chip>
          <.chip :if={@mfa == false}>no 2FA</.chip>
        </dd>

        <dt :if={@mcp_client_label != ""} class={entity_fact_label_class()}>MCP client</dt>
        <dd
          :if={@mcp_client_label != ""}
          class={[entity_fact_value_class(), "truncate"]}
          title={@mcp_client_label}
        >
          {@mcp_client_label}
        </dd>
      </dl>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :kind, :string, default: nil

  defp entity_heading(assigns) do
    assigns = assign(assigns, :kind_label, entity_kind_label(assigns.kind))

    ~H"""
    <div
      class="flex items-center gap-1.5 text-xs uppercase leading-4 tracking-wider"
      data-audit-entity-heading
    >
      <span :if={@kind_label} class="font-semibold text-zinc-400" data-audit-entity-kind>
        {@kind_label}
      </span>
      <span :if={@kind_label} aria-hidden="true" class="text-zinc-700">·</span>
      <span
        class="font-medium text-zinc-400"
        data-audit-entity-role
      >
        {@role}
      </span>
    </div>
    """
  end

  defp entity_kind_label(nil), do: nil
  defp entity_kind_label(kind), do: String.replace(kind, "_", " ")

  defp entity_fact_label_class,
    do: "flex min-h-5 items-start font-normal text-zinc-400"

  defp entity_fact_value_class,
    do: "flex min-h-5 min-w-0 items-start text-zinc-300"

  defp entity_fact_centered_value_class,
    do: "flex min-h-5 min-w-0 items-center gap-2 text-zinc-300"

  defp auth_method_label("magic_link"), do: "Magic link"
  defp auth_method_label("sso"), do: "SSO"
  defp auth_method_label(other), do: other

  defp device_label(ua) do
    # The runner (and any bare Go HTTP client that didn't set a custom UA)
    # isn't a "device" worth showing on the actor — return nil so the line
    # hides. The runner appears under the Subject when an event is about one.
    if is_nil(ua) or UserAgent.go_http_client?(ua), do: nil, else: UserAgent.label(ua)
  end

  # `runner: name (group) version` for the target runner line — group and
  # version are appended only when present.
  defp runner_label(%Runners.Runner{} = runner) do
    base =
      if runner.group in [nil, ""],
        do: runner.name,
        else: "#{runner.name} (#{runner.group})"

    # "-" is the runner's no-version placeholder — don't render a dangling dash.
    if runner.runner_version in [nil, "", "-"],
      do: base,
      else: "#{base} #{runner.runner_version}"
  end

  # Pulls structured device-posture fields out of the MCP bridge's
  # User-Agent. The bridge stamps a parens-delimited posture:
  #
  #   "emisar-mcp/0.2.0 (client=claude-desktop; host=andrews-mbp.local)"
  #
  # → %{bridge?: true, bridge: "emisar-mcp/0.2.0", client: ..., host: ...}
  #
  # For everything else (`Go-http-client/1.1` from runners,
  # `Mozilla/...` from browsers, nil), `:bridge?` is false and the
  # detail page hides the Client/Host/MCP-bridge cells — they would
  # otherwise misattribute the runner's HTTP UA as an "MCP bridge".
  defp parse_client_posture(nil),
    do: %{bridge?: false, client: nil, host: nil, os: nil, bridge: nil}

  defp parse_client_posture(ua) when is_binary(ua) do
    parens =
      case Regex.run(~r/\(([^)]+)\)/, ua) do
        [_, body] -> body
        _ -> nil
      end

    fields =
      (parens || "")
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    bridge_token =
      case Regex.run(~r{^([^\s]+)}, ua) do
        [_, b] -> b
        _ -> nil
      end

    # Treat as a bridge UA only when we actually parsed a posture
    # block AND it carries at least one structured field. Otherwise
    # the first whitespace-delimited token isn't a "bridge", it's
    # just opaque (Go-http-client/1.1 etc.) and shouldn't be labelled.
    is_bridge = parens != nil and (Map.has_key?(fields, "client") or Map.has_key?(fields, "host"))

    %{
      bridge?: is_bridge,
      bridge: if(is_bridge, do: bridge_token),
      client: Map.get(fields, "client"),
      host: Map.get(fields, "host"),
      os: Map.get(fields, "os")
    }
  end
end
