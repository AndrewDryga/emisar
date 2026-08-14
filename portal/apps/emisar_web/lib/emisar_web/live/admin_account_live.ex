defmodule EmisarWeb.AdminAccountLive do
  @moduledoc """
  One account's whole support picture, read-only: billing, roster, SSO, fleet,
  runs, MCP, and the tail of its audit trail.

  Two things this page must never do. It never renders a run's arguments,
  output, or any other payload field — `Emisar.Admin` hands back whole
  `%Runs.ActionRun{}` structs, so the restraint lives here, and the no-leak
  regression test pins it. And it never mutates: every support write goes
  through the private emisar-admin pack over release RPC, so a staff read
  cannot become a staff write by finding the right button.

  Opening the page appends `staff.account_viewed` to the CUSTOMER's own audit
  trail — access transparency, so only the connected mount writes it.
  """
  use EmisarWeb, :live_view
  import EmisarWeb.StaffComponents
  alias Emisar.{Admin, Auth}

  def mount(%{"id" => id}, _session, socket) do
    # IL-18: mount runs twice. The connected guard keeps the eight-query
    # overview off the dead render AND is what makes the audit row exactly one
    # per view rather than two.
    if connected?(socket),
      do: load_account(socket, id),
      else: {:ok, assign(socket, page_title: "Account", overview: nil)}
  end

  defp load_account(socket, id) do
    case Admin.account_overview(id, socket.assigns.current_user) do
      {:ok, overview} ->
        {:ok, _event} = Admin.record_account_view(overview.account, socket.assigns.current_user)

        {:ok, assign(socket, page_title: overview.account.name, overview: overview)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Account not found.")
         |> push_navigate(to: ~p"/admin")}
    end
  end

  def render(assigns) do
    ~H"""
    <.staff_shell current_user={@current_user}>
      <:title>
        <.detail_header back="Accounts" navigate={~p"/admin"} title={@page_title} />
      </:title>

      <.loading_state :if={is_nil(@overview)} />

      <%!-- ONE page wrapper owns the rhythm (§3.3); every block below is a
           sibling section on the canvas, never a card inside a card. --%>
      <div :if={@overview} class="space-y-12">
        <.meta_strip>
          <.meta_field label="Slug">
            <span class="font-mono">{@overview.account.slug}</span>
          </.meta_field>
          <.meta_field label="Account ID" wrap>
            <.copyable_id value={@overview.account.id} />
          </.meta_field>
          <.meta_field label="Created">
            <.local_time value={@overview.account.inserted_at} mode={:absolute} />
          </.meta_field>
          <.meta_field :if={@overview.account.disabled_at} label="Disabled">
            <.local_time value={@overview.account.disabled_at} mode={:absolute} />
          </.meta_field>
        </.meta_strip>

        <div>
          <.section_header title="Billing" />
          <dl class="mt-2 max-w-md text-sm">
            <.kv label="Plan">{@overview.billing.plan}</.kv>
            <.kv label="Source">{@overview.billing.source}</.kv>
            <.kv :if={@overview.billing.subscription_status} label="Subscription status">
              {@overview.billing.subscription_status}
            </.kv>
          </dl>

          <div class="mt-4 max-w-md space-y-2">
            <.code_line
              :if={@overview.account.paddle_customer_id}
              id="paddle-customer-id"
              label="Paddle customer"
              value={@overview.account.paddle_customer_id}
            />
            <.code_line
              :if={@overview.billing.paddle_subscription_id}
              id="paddle-subscription-id"
              label="Paddle subscription"
              value={@overview.billing.paddle_subscription_id}
            />
          </div>

          <p class="mt-4 text-xs text-zinc-400">
            <.inline_code text="Change a plan with `emisar.admin.plan.grant`; re-read Paddle with `emisar.admin.billing.sync`." />
          </p>
        </div>

        <div>
          <.section_header title="Members" count={length(@overview.members)} />
          <.empty_state :if={@overview.members == []} variant={:bare} title="No members.">
            Nobody can sign in to this account.
          </.empty_state>
          <ul
            :if={@overview.members != []}
            class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row
              :for={membership <- @overview.members}
              id={"member-#{membership.id}"}
              padding="py-4"
            >
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">
                  {membership.user.email}
                </span>
              </:title>
              <:chips>
                <.chip>{Auth.role_label(membership.role)}</.chip>
                <%!-- Both states can hold at once (an invitee suspended before
                     they ever accepted), so neither shadows the other. --%>
                <.chip :if={is_nil(membership.invitation_accepted_at)}>Invitation pending</.chip>
                <.chip :if={membership.disabled_at}>Suspended</.chip>
              </:chips>
              <:meta :if={membership.user.full_name}>{membership.user.full_name}</:meta>
            </.list_row>
          </ul>
        </div>

        <div>
          <.section_header title="Single sign-on" count={length(@overview.sso)} />
          <.empty_state :if={@overview.sso == []} variant={:bare} title="No providers configured.">
            Everyone signs in with a magic link.
          </.empty_state>
          <ul
            :if={@overview.sso != []}
            class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row
              :for={provider <- @overview.sso}
              id={"provider-#{provider.id}"}
              padding="py-4"
            >
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">{provider.name}</span>
              </:title>
              <:chips>
                <%!-- The raw enum value, not a humanized label: the one label map
                     lives in SSOSettingsLive, and a second copy here would drift
                     the moment a kind is added. --%>
                <.chip mono>{provider.kind}</.chip>
                <.chip :if={provider.enabled} tone={:brand}>Enabled</.chip>
                <.chip :if={!provider.enabled}>Disabled</.chip>
              </:chips>
            </.list_row>
          </ul>
        </div>

        <div>
          <.section_header title="Fleet" />
          <div class="mt-2 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <.stat label="Connected" value={@overview.fleet.counts.connected} />
            <.stat label="Disconnected" value={@overview.fleet.counts.disconnected} />
            <.stat label="Never connected" value={@overview.fleet.counts.never_connected} />
            <.stat label="Disabled" value={@overview.fleet.counts.disabled} />
          </div>

          <.empty_state
            :if={@overview.fleet.runners == []}
            variant={:bare}
            title="No runners enrolled."
            class="mt-6"
          >
            Nothing in this account can execute an action yet.
          </.empty_state>
          <ul
            :if={@overview.fleet.runners != []}
            class="mt-6 divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row
              :for={runner <- @overview.fleet.runners}
              id={"runner-#{runner.id}"}
              padding="py-4"
            >
              <:title>
                <span class="truncate font-mono text-sm text-zinc-100">{runner.name}</span>
              </:title>
              <:chips>
                <.chip :if={runner.disabled_at}>Disabled</.chip>
              </:chips>
              <%!-- The durable connect/disconnect columns, not a live verdict:
                   presence is not in this read, and a stale "connected" on a
                   support surface is worse than the timestamps themselves. --%>
              <:meta>
                <.meta_line>
                  <:seg :if={runner.hostname} mono>{runner.hostname}</:seg>
                  <:seg>
                    last connected{" "}<.local_time
                      id={"runner-connected-#{runner.id}"}
                      value={runner.last_connected_at}
                      mode={:relative}
                      placeholder="never"
                    />
                  </:seg>
                </.meta_line>
              </:meta>
            </.list_row>
          </ul>
        </div>

        <div>
          <.section_header title="Runs" />
          <div class="mt-2 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <.stat label="Runs" value={@overview.runs.count_30d} hint="last 30 days" />
          </div>

          <.empty_state
            :if={@overview.runs.recent == []}
            variant={:bare}
            title="No runs yet."
            class="mt-6"
          >
            This account has never dispatched an action.
          </.empty_state>
          <%!-- Identity, status, and timing only. A run row carries the
                customer's arguments and output; neither ever renders here. --%>
          <ul
            :if={@overview.runs.recent != []}
            class="mt-6 divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row :for={run <- @overview.runs.recent} id={"run-#{run.id}"} padding="py-4">
              <:title>
                <span class="min-w-0 break-words font-mono text-sm text-zinc-100">
                  <.dotted_mono value={run.action_id} />
                </span>
              </:title>
              <:chips>
                <.status_badge status={run.status} />
              </:chips>
              <:meta>
                <.meta_line>
                  <:seg :if={run.runner_ref} mono>{run.runner_ref}</:seg>
                  <:seg>
                    <.local_time
                      id={"run-at-#{run.id}"}
                      value={run.inserted_at}
                      mode={:relative}
                    />
                  </:seg>
                </.meta_line>
              </:meta>
            </.list_row>
          </ul>
        </div>

        <div>
          <.section_header title="LLM agents" />
          <div class="mt-2 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <.stat label="Active API keys" value={@overview.mcp.active_api_keys} />
          </div>

          <.empty_state
            :if={@overview.mcp.recent_clients == []}
            variant={:bare}
            title="No MCP activity."
            class="mt-6"
          >
            No agent has dispatched an action here in the last 30 days.
          </.empty_state>
          <ul
            :if={@overview.mcp.recent_clients != []}
            class="mt-6 divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row
              :for={{client, index} <- Enum.with_index(@overview.mcp.recent_clients)}
              id={"mcp-client-#{index}"}
              padding="py-4"
            >
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">{client.client}</span>
              </:title>
              <:meta>{client.runs} runs in the last 30 days</:meta>
            </.list_row>
          </ul>
        </div>

        <div>
          <.section_header title="Recent audit events" />
          <.empty_state :if={@overview.audit_tail == []} variant={:bare} title="Nothing recorded.">
            This account's trail is empty.
          </.empty_state>
          <ul
            :if={@overview.audit_tail != []}
            class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <.list_row :for={event <- @overview.audit_tail} id={"event-#{event.id}"} padding="py-4">
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">
                  {format_event_type(event.event_type)}
                </span>
              </:title>
              <:meta>
                <.meta_line>
                  <:seg :if={event.actor_label}>{event.actor_label}</:seg>
                  <:seg>
                    <.local_time
                      id={"event-at-#{event.id}"}
                      value={event.occurred_at}
                      mode={:relative}
                    />
                  </:seg>
                </.meta_line>
              </:meta>
            </.list_row>
          </ul>
        </div>

        <%!-- The command-line glyph, not an external-link arrow: this note is a
             posture fact about where changes enter, not a link to somewhere. --%>
        <%!-- The top bar's chip already says read-only and the billing section
             already names its two action ids; what this adds is where a
             mutation SURFACES — in the customer's trail, like any other run. --%>
        <.status_note icon="hero-command-line" title="Where support changes happen">
          Every mutation enters through the private emisar-admin pack, so it arrives in this
          account's own audit trail as an ordinary run.
        </.status_note>
      </div>
    </.staff_shell>
    """
  end
end
