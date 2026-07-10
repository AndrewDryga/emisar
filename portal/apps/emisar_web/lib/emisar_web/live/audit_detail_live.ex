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
          <span class="ml-2 font-mono text-xs font-normal text-zinc-500">{@event.event_type}</span>
        </.detail_header>
      </:title>
      <% posture = parse_client_posture(@event.user_agent) %>

      <%!-- The page owns its rhythm (§3.3): ONE space-y-12 child; the EVENT
           RECORD block groups the naked meta row with the actor→target pair
           and the summary chips — they're all facets of one event. --%>
      <div class="mt-4 space-y-12">
        <div>
          <%!-- Event facts on the CANVAS — when it occurred, where from,
               request id (the actor's MCP session/client ride the Actor
               cluster: they describe who acted, not the event). --%>
          <div class="grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
            <%!-- wrap: forensic precision must survive a phone — the timestamp takes
             the full row and wraps rather than clipping (it isn't copy-backed). --%>
            <.meta_field label="When" wrap>
              <.local_time
                value={@event.occurred_at}
                mode={:forensic}
                class="tabular-nums text-zinc-200"
              />
            </.meta_field>
            <%!-- The event's own id — its permalink identity. It used to hide in the
             payload panel's annotation; here it's a first-class, copyable field
             an incident responder can paste into a ticket. --%>
            <%!-- wrap: the event id is a UUID you copy off a forensic page — it takes
             the full row and wraps so it never clips (and its copy button never
             shears off the cell edge). --%>
            <.meta_field label="Event ID" wrap>
              <.copyable_id value={@event.id} class="text-xs text-zinc-300" />
            </.meta_field>
            <.meta_field label="IP address">
              <.copyable_id
                :if={@event.ip_address}
                value={@event.ip_address}
                class="text-xs text-zinc-300"
              />
              <span :if={!@event.ip_address} class="text-zinc-500">—</span>
            </.meta_field>
            <.meta_field label="Request ID">
              <.copyable_id
                :if={@event.request_id}
                value={@event.request_id}
                class="text-xs text-zinc-400"
              />
              <span :if={!@event.request_id} class="text-zinc-500">—</span>
            </.meta_field>
          </div>

          <%!-- Actor → Target, NAKED clusters (no cards): the arrow still
               draws the relationship ("user X acted ON runner Y") between
               the two field-key columns. The actor track hugs its content
               (max-content, shrinkable under pressure) so the arrow sits
               BETWEEN the clusters — a 1fr left column left it hanging
               mid-page in empty space. --%>
          <div class="mt-8 grid grid-cols-1 gap-8 sm:grid-cols-[minmax(0,max-content)_auto_minmax(0,1fr)] sm:items-start sm:gap-x-10">
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
              mcp_session={@event.mcp_session_id}
              mcp_client={if posture.bridge?, do: posture.client}
              mcp_client_host={if posture.bridge?, do: posture.host}
              mcp_client_os={if posture.bridge?, do: posture.os}
            />
            <div class="hidden flex-none items-center pt-6 sm:flex">
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
            <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
              Summary
            </span>
            <.chip :for={pair <- AuditSummary.summary_pairs(@event)}>
              <span class="font-mono text-zinc-500">{elem(pair, 0)}:</span>
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
                <span class="text-zinc-600">→</span>
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
                <span :if={ov["name"] && ov["name"] != ""} class="ml-2 text-zinc-500">
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
                <span class="text-zinc-600">→</span>
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

  # Actor/Subject card — name (linked when possible) up top with a
  # subdued role label, ID underneath. Side-by-side with an arrow
  # between them so the reader sees "this acted on that" at a glance.
  # The Actor card optionally renders the User-Agent (the actor's
  # device); the Subject card doesn't take one.
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
  attr :mcp_session, :string, default: nil
  attr :mcp_client, :string, default: nil
  attr :mcp_client_host, :string, default: nil
  attr :mcp_client_os, :string, default: nil
  attr :auth_method, :string, default: nil
  attr :mfa, :boolean, default: nil

  defp entity_card(%{self?: true} = assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">{@role}</div>
      <p class="mt-1.5 text-sm text-zinc-400">
        same as actor <span class="text-zinc-600">(self)</span>
      </p>
    </div>
    """
  end

  defp entity_card(%{kind: nil} = assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">{@role}</div>
      <p class="mt-1.5 text-sm text-zinc-500">— (not recorded)</p>
    </div>
    """
  end

  defp entity_card(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">{@role}</div>
      <div class="mt-1.5 text-sm">
        <EmisarWeb.AuditLive.ref
          kind={@kind}
          id={@id}
          label={@label}
          refs={@refs}
          actor?={@role == "Actor"}
          current_account={@current_account}
        />
      </div>
      <div :if={@id} class="mt-1 flex items-center gap-1.5 text-[10px] text-zinc-500">
        <span class="font-semibold uppercase tracking-wider">id</span>
        <.copyable_id value={@id} class="text-[10px] text-zinc-400" />
      </div>
      <%!-- Runner line — which host an action_run executed on (historical rows
           whose target is the run). No icon — just `runner: name (group)
           version`. --%>
      <p :if={@runner} class="mt-1 text-[11px] text-zinc-400">
        <span class="text-zinc-500">runner:</span>
        <.link
          navigate={~p"/app/#{@current_account}/runners/#{@runner.id}"}
          class="text-brand-300 hover:text-brand-200"
        >
          {runner_label(@runner)}
        </.link>
      </p>
      <%!-- Run line — the inverse: current run events target the RUNNER and
           carry the run in the payload; link back to what actually ran. --%>
      <p :if={@run} class="mt-1 text-[11px] text-zinc-400">
        <span class="text-zinc-500">run:</span>
        <.link
          navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
          class="text-brand-300 hover:text-brand-200"
        >
          {@run.action_id}
        </.link>
      </p>
      <%!-- Device line — what the ACTOR was using. Browser/OS for human
           users, "MCP bridge" for LLM clients. Hidden for the runner's
           bare Go HTTP client (it's not a device worth showing — the
           runner appears under the Subject when relevant). The full UA
           string is one click away via the `title=` tooltip. --%>
      <% device = device_label(@user_agent) %>
      <p
        :if={device}
        class="mt-2 flex items-center gap-1.5 truncate text-[11px] text-zinc-500"
        title={@user_agent}
      >
        <.icon name={UserAgent.icon(@user_agent)} class="h-3 w-3 shrink-0 text-zinc-600" />
        <span class="truncate">{device}</span>
      </p>
      <%!-- How the human actor authenticated this session + whether a second
           factor was verified (provenance — decision 6). Absent for API keys
           and runners (the credential IS the actor). So an auditor can see, on
           any action, the sign-in method and 2FA state without opening JSON. --%>
      <p :if={@auth_method} class="mt-2 flex items-center gap-1.5 text-[11px] text-zinc-500">
        <.icon name="hero-finger-print" class="h-3 w-3 shrink-0 text-zinc-600" />
        <span>via <span class="text-zinc-300">{auth_method_label(@auth_method)}</span></span>
        <.chip :if={@mfa == true} tone={:brand}>2FA</.chip>
        <.chip :if={@mfa == false}>no 2FA</.chip>
      </p>
      <%!-- MCP coordinates for this actor: the client the LLM connected
           through (bridge only) and the session it was on. They belong to
           the actor, so they live here rather than in the event meta strip. --%>
      <div
        :if={@mcp_client || @mcp_session}
        class="mt-2 space-y-1 border-t border-zinc-800/70 pt-2 text-[11px]"
      >
        <p :if={@mcp_client} class="flex items-center gap-1.5 truncate text-zinc-400">
          <.icon name="hero-cpu-chip" class="h-3 w-3 shrink-0 text-zinc-600" />
          <span class="truncate" title={@mcp_client_host}>
            MCP client: {@mcp_client}<span :if={@mcp_client_host} class="text-zinc-500">
              · {@mcp_client_host}</span>
            <span :if={@mcp_client_os} class="text-zinc-500">
              · {@mcp_client_os}
            </span>
          </span>
        </p>
        <p :if={@mcp_session} class="truncate font-mono text-[10px] text-zinc-500">
          MCP session <span class="text-zinc-400">{@mcp_session}</span>
        </p>
      </div>
    </div>
    """
  end

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
