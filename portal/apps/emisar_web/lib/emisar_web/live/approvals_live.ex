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

  alias Emisar.{Accounts, Approvals, PubSub, Runners}
  alias EmisarWeb.{LiveTable, Permissions}

  def mount(_params, _session, socket) do
    if connected?(socket),
      do: PubSub.subscribe_account_approvals(socket.assigns.current_account.id)

    {:ok, assign(socket, :page_title, "Approvals")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params)}
  end

  def handle_info({:approval_updated, _}, socket), do: {:noreply, reload(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp reload(socket), do: load(socket, socket.assigns[:filter_params] || %{})

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    Permissions.gated(socket, :decide_approval, fn s ->
      case Approvals.fetch_grant_by_id(id, s.assigns.current_subject) do
        {:error, :not_found} ->
          {:noreply, put_flash(s, :error, "Grant not found.")}

        {:ok, grant} ->
          # Audit logging lives inside `Approvals.revoke_grant/2` so the
          # transaction is atomic and other callers (future scripts /
          # tasks) can't accidentally skip it.
          case Approvals.revoke_grant(grant, s.assigns.current_subject) do
            {:ok, _} ->
              {:noreply,
               s
               |> put_flash(:info, "Grant revoked. New calls will require fresh approval.")
               |> reload()}

            _ ->
              {:noreply, put_flash(s, :error, "Could not revoke grant.")}
          end
      end
    end)
  end

  defp load(socket, params) do
    subject = socket.assigns.current_subject

    pending_opts = LiveTable.params_to_opts(params, [], prefix: "pending_")
    grants_opts = LiveTable.params_to_opts(params, [], prefix: "grants_")
    decided_opts = LiveTable.params_to_opts(params, [], prefix: "decided_")

    {:ok, pending, pending_meta} = list_or_empty(Approvals.list_pending_approval_requests(subject, pending_opts))
    {:ok, grants, grants_meta} = list_or_empty(Approvals.list_grants_for_account(subject, grants_opts))

    # "Decided" = the full list minus the ones already showing in the
    # Pending section above (only relevant on page 1 — on later pages
    # the cursors don't overlap). Caps keep the section tight.
    {:ok, all_recent, decided_meta} = list_or_empty(Approvals.list_approval_requests_for_account(subject, decided_opts))
    decided = all_recent -- pending

    socket
    |> assign(:pending, pending)
    |> assign(:pending_metadata, pending_meta)
    |> assign(:grants, grants)
    |> assign(:grants_metadata, grants_meta)
    |> assign(:decided, decided)
    |> assign(:decided_metadata, decided_meta)
    |> assign(:filter_params, params)
    |> assign(:runner_labels, runner_labels_for(pending ++ all_recent))
    |> assign(:user_labels, user_labels_for(pending ++ all_recent))
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

    Accounts.user_labels_for_ids(ids)
  end

  defp runner_id_from(%{context: %{"runner_id" => id}}) when is_binary(id), do: id
  defp runner_id_from(_), do: nil

  defp runner_label(req, labels) do
    id = runner_id_from(req)

    cond do
      id && labels[id] -> labels[id]
      id -> String.slice(id, 0, 8) <> "…"
      true -> "—"
    end
  end

  defp user_label(nil, _labels), do: "—"
  defp user_label(id, labels), do: labels[id] || (String.slice(id, 0, 8) <> "…")

  # -- Grant helpers (moved from old GrantsLive) ---------------------

  defp grant_key_label(%{api_key: %{name: n, key_prefix: p}}) when is_binary(n),
    do: "#{n} (#{p}…)"

  defp grant_key_label(%{api_key: %{key_prefix: p}}) when is_binary(p), do: "#{p}…"
  defp grant_key_label(_), do: "(deleted key)"

  # Fresh grants always start with uses_count=0 — say so plainly
  # instead of "0 uses", which reads like the grant was somehow
  # consumed-but-not-consumed and confuses operators.
  defp format_uses(%{uses_count: 0, max_uses: nil}), do: "not used yet"
  defp format_uses(%{uses_count: 0, max_uses: max}), do: "not used yet · cap #{max}"
  defp format_uses(%{uses_count: c, max_uses: nil}), do: "#{c} #{pluralize(c, "use")}"
  defp format_uses(%{uses_count: c, max_uses: max}), do: "#{c} / #{max} uses"

  defp expires_label(%{expires_at: nil}), do: "no expiry"
  defp expires_label(%{expires_at: ts}), do: "expires #{relative_time(ts)}"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  def render(assigns) do
    ~H"""
    <.dashboard_shell pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:approvals}
    >
      <:title>Approvals</:title>

      <.page_container max="5xl">
        <%!-- 1. PENDING --%>
        <section>
          <header class="mb-3 flex items-center gap-2">
            <h2 class="text-sm font-semibold text-zinc-100">Pending</h2>
            <span
              :if={@pending_metadata.count > 0}
              class="rounded bg-amber-500/20 px-1.5 py-0.5 text-xs font-medium text-amber-200"
            >
              {@pending_metadata.count}
            </span>
          </header>

          <LiveTable.live_table
            layout={:cards}
            id="pending"
            path={~p"/app/approvals"}
            prefix="pending_"
            rows={@pending}
            metadata={@pending_metadata}
            filter_params={@filter_params}
            wrapper_class="space-y-2"
          >
            <:item :let={req}>
              <li>
                <.link
                  navigate={~p"/app/approvals/#{req.id}"}
                  class="block rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-4 transition hover:border-amber-500/50 hover:bg-amber-500/[0.07]"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="truncate font-mono text-sm font-semibold text-amber-100">
                        {req.context["action_id"] || "—"}
                      </div>
                      <div class="mt-0.5 truncate text-xs text-amber-200/70">
                        on {runner_label(req, @runner_labels)}
                        · requested by {user_label(req.requested_by_id, @user_labels)}
                      </div>
                    </div>
                    <span class="shrink-0 text-xs text-amber-200/70">
                      {relative_time(req.requested_at)}
                    </span>
                  </div>
                  <p :if={req.reason && req.reason != ""} class="mt-2 text-sm italic text-zinc-300">
                    "{req.reason}"
                  </p>
                </.link>
              </li>
            </:item>
            <:empty>
              Nothing waiting. Approvals appear here when a policy gates a run.
            </:empty>
          </LiveTable.live_table>
        </section>

        <%!-- 2. STANDING GRANTS --%>
        <section>
          <header class="mb-3 flex items-baseline justify-between gap-2">
            <div class="flex items-center gap-2">
              <h2 class="text-sm font-semibold text-zinc-100">Standing grants</h2>
              <span
                :if={@grants_metadata.count > 0}
                class="rounded bg-zinc-800 px-1.5 py-0.5 text-xs font-medium text-zinc-300"
              >
                {@grants_metadata.count}
              </span>
            </div>
            <p class="hidden text-xs text-zinc-500 sm:block">
              Approvals that auto-allow follow-up calls for a bounded window. Revocable here.
            </p>
          </header>

          <LiveTable.live_table
            layout={:cards}
            id="grants"
            path={~p"/app/approvals"}
            prefix="grants_"
            rows={@grants}
            metadata={@grants_metadata}
            filter_params={@filter_params}
          >
            <:item :let={g}>
              <li class="flex items-start gap-4 px-5 py-3">
                <span class="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                  <.icon name="hero-key" class="h-3.5 w-3.5" />
                </span>

                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="truncate font-mono text-sm text-zinc-100">{g.action_id}</span>
                    <.chip>runner: {if g.runner, do: g.runner.name, else: "any"}</.chip>
                    <.chip>args: {if g.args_sha256, do: "exact", else: "any"}</.chip>
                    <.chip :if={g.expires_at == nil} tone={:rose}>No expiry</.chip>
                  </div>

                  <div class="mt-1 truncate text-xs text-zinc-500">
                    via {grant_key_label(g)}
                    <span :if={g.granted_by}>· granted by {g.granted_by.email}</span>
                    · {format_uses(g)}
                  </div>

                  <div class="mt-0.5 text-xs text-zinc-500">
                    {expires_label(g)} · last used {last_used(g.last_used_at)}
                  </div>
                </div>

                <button
                  :if={Permissions.can?(assigns, :decide_approval)}
                  phx-click="revoke_grant"
                  phx-value-id={g.id}
                  data-confirm={"Revoke this grant? Calls to #{g.action_id} from #{(g.api_key && g.api_key.name) || "the key"} will require fresh approval."}
                  class="shrink-0 rounded-lg border border-rose-500/40 px-2.5 py-1 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
                >
                  Revoke
                </button>
              </li>
            </:item>
            <:empty>
              No active grants. They appear when an operator approves a run with a duration
              other than "just this call".
            </:empty>
          </LiveTable.live_table>
        </section>

        <%!-- 3. RECENT DECISIONS --%>
        <section>
          <header class="mb-3 flex items-center gap-2">
            <h2 class="text-sm font-semibold text-zinc-100">Recent decisions</h2>
          </header>

          <LiveTable.live_table
            layout={:cards}
            id="decided"
            path={~p"/app/approvals"}
            prefix="decided_"
            rows={@decided}
            metadata={@decided_metadata}
            filter_params={@filter_params}
          >
            <:item :let={req}>
              <li>
                <.link
                  navigate={~p"/app/approvals/#{req.id}"}
                  class="flex items-center justify-between gap-3 px-4 py-3 text-sm transition hover:bg-zinc-900/40"
                >
                  <div class="min-w-0 flex-1">
                    <div class="truncate font-mono text-sm text-zinc-200">
                      {req.context["action_id"] || "—"}
                    </div>
                    <div class="truncate text-xs text-zinc-500">
                      on {runner_label(req, @runner_labels)}
                      <span :if={req.decided_by_id}>
                        · {String.capitalize(req.status)} by {user_label(req.decided_by_id, @user_labels)}
                      </span>
                    </div>
                  </div>
                  <div class="flex shrink-0 items-center gap-3">
                    <span class="text-xs text-zinc-500">
                      {relative_time(req.decided_at || req.requested_at)}
                    </span>
                    <.status_badge status={req.status} />
                  </div>
                </.link>
              </li>
            </:item>
            <:empty>
              Decided approvals will be listed here.
            </:empty>
          </LiveTable.live_table>
        </section>
      </.page_container>
    </.dashboard_shell>
    """
  end
end
