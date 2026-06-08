defmodule EmisarWeb.AuditDetailLive do
  @moduledoc """
  Single audit event detail view. Shareable URL for incident response:
  paste `/app/audit/:id` into a Slack thread, post in a postmortem.

  Renders every field on the event: when, type, actor + subject (with
  links into their detail pages when one exists), IP, user agent,
  request id, and the full payload as pretty JSON.
  """
  use EmisarWeb, :live_view

  alias Emisar.Audit
  alias EmisarWeb.AuditSummary

  def mount(%{"id" => id}, _session, socket) do
    case Audit.fetch_event_by_id(id, socket.assigns.current_subject) do
      {:ok, event} ->
        refs = Audit.resolve_references([event])

        {:ok,
         socket
         |> assign(:page_title, "Audit · #{event.event_type}")
         |> assign(:event, event)
         |> assign(:refs, refs)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Audit event not found.")
         |> push_navigate(to: ~p"/app/audit")}
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
    >
      <:title>
        <.back_link navigate={~p"/app/audit"}>Audit log</.back_link>
        <span class="font-semibold">{format_event_type(@event.event_type)}</span>
        <span class="ml-2 font-mono text-xs font-normal text-zinc-500">{@event.event_type}</span>
      </:title>
      <% posture = parse_client_posture(@event.user_agent) %>

      <%!-- Meta strip — consistent with run / approval / runner
           detail. When occurred, where from, request id. Bridge
           UAs get extra cells for client + host. --%>
      <.meta_strip cols={if(posture.bridge?, do: 5, else: 3)}>
        <.meta_field label="When">
          <.local_time value={@event.occurred_at} class="text-zinc-200" />
        </.meta_field>
        <.meta_field label="IP address">
          <span class="font-mono text-xs text-zinc-300">{@event.ip_address || "—"}</span>
        </.meta_field>
        <.meta_field label="Request ID">
          <span class="font-mono text-xs text-zinc-400">{@event.request_id || "—"}</span>
        </.meta_field>
        <.meta_field :if={@event.mcp_session_id} label="MCP session">
          <span class="font-mono text-xs text-zinc-400">{@event.mcp_session_id}</span>
        </.meta_field>
        <.meta_field :if={posture.bridge?} label="Client">
          <span class="text-xs text-zinc-200">{posture.client || "—"}</span>
        </.meta_field>
        <.meta_field :if={posture.bridge?} label="Client host">
          <span class="font-mono text-xs text-zinc-300">{posture.host || "—"}</span>
        </.meta_field>
      </.meta_strip>

      <%!-- Actor → Subject row. The arrow makes the relationship
           visual ("user X acted ON runner Y") instead of forcing
           the reader to mentally pair two separate cards. The
           User-Agent rides on the actor card — it describes the
           actor's device, not the event in general. --%>
      <div class="mt-4 flex flex-col items-stretch gap-3 sm:flex-row sm:items-center">
        <.entity_card
          role="Actor"
          kind={@event.actor_kind}
          id={@event.actor_id}
          label={@event.actor_label}
          refs={@refs}
          user_agent={@event.user_agent}
        />
        <div class="hidden flex-none items-center sm:flex">
          <.icon name="hero-arrow-right" class="h-5 w-5 text-zinc-700" />
        </div>
        <.entity_card
          role="Subject"
          kind={@event.subject_kind}
          id={@event.subject_id}
          label={@event.subject_label}
          refs={@refs}
        />
      </div>

      <%!-- At-a-glance summary chips — the "interesting fact" pulled
           from the payload (via, role from→to, count, etc.). Used to
           live in the breadcrumb but operators couldn't scan it
           there; this row lets it breathe and stays out of the
           page-title chrome. Hidden when the event type has no
           special summary (most do not). --%>
      <section
        :if={AuditSummary.summary_pairs(@event) != []}
        class="mt-4 flex flex-wrap items-center gap-2 rounded-xl border border-zinc-900 bg-zinc-950/40 px-4 py-3"
      >
        <span class="text-[10px] font-semibold uppercase tracking-[0.12em] text-zinc-500">
          Summary
        </span>
        <span
          :for={pair <- AuditSummary.summary_pairs(@event)}
          class="inline-flex items-center gap-1 rounded-md bg-zinc-900/80 px-2 py-0.5 text-xs ring-1 ring-zinc-800"
        >
          <span class="font-mono text-zinc-500">{elem(pair, 0)}:</span>
          <span class="text-zinc-200">{elem(pair, 1)}</span>
        </span>
      </section>

      <%!-- Policy-update diff — special-case rendering for the one
           event type where the payload diff is the whole reason
           anyone opens the page. Falls through to plain JSON below
           for everything else. --%>
      <.policy_changes
        :if={@event.event_type == "policy.updated" and is_map(@event.payload)}
        changes={@event.payload["changes"] || %{}}
      />

      <%!-- Payload — primary content on the page. Wide and tall,
           terminal-style for the JSON. --%>
      <section class="mt-6 overflow-hidden rounded-xl border border-zinc-900">
        <header class="flex items-center justify-between border-b border-zinc-900 bg-zinc-950/60 px-4 py-2">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Payload</h3>
          <span
            class="ml-3 min-w-0 flex-1 truncate text-right font-mono text-[11px] text-zinc-500"
            title={@event.id}
          >
            event:{@event.id}
          </span>
        </header>
        <pre class="max-h-[60vh] overflow-auto bg-black p-4 font-mono text-xs leading-relaxed text-zinc-300">{pretty_payload(@event.payload)}</pre>
      </section>
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
    <section
      :if={@defaults_diff != %{} or @added != [] or @removed != [] or @changed != []}
      class="mt-6 overflow-hidden rounded-xl border border-zinc-900"
    >
      <header class="border-b border-zinc-900 bg-zinc-950/60 px-4 py-2">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
          Changes
        </h3>
      </header>

      <div class="space-y-4 p-4">
        <%= if @defaults_diff != %{} do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
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
                <code class="rounded bg-emerald-500/10 px-1.5 py-0.5 text-[11px] text-emerald-300">
                  {to || "—"}
                </code>
              </li>
            </ul>
          </div>
        <% end %>

        <%= if @added != [] do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-emerald-300">
              Added overrides ({length(@added)})
            </p>
            <ul class="space-y-1 text-xs">
              <li :for={ov <- @added} class="rounded bg-emerald-500/[0.04] px-2 py-1">
                <code class="font-mono text-zinc-200">{ov["action"]}</code>
                <span class="text-zinc-500">→</span>
                <code class="font-mono text-emerald-300">{ov["decision"]}</code>
                <span :if={ov["name"] && ov["name"] != ""} class="ml-2 text-zinc-500">
                  ({ov["name"]})
                </span>
              </li>
            </ul>
          </div>
        <% end %>

        <%= if @removed != [] do %>
          <div>
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-rose-300">
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
            <p class="mb-2 text-[10px] font-semibold uppercase tracking-wider text-amber-300">
              Modified overrides ({length(@changed)})
            </p>
            <ul class="space-y-1 text-xs">
              <li :for={c <- @changed} class="rounded bg-amber-500/[0.04] px-2 py-1">
                <code class="font-mono text-zinc-200">{c["action"]}</code>:
                <code class="rounded bg-rose-500/10 px-1.5 py-0.5 text-rose-300">
                  {c["from"]["decision"]}
                </code>
                <span class="text-zinc-600">→</span>
                <code class="rounded bg-emerald-500/10 px-1.5 py-0.5 text-emerald-300">
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
  attr :kind, :string, default: nil
  attr :id, :any, default: nil
  attr :label, :string, default: nil
  attr :refs, :map, default: %{}
  attr :user_agent, :string, default: nil

  defp entity_card(%{kind: nil} = assigns) do
    ~H"""
    <div class="flex-1 rounded-xl border border-zinc-900 bg-zinc-950/40 p-4">
      <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">{@role}</div>
      <p class="mt-1 text-sm text-zinc-500">— (not recorded)</p>
    </div>
    """
  end

  defp entity_card(assigns) do
    ~H"""
    <div class="min-w-0 flex-1 rounded-xl border border-zinc-900 bg-zinc-950/40 p-4">
      <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">{@role}</div>
      <div class="mt-1 text-sm">
        <EmisarWeb.AuditLive.ref kind={@kind} id={@id} label={@label} refs={@refs} />
      </div>
      <p :if={@id} class="mt-1 break-all font-mono text-[10px] text-zinc-500">{@id}</p>
      <%!-- Device line — what they were using when they did this.
           Browser/OS for human users, "MCP bridge" for LLM clients,
           raw UA token for everything else. The full UA string is
           one click away via the `title=` tooltip. --%>
      <p
        :if={@user_agent}
        class="mt-2 flex items-center gap-1.5 truncate text-[11px] text-zinc-500"
        title={@user_agent}
      >
        <.icon name={device_icon(@user_agent)} class="h-3 w-3 shrink-0 text-zinc-600" />
        <span class="truncate">{device_label(@user_agent)}</span>
      </p>
    </div>
    """
  end

  # Compact device label for the UA — same parser shape as ProfileLive's
  # session list, so the audit page and the profile page agree about
  # "what does this string mean." Strips the verbose Mozilla/AppleWebKit
  # cruft into something a reader can scan.
  defp device_label(ua) when is_binary(ua) do
    browser =
      cond do
        ua =~ ~r/Edg\//i -> "Edge"
        ua =~ ~r/Chrome\//i -> "Chrome"
        ua =~ ~r/Firefox\//i -> "Firefox"
        ua =~ ~r/Safari\//i and not (ua =~ ~r/Chrome\//i) -> "Safari"
        ua =~ ~r/^Go-http-client/i -> "Runner (Go)"
        true -> nil
      end

    os =
      cond do
        ua =~ ~r/Mac OS X/i -> "Mac"
        ua =~ ~r/Windows/i -> "Windows"
        ua =~ ~r/iPhone|iPad|iOS/i -> "iOS"
        ua =~ ~r/Android/i -> "Android"
        ua =~ ~r/Linux/i -> "Linux"
        true -> nil
      end

    case {browser, os} do
      {nil, nil} -> short_ua(ua)
      {b, nil} -> b
      {nil, o} -> o
      {b, o} -> "#{b} on #{o}"
    end
  end

  defp device_label(_), do: nil

  # Last-resort: the first whitespace-delimited token, so a missing UA
  # parser doesn't print a 200-char Mozilla string into the card.
  defp short_ua(ua) do
    case Regex.run(~r{^([^\s]+)}, ua) do
      [_, token] -> token
      _ -> "Unknown device"
    end
  end

  defp device_icon(ua) when is_binary(ua) do
    cond do
      ua =~ ~r/iPhone|iPad|Android/i -> "hero-device-phone-mobile"
      ua =~ ~r/Mozilla|WebKit/i -> "hero-computer-desktop"
      ua =~ ~r/^Go-http-client/i -> "hero-server"
      true -> "hero-globe-alt"
    end
  end

  defp device_icon(_), do: "hero-globe-alt"

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
  defp parse_client_posture(nil), do: %{bridge?: false, client: nil, host: nil, bridge: nil}

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
      host: Map.get(fields, "host")
    }
  end
end
