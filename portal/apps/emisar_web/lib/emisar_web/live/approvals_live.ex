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
  alias Emisar.{Accounts, Approvals, Audit, Runners}
  alias EmisarWeb.{ConfirmDialog, LiveTable, Permissions}
  alias Phoenix.LiveView.JS

  @reload_debounce_ms 500

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> ConfirmDialog.init()
     |> assign(:page_title, "Approvals")
     # The notice describes the list, so it is derived where the list is —
     # `load/2` re-reads current access on every load and debounced refresh. The
     # dead render has no rows yet, so it makes no claim about them.
     |> assign(:pack_access_restricted?, false)
     |> assign(:reload_scheduled?, false)}
  end

  # IL-18: the dead render shows `<.loading_state />`, so paying the page's
  # three list reads plus label/risk batches on it doubled every first paint.
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply, load(socket, params)}
    else
      {:noreply, assign(socket, :filter_params, params)}
    end
  end

  # A runbook deciding a batch of approvals broadcasts once per request, and
  # every open sockets pays the full page load per event — coalesce like the
  # dashboard/runs feeds do.
  def handle_info({:approval_updated, _}, socket), do: {:noreply, schedule_reload(socket)}

  def handle_info(:reload_approvals, socket),
    do: {:noreply, socket |> assign(:reload_scheduled?, false) |> reload()}

  def handle_info(_, socket), do: {:noreply, socket}

  defp schedule_reload(socket) do
    if socket.assigns.reload_scheduled? do
      socket
    else
      Process.send_after(self(), :reload_approvals, @reload_debounce_ms)
      assign(socket, :reload_scheduled?, true)
    end
  end

  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  def handle_event("confirm_typed", params, socket),
    do: {:noreply, ConfirmDialog.put_typed(socket, params)}

  def handle_event("confirm_reset", _params, socket),
    do: {:noreply, ConfirmDialog.reset(socket)}

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

  def handle_event("revoke_all_grants", _params, socket) do
    Permissions.gated(
      socket,
      Approvals.subject_can_manage_grants?(socket.assigns.current_subject),
      &revoke_all_grants/1
    )
  end

  # The max grant-lifetime cap (account setting) governs how long the standing
  # grants below can keep auto-approving, so it's edited here, beside them.
  # Approvals owns what the raw value MEANS — including that 0 disables standing
  # grants and revokes the ones already out there; this only maps the outcome.
  def handle_event("set_max_grant_lifetime", %{"seconds" => _} = attrs, socket) do
    case Approvals.update_grant_lifetime_settings(
           socket.assigns.current_account,
           attrs,
           socket.assigns.current_subject
         ) do
      {:ok, %{account: account, revoked_count: revoked_count}} ->
        {:noreply, cap_updated(socket, account, revoked_count)}

      # The cap stuck, so the grants left behind are already inert — show the
      # swept page and say plainly what could not be cleaned up.
      {:error, :grants_partially_revoked, %{account: account, revoked_count: revoked_count}} ->
        {:noreply,
         socket
         |> assign(:current_account, account)
         |> load(socket.assigns.filter_params)
         |> put_flash(:error, grant_cap_partially_revoked_flash(revoked_count))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins can change this setting.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Pick a valid grant-lifetime cap.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update the grant-lifetime cap.")}
    end
  end

  # A crafted event that drops the "seconds" key would otherwise match no clause
  # and crash the socket.
  def handle_event("set_max_grant_lifetime", _params, socket), do: {:noreply, socket}

  defp revoke_all_grants(socket) do
    case Approvals.revoke_all_grants(socket.assigns.current_subject) do
      {:ok, revoked_count} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, grants_revoked_flash(revoked_count))}

      {:error, :grants_partially_revoked, revoked_count, _reason} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:error, grants_partially_revoked_flash(revoked_count))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not revoke standing grants. Refresh and try again.")}
    end
  end

  defp load(socket, params) do
    subject = socket.assigns.current_subject

    # Three tables share one page — compact 10-row pages keep every section
    # scannable (the Paginator's 20/the decided read's 100 defaults let one
    # busy section swallow the page); the pager takes over past that.
    pending_opts =
      LiveTable.params_to_opts(params, [], prefix: "pending_") |> put_page_limit(10)

    grants_opts = LiveTable.params_to_opts(params, [], prefix: "grants_") |> put_page_limit(10)
    decided_opts = LiveTable.params_to_opts(params, [], prefix: "decided_") |> put_page_limit(10)

    # Each of the three sections carries its OWN read failure. An {:error, _}
    # collapsed to [] reads as "Nothing waiting" / "No active grants" — hiding a
    # run awaiting a human, or a standing grant that is right now letting an
    # agent skip the prompt. A section the subject has no permission for is a
    # different message, so its denial never renders as a read failure: grants
    # need manage_grants (admin+), which an operator or viewer simply lacks.
    {pending, pending_meta, pending_error?} =
      list_read(Approvals.list_pending_approval_requests(subject, pending_opts))

    grants_read_opts =
      Keyword.put(grants_opts, :preload, [:api_key, :runner, :approval_request_run])

    {grants, grants_meta, grants_failed?} =
      list_read(Approvals.list_grants_for_account(subject, grants_read_opts))

    can_manage_grants? = Approvals.subject_can_manage_grants?(subject)
    grants_error? = grants_failed? and can_manage_grants?
    grants_denied? = grants_failed? and not can_manage_grants?

    # Decided-only AT THE QUERY — the old "all minus pending" client-side
    # subtraction made the pager count include pending rows it never showed
    # ("2 / 4 total" with no Next), a dead end on a governance surface.
    decided_read_opts = Keyword.put(decided_opts, :status, :decided)

    {decided, decided_meta, decided_error?} =
      list_read(Approvals.list_approval_requests_for_account(subject, decided_read_opts))

    # ONE projection time for the whole page: two rows must not disagree about a
    # deadline that falls between their renders, and what an expiry MEANS
    # (lapsed? how long left?) is Approvals', not the badge's, to decide.
    now = DateTime.utc_now()
    pending_facts = Map.new(pending, &{&1.id, Approvals.request_facts(&1, now)})
    approval_event_refs = approval_event_refs(grants, subject)

    socket
    # The rows above were narrowed by CURRENT pack access, read fresh inside
    # each list call. Derive the notice from the same projection rather than the
    # mount-time membership snapshot, or a member whose access is narrowed (or
    # widened) mid-session keeps reading the wrong explanation for a list that
    # already changed underneath them.
    |> assign(
      :pack_access_restricted?,
      Accounts.runner_access_for_subject(subject).pack_mode == :restricted
    )
    |> assign(:pending, pending)
    |> assign(:pending_request_facts, pending_facts)
    |> assign(:pending_metadata, pending_meta)
    |> assign(:pending_error?, pending_error?)
    |> assign(:grants, grants)
    |> assign(:grants_metadata, grants_meta)
    |> assign(:grants_error?, grants_error?)
    |> assign(:grants_denied?, grants_denied?)
    |> assign(:approval_event_refs, approval_event_refs)
    |> assign(:decided, decided)
    |> assign(:decided_metadata, decided_meta)
    |> assign(:decided_error?, decided_error?)
    |> assign(:filter_params, params)
    |> assign(:runner_labels, runner_labels_for(subject.account.id, pending ++ decided))
    |> assign(:user_labels, user_labels_for(pending ++ decided, grants, subject))
    # Risk tier per pending request so the queue is triageable at a glance — an
    # approver shouldn't have to open each card to see if it's a scary one.
    |> assign(:risk_labels, risk_labels_for(pending, subject))
  end

  defp approval_event_refs(grants, subject) do
    request_ids = grants |> Enum.map(& &1.approval_request_id) |> Enum.reject(&is_nil/1)

    case Audit.approval_event_refs(request_ids, subject) do
      {:ok, refs} -> refs
      {:error, _reason} -> %{}
    end
  end

  defp grant_approval_event_id(grant, refs) do
    get_in(refs, [grant.approval_request_id, :final])
  end

  defp put_page_limit(opts, limit) do
    page = opts |> Keyword.get(:page, []) |> Keyword.put_new(:limit, limit)
    Keyword.put(opts, :page, page)
  end

  # A section's read as {rows, metadata, read_failed?}. The empty list is the
  # RENDER shape only — the third element is what keeps a failed read from
  # rendering as this section's ordinary empty state.
  defp list_read({:ok, list, meta}), do: {list, meta, false}

  defp list_read(_) do
    {[], %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0}, true}
  end

  defp runner_labels_for(account_id, requests) do
    ids = Enum.map(requests, &runner_id_from/1)
    Runners.runner_labels_for_ids(account_id, ids)
  end

  # One account-local label lookup for every human this page names — the
  # requesters and deciders of the listed requests, plus whoever minted each
  # standing grant. A denied or oversized read degrades to no labels, which the
  # renderer already shows as "Former member".
  defp user_labels_for(requests, grants, subject) do
    ids =
      Enum.flat_map(requests, fn r -> [r.requested_by_id, r.decided_by_id] end) ++
        Enum.map(grants, & &1.granted_by_id)

    case Approvals.actor_labels_for_ids(ids, subject) do
      {:ok, labels} -> labels
      {:error, _reason} -> %{}
    end
  end

  defp runner_id_from(%{context: %{"runner_id" => id}}) when is_binary(id), do: id
  defp runner_id_from(_), do: nil

  defp risk_labels_for(requests, subject) do
    case Approvals.risk_by_request_ids(Enum.map(requests, & &1.id), subject) do
      {:ok, risks} -> risks
      {:error, _reason} -> %{}
    end
  end

  # A labels miss means the runner row is gone — an honest label beats an id
  # fragment; the detail page still carries the frozen runner id in full.
  defp runner_label(request, labels) do
    id = runner_id_from(request)

    cond do
      id && labels[id] -> labels[id]
      id -> "a removed runner"
      true -> "—"
    end
  end

  defp request_scope_label(
         %{context: %{"kind" => "runbook_execution", "plan" => plan}},
         _labels
       ) do
    stages = Map.get(plan, "stages", [])
    items = Enum.flat_map(stages, &Map.get(&1, "items", []))
    runners = items |> Enum.map(& &1["runner_ref"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    "#{length(stages)} #{plural(length(stages), "stage")} · " <>
      "#{length(items)} #{plural(length(items), "action")} across " <>
      "#{length(runners)} #{plural(length(runners), "runner")}"
  end

  defp request_scope_label(request, labels), do: "on #{runner_label(request, labels)}"

  defp plural(1, noun), do: noun
  defp plural(_count, noun), do: noun <> "s"

  defp user_label(nil, _labels), do: "—"
  # A labels miss means the user row is gone — the approval detail page
  # renders the same state as "Former member", so the two surfaces agree.
  defp user_label(id, labels), do: labels[id] || "Former member"

  # -- Grant helpers (moved from old GrantsLive) ---------------------

  # The key NAME is the identity — a truncated prefix rendered the same shared
  # literal on every row (the agents list dropped it for the same reason); the
  # prefix survives only as the fallback for a name-less key, where it's all
  # there is.
  defp grant_key_label(%{api_key: %{name: n}}) when is_binary(n) and n != "", do: n
  defp grant_key_label(%{api_key: %{key_prefix: p}}) when is_binary(p), do: "#{p}…"
  defp grant_key_label(_), do: "(deleted key)"

  # New grants start at uses_count=1 — minting a grant also dispatches the
  # run it was approved from, and that execution counts. The 0 clauses
  # stay as a fallback for legacy grants minted before that was recorded.
  # Plain English — "1 use" read as "1 use REMAINING"; "used once" can't.
  defp format_uses(%{uses_count: 0, max_uses: nil}), do: "not used yet"
  defp format_uses(%{uses_count: 0, max_uses: max}), do: "not used yet · cap #{max}"
  defp format_uses(%{uses_count: 1, max_uses: nil}), do: "used once"
  defp format_uses(%{uses_count: c, max_uses: nil}), do: "used #{c} times"
  defp format_uses(%{uses_count: c, max_uses: max}), do: "used #{c} of #{max}"

  # A grant's expiry — "no expiry" when open-ended, else "expires 3m
  # ago" with the timestamp through <.local_time> (viewer-local,
  # hoverable, live); {" "} keeps "expires" off the <time> tag.
  attr :grant, :map, required: true

  defp expiry_status(%{grant: %{expires_at: %DateTime{} = ts}} = assigns) do
    assigns = assign(assigns, :expires_at, ts)

    ~H"""
    expires{" "}<.local_time id={"grant-expiry-#{@grant.id}"} value={@expires_at} mode={:relative} />
    """
  end

  defp expiry_status(assigns), do: ~H"no expiry"

  # Keep the exact scope inspectable without repeating argument values. Some
  # values are secrets, and the grant row intentionally stores only the hash.
  defp grant_args_line(%{args_sha256: nil}), do: nil

  defp grant_args_line(%{args_sha256: sha}) when is_binary(sha), do: "sha256:#{sha}"

  # Disabling swept the grants listed below, so those tables have to re-read;
  # any other cap only changes the guardrail copy.
  defp cap_updated(socket, %{settings: %{max_grant_lifetime_seconds: 0}} = account, revoked_count) do
    socket
    |> assign(:current_account, account)
    |> load(socket.assigns.filter_params)
    |> put_flash(:info, grants_disabled_flash(revoked_count))
  end

  defp cap_updated(socket, account, _revoked_count) do
    socket
    |> assign(:current_account, account)
    |> put_flash(:info, grant_lifetime_flash(account.settings.max_grant_lifetime_seconds))
  end

  # 0 is the kill switch: minting AND matching refuse account-wide.
  defp grants_disabled?(account), do: account.settings.max_grant_lifetime_seconds == 0

  defp grant_lifetime_flash(nil), do: "Grant-lifetime cap removed — grants can use any window."
  defp grant_lifetime_flash(_seconds), do: "Grant-lifetime cap updated."

  defp grants_disabled_flash(0),
    do: "Standing grants disabled — every approval is now single-use."

  defp grants_disabled_flash(1),
    do: "Standing grants disabled — 1 active grant revoked; every approval is now single-use."

  defp grants_disabled_flash(n),
    do: "Standing grants disabled — #{n} active grants revoked; every approval is now single-use."

  defp grant_cap_partially_revoked_flash(revoked_count) do
    "Standing grants are disabled — every approval is now single-use — but only " <>
      "#{revoked_count} #{plural(revoked_count, "grant")} could be revoked. The rest can no " <>
      "longer authorize anything; try again to clear them from the list."
  end

  defp grants_revoked_flash(0), do: "No active standing grants remained in your access."

  defp grants_revoked_flash(1) do
    "Revoked 1 standing grant in your access. The affected client's next matching call will need fresh approval."
  end

  defp grants_revoked_flash(revoked_count) do
    "Revoked #{revoked_count} standing grants in your access. The affected clients' next matching calls will need fresh approval."
  end

  defp grants_partially_revoked_flash(0) do
    "No standing grants were revoked. Some grants in your access may remain active. Retry Revoke all."
  end

  defp grants_partially_revoked_flash(1) do
    "1 standing grant was revoked and stays revoked. Some grants in your access may remain active. Retry Revoke all."
  end

  defp grants_partially_revoked_flash(revoked_count) do
    "#{revoked_count} standing grants were revoked and stay revoked. Some grants in your access may remain active. Retry Revoke all."
  end

  defp can_revoke_all_grants?(subject, metadata, grants_error?) do
    not grants_error? and metadata.count > 0 and Approvals.subject_can_manage_grants?(subject)
  end

  # What a member who can't change the cap reads in its place. Worded like the
  # select's own options, so both audiences read the setting the same way — and
  # it covers the uncapped state, which had no rendering at all.
  defp grant_lifetime_value_label(nil), do: "No cap"
  defp grant_lifetime_value_label(0), do: "Disabled"
  defp grant_lifetime_value_label(seconds), do: grant_lifetime_label(seconds)

  defp grant_lifetime_label(3_600), do: "1 hour"
  defp grant_lifetime_label(86_400), do: "1 day"
  defp grant_lifetime_label(2_592_000), do: "30 days"
  defp grant_lifetime_label(7_776_000), do: "90 days"
  defp grant_lifetime_label(seconds), do: "#{seconds} s"

  # A strict→loose scale: disabled (no standing grants at all) up to no cap.
  defp grant_lifetime_options(current) do
    [
      %{
        value: "0",
        label: "Disabled — approvals are always single-use",
        selected: current == 0,
        disabled: false
      },
      %{value: "3600", label: "1 hour", selected: current == 3_600, disabled: false},
      %{value: "86400", label: "1 day", selected: current == 86_400, disabled: false},
      %{value: "2592000", label: "30 days", selected: current == 2_592_000, disabled: false},
      %{value: "7776000", label: "90 days", selected: current == 7_776_000, disabled: false},
      %{value: "", label: "No cap", selected: is_nil(current), disabled: false}
    ]
  end

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:approvals}
      width={:table}
    >
      <:title>Approvals</:title>

      <.page_intro>
        Actions and whole runbook executions pause here before they run. Review the exact frozen
        work, then approve or deny; your reason is logged.
        <.doc_link href={~p"/docs/policies-and-approvals"}>Approvals docs</.doc_link>
        <span :if={@pack_access_restricted?} class="mt-2 block">
          Your pack access limits this page to approvals and grants for packs you can use.
        </span>
      </.page_intro>

      <.loading_state :if={not connected?(@socket)} />
      <%!-- Three canvas sections need RHYTHM, not chrome: generous vertical
           air is what says "a new table starts here". --%>
      <div :if={connected?(@socket)} class="space-y-12">
        <%!-- 1. PENDING --%>
        <section class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
          <div class="min-w-0">
            <.section_header title="Pending" />

            <LiveTable.live_table
              layout={:cards}
              id="pending"
              path={~p"/app/#{@current_account}/approvals"}
              prefix="pending_"
              rows={@pending}
              metadata={@pending_metadata}
              filter_params={@filter_params}
              wrapper_class="divide-y divide-zinc-800/70"
            >
              <%!-- Canvas rows, not amber boxes — amber stays on the STATUS (the
                 pending dot, the expiry), the dashboard's approvals grammar. --%>
              <:item :let={request}>
                <% facts = @pending_request_facts[request.id] %>
                <li>
                  <.link
                    navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
                    class="group -mx-2 flex items-start gap-3 rounded-md px-2 py-3.5 transition hover:bg-white/[0.04]"
                  >
                    <%!-- (20px title line − 8px dot) / 2 = 6px — measured to the FIRST
                       text line, not eyeballed. --%>
                    <.status_dot tone={:amber} size={:md} class="mt-1.5" />
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="truncate font-mono text-sm text-zinc-200">
                          {Approvals.request_name(request) || "—"}
                        </span>
                        <.risk_pill
                          :if={@risk_labels[request.id]}
                          id={"pending-#{request.id}-risk"}
                          risk={@risk_labels[request.id]}
                          class="flex-none"
                        />
                      </div>
                      <div class="mt-0.5 text-xs text-zinc-400 sm:truncate">
                        {request_scope_label(request, @runner_labels)} · requested by {user_label(
                          request.requested_by_id,
                          @user_labels
                        )}
                      </div>
                      <p
                        :if={request.reason && request.reason != ""}
                        class="mt-1 text-sm italic text-zinc-400"
                      >
                        “{request.reason}”
                      </p>
                    </div>
                    <div class="shrink-0 text-right">
                      <div class="text-xs text-zinc-400">
                        <.local_time
                          id={"pending-when-#{request.id}"}
                          value={request.requested_at}
                          mode={:relative}
                        />
                      </div>
                      <%!-- Held runs auto-cancel at expiry — surface it so an
                         approver can triage by urgency, not just arrival. --%>
                      <.approval_expiry
                        id={"expiry-#{request.id}"}
                        expires_at={facts.expires_at}
                        expired?={facts.expired?}
                        expires_in_seconds={facts.expires_in_seconds}
                        class="mt-0.5 justify-end"
                      />
                    </div>
                  </.link>
                </li>
              </:item>
              <:empty>
                <.empty_state
                  :if={@pending_error?}
                  tone={:danger}
                  icon="state.warning"
                  title="Couldn't load pending approvals."
                >
                  This is a load error, not an empty queue — a held action may be waiting.
                  Refresh the page; if it persists, your access may have changed.
                </.empty_state>
                <.empty_state
                  :if={not @pending_error?}
                  icon="product.approval"
                  title="Nothing waiting."
                >
                  Approvals show up here when
                  <.link
                    navigate={~p"/app/#{@current_account}/policies"}
                    class="text-brand-400 hover:text-brand-300"
                  >
                    policy
                  </.link>
                  evaluates an action as <code class="text-zinc-300">require_approval</code>
                  — in a direct run or anywhere in a runbook. You'll get an email too.
                </.empty_state>
              </:empty>
            </LiveTable.live_table>
          </div>

          <.docs_rail title="What needs approval?">
            <p>
              A run lands here when
              <.link
                navigate={~p"/app/#{@current_account}/policies"}
                class="text-brand-400 hover:text-brand-300"
              >
                policy
              </.link>
              evaluates an action as <span class="font-mono text-[13px] text-zinc-300">require_approval</span>. A direct action creates one request for that run. A runbook with any gated item
              creates one request for its complete frozen execution.
            </p>
          </.docs_rail>
        </section>

        <%!-- 2. STANDING GRANTS --%>
        <section class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
          <div class="min-w-0">
            <.section_header title="Standing grants">
              <:subtitle :if={not grants_disabled?(@current_account)}>
                Approvals that auto-allow follow-up calls for a bounded window.
              </:subtitle>
              <:subtitle :if={grants_disabled?(@current_account)}>
                Disabled for this account — every approval is single-use.
              </:subtitle>
              <:actions :if={
                can_revoke_all_grants?(
                  @current_subject,
                  @grants_metadata,
                  @grants_error?
                )
              }>
                <.button
                  id="revoke-all-grants"
                  variant={:secondary}
                  tone={:rose}
                  size={:sm}
                  phx-click={show_confirm_dialog("revoke-all-grants-dialog")}
                >
                  Revoke all
                </.button>
              </:actions>
            </.section_header>

            <.confirm_dialog
              :if={
                can_revoke_all_grants?(
                  @current_subject,
                  @grants_metadata,
                  @grants_error?
                )
              }
              id="revoke-all-grants-dialog"
              title="Revoke all grants in your access?"
              confirm_label="Revoke all grants"
              confirm_token="REVOKE ALL"
              typed={@typed}
              on_confirm={
                JS.push("revoke_all_grants")
                |> hide_confirm_dialog("revoke-all-grants-dialog")
              }
            >
              <:body>
                This immediately revokes every active standing grant within your runner and pack access, including grants on other pages. Each affected client's next matching call will need fresh approval.
              </:body>
            </.confirm_dialog>

            <LiveTable.live_table
              layout={:cards}
              id="grants"
              path={~p"/app/#{@current_account}/approvals"}
              prefix="grants_"
              rows={@grants}
              metadata={@grants_metadata}
              filter_params={@filter_params}
              wrapper_class="divide-y divide-zinc-800/70"
            >
              <%!-- Canvas rows; the per-row key icon died with the island — every
                 row wearing the same glyph decorated nothing. --%>
              <:item :let={g}>
                <.list_row padding="py-4">
                  <:title>
                    <span class="truncate font-mono text-sm text-zinc-100">{g.action_id}</span>
                  </:title>
                  <:chips>
                    <.identity_tag
                      category="runner"
                      value={if g.runner, do: g.runner.name, else: "any"}
                    />
                    <.identity_tag category="args" value={if g.args_sha256, do: "exact", else: "any"} />
                    <.chip :if={g.expires_at == nil} tone={:amber}>no expiry</.chip>
                  </:chips>
                  <:meta>
                    <div
                      :if={grant_args_line(g)}
                      class="truncate font-mono text-zinc-400"
                      title={grant_args_line(g)}
                    >
                      {grant_args_line(g)}
                    </div>

                    <%!-- Line 1 = accountability: which key HOLDS the capability,
                       who granted it, and WHEN (an unexplained grant minted
                       during an incident window is exactly what an auditor
                       scans for). Line 2 = lifetime + usage. --%>
                    <.meta_line class="mt-1">
                      <:seg>via {grant_key_label(g)}</:seg>
                      <:seg :if={g.granted_by_id}>
                        granted by {user_label(g.granted_by_id, @user_labels)}
                        <.local_time
                          id={"grant-created-#{g.id}"}
                          value={g.inserted_at}
                          mode={:relative}
                        />
                      </:seg>
                    </.meta_line>

                    <.meta_line class="mt-0.5">
                      <:seg><.expiry_status grant={g} /></:seg>
                      <:seg>{format_uses(g)}</:seg>
                      <:seg>
                        last used{" "}<.local_time
                          id={"grant-used-#{g.id}"}
                          value={g.last_used_at}
                          mode={:relative}
                          placeholder="never"
                        />
                      </:seg>
                    </.meta_line>
                  </:meta>
                  <:actions>
                    <%!-- Navigation, but it shares this row with a bordered Revoke,
                         and a row wears ONE button grammar (§7.47) — so it takes the
                         :secondary face at Revoke's size, not the bare brand link. --%>
                    <.button
                      :if={grant_approval_event_id(g, @approval_event_refs)}
                      navigate={
                        ~p"/app/#{@current_account}/audit/#{grant_approval_event_id(g, @approval_event_refs)}"
                      }
                      variant={:secondary}
                      size={:sm}
                    >
                      Audit record
                    </.button>
                    <.confirm_button
                      :if={Approvals.subject_can_manage_grants?(@current_subject)}
                      id={"revoke-grant-#{g.id}"}
                      title="Revoke this grant?"
                      confirm_label="Revoke grant"
                      variant={:secondary}
                      tone={:rose}
                      size={:sm}
                      on_confirm={JS.push("revoke_grant", value: %{id: g.id})}
                    >
                      <:body>
                        Calls to {g.action_id} from {(g.api_key && g.api_key.name) || "the key"} will require fresh approval.
                      </:body>
                      Revoke
                    </.confirm_button>
                  </:actions>
                </.list_row>
              </:item>
              <:empty>
                <%!-- A standing grant is live authorization to skip the prompt, so
                     "No active grants." on a failed read — or on a read this
                     member may not do — understates what the account allows. --%>
                <.empty_state
                  :if={@grants_denied?}
                  icon="state.locked"
                  title="Only owners and admins can see standing grants."
                >
                  Grants may be active and letting agents skip the approval prompt — ask an
                  owner or admin to review them.
                </.empty_state>
                <.empty_state
                  :if={@grants_error?}
                  tone={:danger}
                  icon="state.warning"
                  title="Couldn't load standing grants"
                >
                  This is a load error, not an empty list — grants may well be active and letting
                  agents skip approval. Refresh the page; if it persists, your access may have
                  changed.
                </.empty_state>
                <.empty_state
                  :if={
                    not @grants_error? and not @grants_denied? and grants_disabled?(@current_account)
                  }
                  icon="state.disabled"
                  title="Standing grants are disabled."
                >
                  Every approval is single-use — agents re-ask each time. An owner or
                  admin can re-enable them under Maximum grant lifetime below.
                </.empty_state>
                <.empty_state
                  :if={
                    not @grants_error? and not @grants_denied? and
                      not grants_disabled?(@current_account)
                  }
                  icon="product.approval"
                  title="No active grants."
                >
                  Grants appear when you approve a run with a duration other than
                  <em>just this call</em>
                  — they let the same LLM client re-run the same action
                  inside the window without re-asking. Revocable here at any time.
                </.empty_state>
              </:empty>
            </LiveTable.live_table>
          </div>

          <aside class="space-y-6">
            <.docs_rail title="What's a standing grant?">
              <p>
                Approving with a duration mints a <span class="text-zinc-200">standing grant</span>: repeat calls of the same
                action by the same API key are auto-approved for that window instead of re-asking.
              </p>
            </.docs_rail>

            <div>
              <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
                Guardrails
              </h3>
              <%!-- Max grant-lifetime cap — owner/admin. Bounds how long an approved
                   standing grant can keep skipping the prompt; single-use ("once") is
                   always exempt. Server-enforced in Approvals.create_grant. What
                   "Disabled" costs an operator is stated where they meet it — the
                   select's own option, and the grants-list empty state. --%>
              <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — self-contained control card, the team-security rail grammar --%>
              <div id="approvals-grant-cap" class="mt-3 rounded-xl border border-zinc-800/80 p-4">
                <h4 class="text-sm font-medium text-zinc-100">Maximum grant lifetime</h4>
                <p class="mt-1 text-xs leading-relaxed text-zinc-400">
                  Cap how long an approved grant can keep skipping the prompt.
                  Single-use approvals are always allowed.
                </p>
                <.gated_setting
                  id="max-grant-lifetime"
                  can_change?={Approvals.subject_can_manage_grants?(@current_subject)}
                  value={
                    grant_lifetime_value_label(@current_account.settings.max_grant_lifetime_seconds)
                  }
                  who_can_change="Only owners and admins can change this."
                  class="mt-3"
                >
                  <form id="max-grant-lifetime-form" phx-change="set_max_grant_lifetime">
                    <.select
                      name="seconds"
                      aria-label="Maximum grant lifetime"
                      options={
                        grant_lifetime_options(@current_account.settings.max_grant_lifetime_seconds)
                      }
                    />
                  </form>
                </.gated_setting>
              </div>
            </div>
          </aside>
        </section>

        <%!-- 3. RECENT DECISIONS --%>
        <section class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
          <div class="min-w-0">
            <.section_header title="Recent decisions" />

            <LiveTable.live_table
              layout={:cards}
              id="decided"
              path={~p"/app/#{@current_account}/approvals"}
              prefix="decided_"
              rows={@decided}
              metadata={@decided_metadata}
              filter_params={@filter_params}
              wrapper_class="divide-y divide-zinc-800/70"
            >
              <:item :let={request}>
                <li>
                  <.link
                    navigate={~p"/app/#{@current_account}/approvals/#{request.id}"}
                    class="-mx-2 flex items-center justify-between gap-3 rounded-md px-2 py-3 text-sm transition hover:bg-white/[0.04]"
                  >
                    <div class="min-w-0 flex-1">
                      <div class="truncate font-mono text-sm text-zinc-200">
                        {Approvals.request_name(request) || "—"}
                      </div>
                      <div class="text-xs text-zinc-400 sm:truncate">
                        {request_scope_label(request, @runner_labels)}
                        <%!-- The status badge on the right carries the outcome word
                           (approved / denied / expired); the meta just attributes
                           the decider. An expired request has none, so it shows
                           only the badge. --%>
                        <span :if={request.requested_by_id}>
                          · requested by {user_label(request.requested_by_id, @user_labels)}
                        </span>
                        <span :if={request.decided_by_id}>
                          · decided by {user_label(request.decided_by_id, @user_labels)}
                        </span>
                      </div>
                    </div>
                    <div class="flex shrink-0 items-center gap-3">
                      <.local_time
                        id={"decided-when-#{request.id}"}
                        value={request.decided_at || request.requested_at}
                        mode={:relative}
                        class="text-xs text-zinc-400"
                      />
                      <.status_badge status={request.status} />
                    </div>
                  </.link>
                </li>
              </:item>
              <:empty>
                <.empty_state
                  :if={@decided_error?}
                  tone={:danger}
                  icon="state.warning"
                  title="Couldn't load the decision log"
                >
                  This is a load error, not an empty log — decisions may well be recorded.
                  Refresh the page; if it persists, your access may have changed.
                </.empty_state>
                <.empty_state
                  :if={not @decided_error?}
                  icon="product.approval"
                  title="No decided approvals yet."
                >
                  When you approve or deny a pending request, the decision lands here.
                  Useful for re-checking who approved what, and when.
                </.empty_state>
              </:empty>
            </LiveTable.live_table>
          </div>

          <.docs_rail title="The decision log">
            <p>
              Every decided request — <span class="text-zinc-200">approved</span>, <span class="text-zinc-200">denied</span>, or
              <span class="text-zinc-200">expired</span>
              — with who decided it and when.
            </p>
            <p>
              The full forensic trail — request context, the resolved command, reasons —
              lives in the <.link
                navigate={~p"/app/#{@current_account}/audit"}
                class="text-brand-400 hover:text-brand-300"
              >
                audit log</.link>.
            </p>
          </.docs_rail>
        </section>
      </div>
    </.console_shell>
    """
  end
end
