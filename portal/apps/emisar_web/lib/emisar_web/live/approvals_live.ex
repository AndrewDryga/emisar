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

  alias Emisar.{Approvals, Runners, Users}
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
      Approvals.subject_can_decide_approval?(socket.assigns.current_subject),
      fn socket ->
        case Approvals.fetch_grant_by_id(id, socket.assigns.current_subject) do
          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Grant not found.")}

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

  defp load(socket, params) do
    subject = socket.assigns.current_subject

    pending_opts = LiveTable.params_to_opts(params, [], prefix: "pending_")
    grants_opts = LiveTable.params_to_opts(params, [], prefix: "grants_")
    decided_opts = LiveTable.params_to_opts(params, [], prefix: "decided_")

    {:ok, pending, pending_meta} =
      list_or_empty(Approvals.list_pending_approval_requests(subject, pending_opts))

    {:ok, grants, grants_meta} =
      list_or_empty(Approvals.list_grants_for_account(subject, grants_opts))

    # "Decided" = the full list minus the ones already showing in the
    # Pending section above (only relevant on page 1 — on later pages
    # the cursors don't overlap). Caps keep the section tight.
    {:ok, all_recent, decided_meta} =
      list_or_empty(Approvals.list_approval_requests_for_account(subject, decided_opts))

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

    Users.user_labels_for_ids(ids)
  end

  defp runner_id_from(%{context: %{"runner_id" => id}}) when is_binary(id), do: id
  defp runner_id_from(_), do: nil

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

  defp expires_label(%{expires_at: nil}), do: "no expiry"
  defp expires_label(%{expires_at: ts}), do: "expires #{relative_time(ts)}"

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

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
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
            <:item :let={request}>
              <li>
                <.link
                  navigate={~p"/app/approvals/#{request.id}"}
                  class="block rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-4 transition hover:border-amber-500/50 hover:bg-amber-500/[0.07]"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="truncate font-mono text-sm font-semibold text-amber-100">
                        {request.context["action_id"] || "—"}
                      </div>
                      <div class="mt-0.5 truncate text-xs text-amber-200/70">
                        on {runner_label(request, @runner_labels)} · requested by {user_label(
                          request.requested_by_id,
                          @user_labels
                        )}
                      </div>
                    </div>
                    <span class="shrink-0 text-xs text-amber-200/70">
                      {relative_time(request.requested_at)}
                    </span>
                  </div>
                  <p
                    :if={request.reason && request.reason != ""}
                    class="mt-2 text-sm italic text-zinc-300"
                  >
                    "{request.reason}"
                  </p>
                </.link>
              </li>
            </:item>
            <:empty>
              <div class="mx-auto max-w-md">
                <.icon name="hero-check-badge" class="mx-auto h-8 w-8 text-zinc-700" />
                <p class="mt-3 text-zinc-300">Nothing waiting.</p>
                <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                  Approvals show up here when
                  <.link navigate={~p"/app/policies"} class="text-indigo-400 hover:text-indigo-300">
                    policy
                  </.link>
                  gates a run as <code class="text-zinc-300">require_approval</code>
                  — for example a high-risk
                  mutating action from an LLM. You'll get an email + a row here.
                </p>
              </div>
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
              <.list_row icon="hero-key" class="py-3">
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

                  <div class="mt-1 truncate">
                    via {grant_key_label(g)}
                    <span :if={g.granted_by}>· granted by {g.granted_by.email}</span>
                    · {format_uses(g)}
                  </div>

                  <div class="mt-0.5">
                    {expires_label(g)} · last used {last_used(g.last_used_at)}
                  </div>
                </:meta>
                <:actions>
                  <button
                    :if={Approvals.subject_can_decide_approval?(@current_subject)}
                    phx-click="revoke_grant"
                    phx-value-id={g.id}
                    data-confirm={"Revoke this grant? Calls to #{g.action_id} from #{(g.api_key && g.api_key.name) || "the key"} will require fresh approval."}
                    class="rounded-lg border border-rose-500/40 px-2.5 py-1 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
                  >
                    Revoke
                  </button>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <div class="mx-auto max-w-md">
                <.icon name="hero-key" class="mx-auto h-8 w-8 text-zinc-700" />
                <p class="mt-3 text-zinc-300">No active grants.</p>
                <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                  Grants appear when you approve a run with a duration other than
                  <em>just this call</em>
                  — they let the same LLM client re-run the same action
                  inside the window without re-asking. Revocable here at any time.
                </p>
              </div>
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
            <:item :let={request}>
              <li>
                <.link
                  navigate={~p"/app/approvals/#{request.id}"}
                  class="flex items-center justify-between gap-3 px-4 py-3 text-sm transition hover:bg-zinc-900/40"
                >
                  <div class="min-w-0 flex-1">
                    <div class="truncate font-mono text-sm text-zinc-200">
                      {request.context["action_id"] || "—"}
                    </div>
                    <div class="truncate text-xs text-zinc-500">
                      on {runner_label(request, @runner_labels)}
                      <span :if={request.decided_by_id}>
                        · {String.capitalize(to_string(request.status))} by {user_label(
                          request.decided_by_id,
                          @user_labels
                        )}
                      </span>
                    </div>
                  </div>
                  <div class="flex shrink-0 items-center gap-3">
                    <span class="text-xs text-zinc-500">
                      {relative_time(request.decided_at || request.requested_at)}
                    </span>
                    <.status_badge status={request.status} />
                  </div>
                </.link>
              </li>
            </:item>
            <:empty>
              <div class="mx-auto max-w-md">
                <.icon name="hero-clipboard-document-check" class="mx-auto h-8 w-8 text-zinc-700" />
                <p class="mt-3 text-zinc-300">No decided approvals yet.</p>
                <p class="mt-1 text-xs leading-relaxed text-zinc-500">
                  When you approve or deny a pending request, the decision lands here.
                  Useful for re-checking who approved what, and when.
                </p>
              </div>
            </:empty>
          </LiveTable.live_table>
        </section>
      </.page_container>
    </.dashboard_shell>
    """
  end
end
