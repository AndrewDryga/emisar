defmodule EmisarWeb.PacksLive do
  @moduledoc """
  Pack inventory + trust state across the account's runners.

  Each `(pack_id, version)` is one row holding the trusted hash + an
  optional pending hash. The page surfaces:

    * Which packs / versions are deployed.
    * **Pending trust** — a runner advertised a hash that doesn't
      match the trusted one. Dispatch refuses to authorize against
      pending versions until an admin clicks Trust or Reject.

  Pinning rules (see `Emisar.Catalog`):

    * First sight, hash matches our shipped baseline → trusted.
    * First sight, hash diverges from baseline → pending; baseline
      is the trusted hash, advertised is the pending.
    * First sight, no baseline (self-written / custom pack) →
      pending with NO trusted hash. Operator must Trust before any
      of its actions can run.
    * Hash later changes → pending.
  """
  use EmisarWeb, :live_view

  alias Emisar.Catalog

  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, "Packs")

    if connected?(socket) do
      {:ok, socket |> load_packs() |> assign(:loading?, false)}
    else
      # `mount` runs twice (dead render + connected mount) — the pack list
      # is up to 500 rows, so defer the read to the connected pass (IL-18)
      # and render an empty stream + loading shimmer on the dead one.
      {:ok,
       socket
       |> assign(:loading?, true)
       |> assign(:pack_count, 0)
       |> assign(:pending_count, 0)
       |> stream(:packs, [])}
    end
  end

  # Each stream entry is one pack group: `%{id: pack_id, versions: [...]}`.
  # The list is held by the stream (bounded socket memory), not a plain
  # assign. `reset: true` replaces the whole set on the connected mount and
  # after a mutation reload; targeted Trust/Reject updates a single group
  # via `stream_insert`/`stream_delete` (see `restream_pack/2`).
  defp load_packs(socket) do
    rows = fetch_rows(socket)
    pending = Enum.count(rows, &(&1.trust_state == :pending))
    groups = group_by_pack(rows)

    socket
    |> assign(:pack_count, length(groups))
    |> assign(:pending_count, pending)
    # Keep the sidebar badge in step after Trust/Reject on this page.
    |> assign(:pending_packs_count, pending)
    |> stream(:packs, groups, reset: true)
  end

  defp fetch_rows(socket) do
    case Catalog.list_pack_versions(socket.assigns.current_subject,
           order_by: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}],
           page: [limit: 500]
         ) do
      {:ok, rows, _meta} -> rows
      {:error, _} -> []
    end
  end

  def handle_event("trust", %{"id" => id}, socket) do
    case Catalog.trust_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Trusted #{pack_version.pack_id} v#{pack_version.version}.")
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to trust packs.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not trust pack — try again.")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Catalog.reject_pack_version(id, socket.assigns.current_subject) do
      {:ok, pack_version} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Rejected drift on #{pack_version.pack_id} v#{pack_version.version}. The runner advertising the new hash will re-broadcast — if it's still set, this will re-surface."
         )
         |> restream_pack(pack_version.pack_id)}

      {:error, :not_pending} ->
        {:noreply, put_flash(socket, :error, "Nothing pending on that pack.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Admin required to reject packs.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reject pack — try again.")}
    end
  end

  # After a Trust/Reject, recompute just the affected pack group and update
  # the stream in place: `stream_delete` if every version of the pack is
  # gone (a never-trusted custom pack's only version was Rejected → its row
  # is deleted), otherwise `stream_insert` the regrouped versions. The
  # `pending_count` (and sidebar badge) are recomputed from the full set.
  defp restream_pack(socket, pack_id) do
    rows = fetch_rows(socket)
    pending = Enum.count(rows, &(&1.trust_state == :pending))
    pack_count = rows |> Enum.map(& &1.pack_id) |> Enum.uniq() |> length()
    versions = rows |> Enum.filter(&(&1.pack_id == pack_id)) |> sort_versions()

    socket =
      socket
      |> assign(:pack_count, pack_count)
      |> assign(:pending_count, pending)
      |> assign(:pending_packs_count, pending)

    if versions == [] do
      stream_delete(socket, :packs, %{id: pack_id})
    else
      stream_insert(socket, :packs, %{id: pack_id, versions: versions})
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:packs}
    >
      <:title>Packs</:title>

      <p class="mt-2 max-w-2xl text-sm text-zinc-400">
        Each <em>(pack, version)</em>
        has a pinned trusted hash. Runners advertising the same
        contents match the pin; a different hash flips the pack into
        <strong class="text-amber-300">pending</strong>
        — dispatch refuses runs against it until
        you Trust (adopt the new contents) or Reject (keep the pinned hash).
      </p>

      <div
        :if={@pending_count > 0}
        class="mt-4 rounded-lg border border-amber-700/60 bg-amber-950/40 p-4 ring-1 ring-amber-700/30"
      >
        <div class="flex items-center gap-2 text-sm text-amber-200">
          <.icon name="hero-shield-exclamation" class="h-4 w-4" />
          <strong>
            {@pending_count} pack version{if @pending_count == 1, do: "", else: "s"} need trust review.
          </strong>
        </div>
        <p class="mt-1 text-xs text-amber-100/70">
          Dispatch against these versions is blocked until an admin reviews the new hash.
        </p>
      </div>

      <.loading_state :if={@loading?} />

      <div
        :if={@pack_count == 0 and not @loading?}
        class="mt-8 rounded-xl border border-dashed border-zinc-800 p-10 text-center"
      >
        <.icon name="hero-cube" class="mx-auto h-8 w-8 text-zinc-700" />
        <p class="mt-3 text-sm text-zinc-400">No packs reported yet.</p>
        <p class="mt-1 text-xs text-zinc-500">
          A pack is the bundle of actions a runner can run. Connect a runner and the packs
          it loads appear here to trust or reject.
        </p>
      </div>

      <ul id="packs" phx-update="stream" class="mt-6 space-y-4">
        <li
          :for={{dom_id, pack} <- @streams.packs}
          id={dom_id}
          class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
        >
          <header class="flex items-center justify-between gap-4 border-b border-zinc-900 px-5 py-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-cube" class="h-4 w-4 text-zinc-500" />
              <h2 class="font-mono text-sm text-zinc-100">{pack.id}</h2>
              <span class="text-xs text-zinc-500">·</span>
              <span class="text-xs text-zinc-500">{version_count_label(pack.versions)}</span>
              <span
                :if={any_pending?(pack.versions)}
                class="ml-2 rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-200 ring-1 ring-amber-500/30"
              >
                Pending
              </span>
            </div>
          </header>

          <ul class="divide-y divide-zinc-900">
            <li :for={v <- pack.versions} class="flex flex-col gap-3 px-5 py-3">
              <div class="flex items-center justify-between gap-4">
                <div class="flex items-center gap-3 min-w-0">
                  <span class="rounded bg-zinc-900 px-1.5 py-0.5 font-mono text-xs text-zinc-200">
                    v{v.version}
                  </span>
                  <span class="truncate font-mono text-[11px] text-zinc-500" title={v.hash}>
                    sha256:{short_hash(v.hash)}
                  </span>
                  <span
                    :if={v.trust_state == :trusted}
                    class="rounded bg-emerald-500/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-emerald-200 ring-1 ring-emerald-500/20"
                  >
                    Trusted
                  </span>
                  <span
                    :if={v.trust_state == :pending}
                    class="rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-200 ring-1 ring-amber-500/30"
                  >
                    Pending
                  </span>
                </div>
                <div class="shrink-0 text-right text-xs text-zinc-500">
                  <div>last seen <.local_time value={v.last_seen_at} class="text-zinc-300" /></div>
                  <div
                    :if={v.first_seen_at && v.first_seen_at != v.last_seen_at}
                    class="text-[10px] text-zinc-600"
                  >
                    first seen <.local_time value={v.first_seen_at} class="inline" />
                  </div>
                </div>
              </div>

              <div
                :if={v.trust_state == :pending}
                class="rounded border border-amber-800/60 bg-amber-950/30 p-3"
              >
                <p :if={is_nil(v.hash)} class="text-xs text-amber-100/90">
                  A runner advertised <code>{pack.id}</code> v{v.version} — a
                  pack we don't ship a baseline for. Dispatch is blocked
                  until you approve its contents.
                </p>
                <p :if={not is_nil(v.hash)} class="text-xs text-amber-100/90">
                  A runner is advertising a different hash. Dispatch is blocked
                  for <code>{pack.id}</code> v{v.version} until you decide.
                </p>
                <dl class="mt-2 grid grid-cols-[max-content,1fr] gap-x-3 gap-y-0.5 text-[11px]">
                  <dt class="font-mono text-zinc-500">trusted:</dt>
                  <dd class="font-mono text-zinc-300 break-all">{v.hash || "— (none yet)"}</dd>
                  <dt class="font-mono text-zinc-500">advertising:</dt>
                  <dd class="font-mono text-amber-300 break-all">{v.pending_hash || "—"}</dd>
                </dl>
                <%!-- Trust/Reject mutate authorization state — owner/admin
                     only. The context gate (manage_catalog) is defense in
                     depth; hide the buttons for viewers/operators too so
                     they aren't offered an action that always denies. The
                     pending banner above stays visible to everyone — it
                     explains WHY dispatch is blocked. --%>
                <div
                  :if={Catalog.subject_can_manage_packs?(@current_subject)}
                  class="mt-3 flex flex-wrap gap-2"
                >
                  <button
                    phx-click="trust"
                    phx-value-id={v.id}
                    data-confirm={
                      if is_nil(v.hash) do
                        "Approve #{pack.id} v#{v.version}? Cloud will allow its actions to run against the advertised contents."
                      else
                        "Adopt the new hash as trusted for #{pack.id} v#{v.version}? Future dispatches will authorize against the advertised contents."
                      end
                    }
                    class="rounded bg-amber-500 px-3 py-1 text-xs font-semibold text-amber-950 hover:bg-amber-400"
                  >
                    {if is_nil(v.hash), do: "Approve pack", else: "Trust new contents"}
                  </button>
                  <button
                    phx-click="reject"
                    phx-value-id={v.id}
                    data-confirm={
                      if is_nil(v.hash) do
                        "Reject this pack? Its actions stay blocked. If the runner keeps advertising it on later heartbeats it will reappear here pending re-decision."
                      else
                        "Keep the trusted hash and discard the pending one?"
                      end
                    }
                    class="rounded border border-zinc-700 bg-zinc-900 px-3 py-1 text-xs text-zinc-200 hover:bg-zinc-800"
                  >
                    Reject
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </li>
      </ul>
    </.dashboard_shell>
    """
  end

  defp group_by_pack(rows) do
    rows
    |> Enum.group_by(& &1.pack_id)
    |> Enum.map(fn {pack_id, vs} -> %{id: pack_id, versions: sort_versions(vs)} end)
    |> Enum.sort_by(& &1.id)
  end

  defp sort_versions(versions),
    do: Enum.sort_by(versions, & &1.last_seen_at, {:desc, DateTime})

  defp any_pending?(versions), do: Enum.any?(versions, &(&1.trust_state == :pending))

  defp version_count_label(versions) do
    n = length(versions)
    "#{n} #{if n == 1, do: "version", else: "versions"}"
  end

  defp short_hash(nil), do: "—"
  defp short_hash(h) when is_binary(h), do: String.slice(h, 0, 12)
end
