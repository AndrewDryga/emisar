defmodule EmisarWeb.PacksLive do
  @moduledoc """
  Pack inventory across the account's runners. Each runner advertises
  the pack versions it currently has loaded; the cloud upserts a row
  per `(pack_id, version, hash)` and re-uses it across runners. This
  page groups the rows by `pack_id` so an operator can see at a glance:

    * which packs are deployed
    * which versions are out there
    * **drift** — same `(pack_id, version)` but distinct hashes means
      somebody hand-edited a pack on a host instead of rebuilding it.
  """
  use EmisarWeb, :live_view

  alias Emisar.Catalog

  def mount(_params, _session, socket) do
    case Catalog.list_pack_versions(socket.assigns.current_subject,
           order_by: [{:packs, :asc, :pack_id}, {:packs, :asc, :version}],
           page: [limit: 500]
         ) do
      {:ok, rows, _meta} ->
        {:ok,
         socket
         |> assign(:page_title, "Packs")
         |> assign(:rows, rows)
         |> assign(:packs, group_by_pack(rows))}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Packs")
         |> assign(:rows, [])
         |> assign(:packs, [])}
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:packs}
    >
      <:title>Packs</:title>

      <p class="mt-2 max-w-2xl text-sm text-zinc-400">
        Packs your runners are currently advertising. Each runner reports its loaded
        catalog on connect — the cloud dedupes by content hash, so two runners on the
        same pack version share a single row. A pack version with multiple hashes is
        <strong class="text-amber-300">drift</strong>: somebody edited a pack on a host
        without rebuilding it; re-deploy from the canonical source to clear it.
      </p>

      <div :if={@packs == []} class="mt-8 rounded-xl border border-dashed border-zinc-800 p-10 text-center">
        <.icon name="hero-cube" class="mx-auto h-8 w-8 text-zinc-700" />
        <p class="mt-3 text-sm text-zinc-400">No packs reported yet.</p>
        <p class="mt-1 text-xs text-zinc-500">
          Runners advertise their loaded packs on each (re)connect. Once one connects
          here, you'll see what it's running.
        </p>
      </div>

      <ul class="mt-6 space-y-4">
        <li
          :for={{pack_id, versions} <- @packs}
          class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"
        >
          <header class="flex items-center justify-between gap-4 border-b border-zinc-900 px-5 py-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-cube" class="h-4 w-4 text-zinc-500" />
              <h2 class="font-mono text-sm text-zinc-100">{pack_id}</h2>
              <span class="text-xs text-zinc-500">·</span>
              <span class="text-xs text-zinc-500">{length(versions)} {if length(versions) == 1, do: "version", else: "versions"}</span>
              <span :if={drift?(versions)} class="ml-2 rounded bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-200 ring-1 ring-amber-500/30">
                Drift
              </span>
            </div>
          </header>

          <ul class="divide-y divide-zinc-900">
            <li :for={v <- versions} class="flex items-center justify-between gap-4 px-5 py-3">
              <div class="flex items-center gap-3 min-w-0">
                <span class="rounded bg-zinc-900 px-1.5 py-0.5 font-mono text-xs text-zinc-200">
                  v{v.version}
                </span>
                <span class="truncate font-mono text-[11px] text-zinc-500" title={v.hash}>
                  sha256:{short_hash(v.hash)}
                </span>
              </div>
              <div class="shrink-0 text-right text-xs text-zinc-500">
                <div>last seen <.local_time value={v.last_seen_at} class="text-zinc-300" /></div>
                <div :if={v.first_seen_at && v.first_seen_at != v.last_seen_at} class="text-[10px] text-zinc-600">
                  first seen <.local_time value={v.first_seen_at} class="inline" />
                </div>
              </div>
            </li>
          </ul>
        </li>
      </ul>
    </.dashboard_shell>
    """
  end

  # Group rows by pack_id, then sort versions newest-last-seen first
  # so an operator scanning the page sees the active row at the top of
  # each pack block.
  defp group_by_pack(rows) do
    rows
    |> Enum.group_by(& &1.pack_id)
    |> Enum.map(fn {pack_id, vs} ->
      sorted = Enum.sort_by(vs, & &1.last_seen_at, {:desc, DateTime})
      {pack_id, sorted}
    end)
    |> Enum.sort_by(fn {pack_id, _} -> pack_id end)
  end

  # Drift = same `pack_id` but more than one distinct `version` *or*
  # same `version` advertised with different hashes. Either is a signal
  # that the deployed bits aren't a single canonical build.
  defp drift?(versions) do
    by_version = Enum.group_by(versions, & &1.version)

    Enum.any?(by_version, fn {_v, rows} ->
      length(Enum.uniq_by(rows, & &1.hash)) > 1
    end)
  end

  defp short_hash(nil), do: "—"
  defp short_hash(h) when is_binary(h), do: String.slice(h, 0, 12)
end
