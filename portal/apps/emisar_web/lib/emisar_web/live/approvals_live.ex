defmodule EmisarWeb.ApprovalsLive do
  @moduledoc """
  Single page that unifies what used to be two separate surfaces:
  pending + decided approval requests, and the standing grants that
  let identical follow-up calls bypass approval. Operators come here
  for one of three things and they all share the same context, so
  splitting them across two routes was just clicks.

  Order is engagement-driven:

    1. **Pending** — the loud amber cards at top; what needs you now.
    2. **Standing grants** — what's still letting calls through; the
       only place to revoke them.
    3. **Recent decisions** — last 25 approve/deny calls for history.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Approvals, Catalog, Runners, Users}
  alias EmisarWeb.{LiveTable, Permissions}

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Approvals.subscribe_account_approvals(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Approvals")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:approval_updated, _}, socket), do: {:noreply, reload(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      Approvals.subject_can_manage_grants?(socket.assigns.current_subject),
      fn socket ->
        case Approvals.fetch_grant_by_id(id, socket.assigns.current_subject) do
          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Grant not found.")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

          {:ok, grant} ->
            # Audit logging lives inside `Approvals.revoke_grant/2` so the
            # transaction is atomic and other callers (future scripts /
            # tasks) can't accidentally skip it.
            case Approvals.revoke_grant(grant, socket.assigns.current_subject) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Grant revoked. New calls will require fresh approval.")
                 |> reload()}

              _ ->
                {:noreply, put_flash(socket, :error, "Could not revoke grant.")}
            end
        end
      end
    )
  end

  # The max grant-lifetime cap (account setting) governs how long the standing
  # grants below can keep auto-approving, so it's edited here, beside them —
  # owner/admin only; server-enforced in Approvals.create_grant.
  def handle_event("set_max_grant_lifetime", %{"seconds" => raw}, socket) do
    if Accounts.subject_can_manage_account_security?(socket.assigns.current_subject) do
      apply_grant_lifetime_cap(socket, parse_grant_lifetime(raw))
    else
      {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}
    end
  end

  defp load(socket, params) do
    subject = socket.assigns.current_subject

    pending_opts = LiveTable.params_to_opts(params, [], prefix: "pending_")
    grants_opts = LiveTable.params_to_opts(params, [], prefix: "grants_")
    decided_opts = LiveTable.params_to_opts(params, [], prefix: "decided_")

    # Pending is the held-action danger: an {:error, _} (incl. :unauthorized)
    # collapsed to [] reads as "Nothing waiting", hiding a run awaiting a human.
    # Track the error so the section can say "couldn't load" instead. (Grants
    # and decided below are historical/secondary — list_or_empty is fine there.)
    {pending, pending_meta, pending_error?} =
      case Approvals.list_pending_approval_requests(subject, pending_opts) do
        {:ok, list, meta} -> {list, meta, false}
        _ -> {[], %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0}, true}
      end

    {:ok, grants, grants_meta} =
      list_or_empty(
        Approvals.list_grants_for_account(
          subject,
          Keyword.put(grants_opts, :preload, [
            :api_key,
            :runner,
            :granted_by,
            :approval_request_run
          ])
        )
      )

    # Decided-only AT THE QUERY — the old "all minus pending" client-side
    # subtraction made the pager count include pending rows it never showed
    # ("2 / 4 total" with no Next), a dead end on a governance surface.
    {:ok, decided, decided_meta} =
      list_or_empty(
        Approvals.list_approval_requests_for_account(
          subject,
          Keyword.put(decided_opts, :status, :decided)
        )
      )

    socket
    |> assign(:pending, pending)
    |> assign(:pending_metadata, pending_meta)
    |> assign(:pending_error?, pending_error?)
    |> assign(:grants, grants)
    |> assign(:grants_metadata, grants_meta)
    |> assign(:decided, decided)
    |> assign(:decided_metadata, decided_meta)
    |> assign(:filter_params, params)
    |> assign(:runner_labels, runner_labels_for(pending ++ decided))
    |> assign(:user_labels, user_labels_for(pending ++ decided))
    # Risk tier per pending request so the queue is triageable at a glance — an
    # approver shouldn't have to open each card to see if it's a scary one.
    |> assign(:risk_labels, risk_labels_for(pending, subject))
  end

  defp list_or_empty({:ok, _, _} = ok), do: ok

  defp list_or_empty(_) do
    {:ok, [], %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0}}
  end

  defp runner_labels_for(requests) do
    requests
    |> Enum.map(&runner_id_from/1)
    |> Runners.runner_labels_for_ids()
  end

  defp user_labels_for(requests) do
    ids =
      Enum.flat_map(requests, fn r ->
        [r.requested_by_id, r.decided_by_id]
      end)

    Users.user_labels_for_ids(ids)
  end

  defp runner_id_from(%{context: %{"runner_id" => id}}) when is_binary(id), do: id
  defp runner_id_from(_), do: nil

  defp risk_labels_for(requests, subject) do
    for request <- requests, into: %{}, do: {request.id, risk_for_request(request, subject)}
  end

  defp risk_for_request(
         %{context: %{"action_id" => action_id, "runner_id" => runner_id}},
         subject
       )
       when is_binary(action_id) and is_binary(runner_id) do
    case Catalog.fetch_action_by_id(action_id, runner_id, subject) do
      {:ok, action} -> action.risk
      _ -> nil
    end
  end

  defp risk_for_request(_request, _subject), do: nil

  defp runner_label(request, labels) do
    id = runner_id_from(request)

    cond do
      id && labels[id] -> labels[id]
      id -> String.slice(id, 0, 8) <> "…"
      true -> "—"
    end
  end

  defp user_label(nil, _labels), do: "—"
  defp user_label(id, labels), do: labels[id] || String.slice(id, 0, 8) <> "…"

  # -- Grant helpers (moved from old GrantsLive) ---------------------

  defp grant_key_label(%{api_key: %{name: n, key_prefix: p}}) when is_binary(n),
    do: "#{n} (#{p}…)"

  defp grant_key_label(%{api_key: %{key_prefix: p}}) when is_binary(p), do: "#{p}…"
  defp grant_key_label(_), do: "(deleted key)"

  # New grants start at uses_count=1 — minting a grant also dispatches the
  # run it was approved from, and that execution counts. The 0 clauses
  # stay as a fallback for legacy grants minted before that was recorded.
  defp format_uses(%{uses_count: 0, max_uses: nil}), do: "not used yet"
  defp format_uses(%{uses_count: 0, max_uses: max}), do: "not used yet · cap #{max}"
  defp format_uses(%{uses_count: c, max_uses: nil}), do: "#{c} #{pluralize(c, "use")}"
  defp format_uses(%{uses_count: c, max_uses: max}), do: "#{c} / #{max} uses"

  # A grant's expiry — "no expiry" when open-ended, else "expires 3m
  # ago" with the timestamp through <.local_time> (viewer-local,
  # hoverable, live); {" "} keeps "expires" off the <time> tag.
  attr :grant, :map, required: true

  defp expiry_status(%{grant: %{expires_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :expires_at, ts)

    ~H"""
    expires{" "}<.local_time value={@expires_at} mode={:relative} />
    """
  end

  defp expiry_status(assigns), do: ~H"no expiry"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  # The exact arguments an `:exact_args` grant is locked to, as a "k=v"
  # summary. The grant row stores only the hash, so we read the raw args
  # off the originating run (preloaded via `approval_request`). Returns
  # nil for any-args grants, no-arg actions, or a since-pruned run — the
  # scope chip already covers those.
  defp grant_args_line(%{args_sha256: nil}), do: nil

  defp grant_args_line(%{approval_request: %{run: %{args: args}}})
       when is_map(args) and map_size(args) > 0 do
    args
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{grant_arg_value(v)}" end)
  end

  defp grant_args_line(_), do: nil

  defp grant_arg_value(v) when is_binary(v), do: v
  defp grant_arg_value(v), do: inspect(v)

  defp apply_grant_lifetime_cap(socket, :error) do
    {:noreply, put_flash(socket, :error, "Pick a valid grant-lifetime cap.")}
  end

  defp apply_grant_lifetime_cap(socket, {:ok, seconds}) do
    case Accounts.update_account(
           socket.assigns.current_account,
           %{settings: %{max_grant_lifetime_seconds: seconds}},
           socket.assigns.current_subject
         ) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:current_account, account)
         |> put_flash(:info, grant_lifetime_flash(seconds))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update the grant-lifetime cap.")}
    end
  end

  defp parse_grant_lifetime(""), do: {:ok, nil}

  defp parse_grant_lifetime(raw) do
    case Integer.parse(raw) do
      {seconds, ""} when seconds > 0 -> {:ok, seconds}
      _ -> :error
    end
  end

  defp grant_lifetime_flash(nil), do: "Grant-lifetime cap removed — grants can use any window."
  defp grant_lifetime_flash(_seconds), do: "Grant-lifetime cap updated."

  defp grant_lifetime_label(3_600), do: "1 hour"
  defp grant_lifetime_label(86_400), do: "1 day"
  defp grant_lifetime_label(2_592_000), do: "30 days"
  defp grant_lifetime_label(7_776_000), do: "90 days"
  defp grant_lifetime_label(seconds), do: "#{seconds} s"

  defp grant_lifetime_options(current) do
    [
      %{value: "", label: "No cap", selected: is_nil(current), disabled: false},
      %{value: "3600", label: "1 hour", selected: current == 3_600, disabled: false},
      %{value: "86400", label: "1 day", selected: current == 86_400, disabled: false},
      %{value: "2592000", label: "30 days", selected: current == 2_592_000, disabled: false},
      %{value: "7776000", label: "90 days", selected: current == 7_776_000, disabled: false}
    ]
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:approvals}
      width={:table}
    >
      <:title>Approvals</:title>

      <.page_intro>
        Gated actions wait here for a human decision before they run — approve or deny,
        with the reason logged to the audit trail.
        <.doc_link href="/docs/policies-and-approvals">Approvals docs</.doc_link>
      </.page_intro>

      <div class="space-y-6">
        <%!-- 1. PENDING --%>
        <section>
          <.section_header title="Pending" />

          <LiveTable.live_table
            layout={:cards}
            id="pending"
            path={~p"/app/#{@current_account}/approvals"}
            prefix="pending_"
            rows={@pending}
            metadata={@pending_metadata}
            filter_params={@filter_params}
            wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <%!-- Canvas rows, not amber boxes — amber stays on the STATUS (the
                 pending dot, the expiry), the dashboard's approvals grammar. --%>
            <:item :let={request}>
              <li>
                <.link
                  navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
                  class="group -mx-2 flex items-start gap-3 rounded-md px-2 py-3.5 transition hover:bg-white/[0.04]"
                >
                  <.status_dot tone={:amber} size={:md} class="mt-1" />
                  <div class="min-w-0 flex-1">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="truncate font-mono text-sm text-zinc-200">
                        {request.context["action_id"] || "—"}
                      </span>
                      <.risk_pill
                        :if={@risk_labels[request.id]}
                        risk={@risk_labels[request.id]}
                        class="flex-none"
                      />
                    </div>
                    <div class="mt-0.5 truncate text-xs text-zinc-500">
                      on {runner_label(request, @runner_labels)} · requested by {user_label(
                        request.requested_by_id,
                        @user_labels
                      )}
                    </div>
                    <p
                      :if={request.reason && request.reason != ""}
                      class="mt-1 text-sm italic text-zinc-400"
                    >
                      "{request.reason}"
                    </p>
                  </div>
                  <div class="shrink-0 text-right">
                    <div class="text-xs text-zinc-500">
                      <.local_time value={request.requested_at} mode={:relative} />
                    </div>
                    <%!-- Held runs auto-cancel at expiry — surface it so an
                         approver can triage by urgency, not just arrival. --%>
                    <.approval_expiry expires_at={request.expires_at} class="mt-0.5 justify-end" />
                  </div>
                </.link>
              </li>
            </:item>
            <:empty>
              <.empty_state
                :if={@pending_error?}
                variant={:bare}
                tone={:danger}
                icon="hero-exclamation-triangle"
                title="Couldn't load pending approvals."
              >
                This is a load error, not an empty queue — a held action may be waiting.
                Refresh the page; if it persists, your access may have changed.
              </.empty_state>
              <.empty_state
                :if={not @pending_error?}
                variant={:bare}
                icon="hero-check-badge"
                title="Nothing waiting."
              >
                Approvals show up here when
                <.link
                  navigate={~p"/app/#{@current_account}/policies"}
                  class="text-brand-400 hover:text-brand-300"
                >
                  policy
                </.link>
                gates a run as <code class="text-zinc-300">require_approval</code>
                — for example a high-risk
                mutating action from an LLM. You'll get an email too.
              </.empty_state>
            </:empty>
          </LiveTable.live_table>
        </section>

        <%!-- 2. STANDING GRANTS --%>
        <section>
          <.section_header title="Standing grants">
            <:subtitle>Approvals that auto-allow follow-up calls for a bounded window.</:subtitle>
          </.section_header>

          <LiveTable.live_table
            layout={:cards}
            id="grants"
            path={~p"/app/#{@current_account}/approvals"}
            prefix="grants_"
            rows={@grants}
            metadata={@grants_metadata}
            filter_params={@filter_params}
            wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <%!-- Canvas rows; the per-row key icon died with the island — every
                 row wearing the same glyph decorated nothing. --%>
            <:item :let={g}>
              <.list_row padding="py-4">
                <:title>
                  <span class="truncate font-mono text-sm text-zinc-100">{g.action_id}</span>
                </:title>
                <:chips>
                  <.chip>runner: {if g.runner, do: g.runner.name, else: "any"}</.chip>
                  <.chip>args: {if g.args_sha256, do: "exact", else: "any"}</.chip>
                  <.chip :if={g.expires_at == nil} tone={:rose}>No expiry</.chip>
                </:chips>
                <:meta>
                  <div
                    :if={grant_args_line(g)}
                    class="truncate font-mono text-zinc-400"
                    title={grant_args_line(g)}
                  >
                    {grant_args_line(g)}
                  </div>

                  <.meta_line class="mt-1">
                    <:seg>via {grant_key_label(g)}</:seg>
                    <:seg :if={g.granted_by}>
                      granted by {g.granted_by.full_name || g.granted_by.email}
                    </:seg>
                    <:seg>{format_uses(g)}</:seg>
                  </.meta_line>

                  <.meta_line class="mt-0.5">
                    <:seg><.expiry_status grant={g} /></:seg>
                    <:seg>
                      last used{" "}<.local_time
                        value={g.last_used_at}
                        mode={:relative}
                        placeholder="never"
                      />
                    </:seg>
                  </.meta_line>
                </:meta>
                <:actions>
                  <.button
                    :if={Approvals.subject_can_manage_grants?(@current_subject)}
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    phx-click="revoke_grant"
                    phx-value-id={g.id}
                    data-confirm={"Revoke this grant? Calls to #{g.action_id} from #{(g.api_key && g.api_key.name) || "the key"} will require fresh approval."}
                  >
                    Revoke
                  </.button>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <.empty_state variant={:bare} icon="hero-key" title="No active grants.">
                Grants appear when you approve a run with a duration other than
                <em>just this call</em>
                — they let the same LLM client re-run the same action
                inside the window without re-asking. Revocable here at any time.
              </.empty_state>
            </:empty>
          </LiveTable.live_table>

          <%!-- Max grant-lifetime cap — owner/admin. Bounds how long an approved
               standing grant can keep skipping the prompt; single-use ("once") is
               always exempt. Server-enforced in Approvals.create_grant. BELOW the
               grants it governs (list first, settings after); collapsed — the
               current cap rides in the header. Choice→consequence: an UNCAPPED
               account wears amber with what that means; a set cap is quiet. --%>
          <.collapsible_section
            id="approvals-grant-cap"
            title="Maximum grant lifetime"
            class="mt-5"
          >
            <:summary>
              <%!-- Status = dot + word; the explanation rides as quiet prose
                   (a sentence-long amber pill shouted, and read as contradicting
                   the per-grant "expires …" rows below — this is the ACCOUNT
                   cap, not those grants). --%>
              <span
                :if={is_nil(@current_account.settings.max_grant_lifetime_seconds)}
                class="flex items-center gap-1.5 text-xs"
              >
                <.status_dot tone={:amber} size={:sm} />
                <span class="text-amber-300">no cap</span>
                <span class="hidden text-zinc-500 sm:inline">
                  — approved grants expire only as approved
                </span>
              </span>
              <span
                :if={@current_account.settings.max_grant_lifetime_seconds}
                class="text-xs text-zinc-400"
              >
                {grant_lifetime_label(@current_account.settings.max_grant_lifetime_seconds)}
              </span>
            </:summary>

            <p class="mb-4 max-w-prose text-xs leading-relaxed text-zinc-400">
              Cap how long an approved grant can keep skipping the prompt. Single-use
              ("once") approvals are always allowed; the limit is enforced server-side.
            </p>

            <%= cond do %>
              <% not Accounts.subject_can_manage_account_security?(@current_subject) -> %>
                <p class="text-[11px] text-zinc-600">
                  Owner/admin only — the current cap is shown above.
                </p>
              <% true -> %>
                <form phx-change="set_max_grant_lifetime" class="max-w-xs">
                  <.select
                    name="seconds"
                    aria-label="Maximum grant lifetime"
                    options={
                      grant_lifetime_options(@current_account.settings.max_grant_lifetime_seconds)
                    }
                  />
                </form>
            <% end %>
          </.collapsible_section>
        </section>

        <%!-- 3. RECENT DECISIONS --%>
        <section>
          <.section_header title="Recent decisions" />

          <LiveTable.live_table
            layout={:cards}
            id="decided"
            path={~p"/app/#{@current_account}/approvals"}
            prefix="decided_"
            rows={@decided}
            metadata={@decided_metadata}
            filter_params={@filter_params}
            wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <:item :let={request}>
              <li>
                <.link
                  navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
                  class="-mx-2 flex items-center justify-between gap-3 rounded-md px-2 py-3 text-sm transition hover:bg-white/[0.04]"
                >
                  <div class="min-w-0 flex-1">
                    <div class="truncate font-mono text-sm text-zinc-200">
                      {request.context["action_id"] || "—"}
                    </div>
                    <div class="truncate text-xs text-zinc-500">
                      on {runner_label(request, @runner_labels)}
                      <%!-- The status badge on the right carries the outcome word
                           (approved / denied / expired); the meta just attributes
                           the decider. An expired request has none, so it shows
                           only the badge. --%>
                      <span :if={request.decided_by_id}>
                        · decided by {user_label(request.decided_by_id, @user_labels)}
                      </span>
                    </div>
                  </div>
                  <div class="flex shrink-0 items-center gap-3">
                    <.local_time
                      value={request.decided_at || request.requested_at}
                      mode={:relative}
                      class="text-xs text-zinc-500"
                    />
                    <.status_badge status={request.status} />
                  </div>
                </.link>
              </li>
            </:item>
            <:empty>
              <.empty_state
                variant={:bare}
                icon="hero-clipboard-document-check"
                title="No decided approvals yet."
              >
                When you approve or deny a pending request, the decision lands here.
                Useful for re-checking who approved what, and when.
              </.empty_state>
            </:empty>
          </LiveTable.live_table>
        </section>
      </div>
    </.dashboard_shell>
    """
  end
end
