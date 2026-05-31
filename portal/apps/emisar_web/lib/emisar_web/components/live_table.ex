defmodule EmisarWeb.LiveTable do
  @moduledoc """
  Sortable / filterable / paginated table component for `live_view`
  pages whose context list functions return
  `{:ok, rows, %Paginator.Metadata{}}`.

  The component is **state-free** — it only renders. The host LiveView
  drives filter/page state through URL params + `handle_params/3`, so
  back-button and refresh keep the user on the same view.

  ## Host-LiveView contract

      def handle_params(params, _uri, socket) do
        opts = LiveTable.params_to_opts(params)
        {:ok, rows, meta} = MyContext.list_things(account_id, opts)

        {:noreply,
         socket
         |> assign(:rows, rows)
         |> assign(:metadata, meta)
         |> assign(:filter_params, params)}
      end

      <.live_table
        id="events"
        path={~p"/app/audit"}
        rows={@rows}
        metadata={@metadata}
        filter_params={@filter_params}
        filters={Emisar.Audit.Event.Query.filters()}
      >
        <:col :let={ev} label="Type"><span class="font-mono">{ev.event_type}</span></:col>
        ...
        <:empty>No events match these filters.</:empty>
      </.live_table>
  """
  use Phoenix.Component
  use EmisarWeb, :verified_routes

  alias Emisar.Repo.Filter

  attr :id, :string, required: true
  attr :path, :any, required: true, doc: "verified route the form/page links navigate to"
  attr :rows, :list, required: true
  attr :metadata, :any, required: true, doc: "%Paginator.Metadata{} from Repo.list/3"
  attr :filter_params, :map, default: %{}, doc: "params currently driving the filter form"
  attr :filters, :list, default: [], doc: "list of %Filter{} from the entity's Query module"
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil
  attr :class, :string, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :empty
  slot :action, doc: "right-side actions for each row"

  def live_table(assigns) do
    ~H"""
    <div class="space-y-4">
      <.filter_form
        :if={@filters != []}
        id={"#{@id}-filter"}
        path={@path}
        filters={@filters}
        params={@filter_params}
      />

      <%= if Enum.empty?(@rows) do %>
        <div id={"#{@id}-empty"} class="rounded-lg border border-zinc-800 bg-zinc-900/30 p-8 text-center text-sm text-zinc-400">
          {render_slot(@empty) || "Nothing to show."}
        </div>
      <% else %>
        <div class="overflow-x-auto rounded-lg border border-zinc-800">
          <table id={@id} class={["w-full text-sm text-left", @class]}>
            <thead class="bg-zinc-900/50 text-xs uppercase tracking-wider text-zinc-400">
              <tr>
                <th :for={col <- @col} class={["px-3 py-2 font-medium", col[:class]]}>
                  {col.label}
                </th>
                <th :if={@action != []} class="px-3 py-2 text-right font-medium">
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody id={"#{@id}-rows"} class="divide-y divide-zinc-800/80 text-zinc-200">
              <tr
                :for={row <- @rows}
                id={@row_id && @row_id.(row)}
                phx-click={@row_click && @row_click.(row)}
                class={["hover:bg-zinc-900/40", @row_click && "cursor-pointer"]}
              >
                <td :for={col <- @col} class={["px-3 py-2 align-middle", col[:class]]}>
                  {render_slot(col, row)}
                </td>
                <td :if={@action != []} class="px-3 py-2 align-middle text-right">
                  {render_slot(@action, row)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.paginator id={@id} path={@path} metadata={@metadata} filter_params={@filter_params} />
      <% end %>
    </div>
    """
  end

  # -- Filter form ----------------------------------------------------

  attr :id, :string, required: true
  attr :path, :any, required: true
  attr :filters, :list, required: true
  attr :params, :map, required: true

  defp filter_form(assigns) do
    ~H"""
    <form
      id={@id}
      method="get"
      action={@path}
      class="flex flex-wrap items-end gap-3 rounded-lg border border-zinc-800 bg-zinc-900/30 p-3"
    >
      <.filter_input :for={filter <- @filters} filter={filter} value={Map.get(@params, to_string(filter.name))} />
      <div class="flex gap-2">
        <button
          type="submit"
          class="rounded-lg bg-indigo-500 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-400"
        >
          Apply
        </button>
        <.link
          :if={has_active_filters?(@params, @filters)}
          href={@path}
          class="rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:bg-zinc-900"
        >
          Clear
        </.link>
      </div>
    </form>
    """
  end

  attr :filter, :any, required: true
  attr :value, :any, default: nil

  defp filter_input(%{filter: %Filter{type: {:list, _}}} = assigns) do
    assigns =
      assigns
      |> assign(:selected, List.wrap(assigns.value))
      |> assign(:groups, normalize_groups(assigns.filter.values || []))

    ~H"""
    <label class="flex flex-col text-xs font-medium text-zinc-400">
      <span class="mb-1">{@filter.title}</span>
      <select
        name={"#{@filter.name}"}
        class="rounded-lg border border-zinc-700 bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200"
      >
        <option value="">All</option>
        <%= for {group_label, options} <- @groups do %>
          <%= if group_label do %>
            <optgroup label={group_label}>
              <option :for={{val, label} <- options} value={val} selected={val in @selected}>
                {label}
              </option>
            </optgroup>
          <% else %>
            <option :for={{val, label} <- options} value={val} selected={val in @selected}>
              {label}
            </option>
          <% end %>
        <% end %>
      </select>
    </label>
    """
  end

  defp filter_input(%{filter: %Filter{type: :boolean}} = assigns) do
    ~H"""
    <label class="flex flex-col text-xs font-medium text-zinc-400">
      <span class="mb-1 invisible">{@filter.title}</span>
      <span class="inline-flex h-[34px] items-center gap-2 rounded-lg border border-zinc-700 bg-zinc-950 px-3 text-xs text-zinc-300">
        <input
          type="checkbox"
          name={@filter.name}
          value="true"
          checked={@value == "true"}
          class="h-4 w-4 rounded border-zinc-700 bg-zinc-950 text-indigo-500 focus:ring-indigo-500"
        />
        {@filter.title}
      </span>
    </label>
    """
  end

  defp filter_input(assigns) do
    ~H"""
    <label class="flex flex-col text-xs font-medium text-zinc-400">
      <span class="mb-1">{@filter.title}</span>
      <input
        type="text"
        name={@filter.name}
        value={@value}
        class="rounded-lg border border-zinc-700 bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200"
      />
    </label>
    """
  end

  # Filter.values may be either a flat list of `{value, label}` OR a
  # list of `{group_label, [{value, label}, …]}` for grouped renders
  # (audit event types are grouped by domain prefix). Normalize to
  # `[{group_label_or_nil, [{value, label}, …]}, …]` so the template
  # can take one path.
  defp normalize_groups(values) do
    case values do
      [{_label, list} | _] when is_list(list) -> values
      flat -> [{nil, flat}]
    end
  end

  defp has_active_filters?(params, filters) do
    filters
    |> Enum.any?(fn f ->
      v = Map.get(params, to_string(f.name))
      v not in [nil, ""]
    end)
  end

  # -- Paginator ------------------------------------------------------

  @doc """
  Standalone cursor pagination control. Use this when a LiveView
  renders its own custom row layout (cards, grouped lists, etc.)
  instead of the flat `<.live_table>` shell — it still gets prev/next
  cursors + total count without re-implementing the link logic.

  Multiple tables on the same page can share URL params without
  collisions by passing `:prefix` (e.g. `prefix: "pending_"` makes the
  cursor key `?pending_after=...`).
  """
  attr :id, :string, required: true
  attr :path, :any, required: true
  attr :metadata, :any, required: true
  attr :filter_params, :map, default: %{}
  attr :prefix, :string, default: ""

  def paginator(assigns) do
    ~H"""
    <nav
      :if={@metadata.previous_page_cursor || @metadata.next_page_cursor || (@metadata.count || 0) > 0}
      id={"#{@id}-pager"}
      class="flex items-center justify-between text-xs text-zinc-400"
    >
      <div>
        <%= if @metadata.count != nil do %>
          {@metadata.count} total
        <% end %>
      </div>
      <div class="flex gap-2">
        <.link
          :if={@metadata.previous_page_cursor}
          patch={page_link(@path, @filter_params, @prefix, before: @metadata.previous_page_cursor)}
          class="rounded-lg border border-zinc-700 px-3 py-1.5 hover:bg-zinc-900"
        >
          ← Prev
        </.link>
        <.link
          :if={@metadata.next_page_cursor}
          patch={page_link(@path, @filter_params, @prefix, after: @metadata.next_page_cursor)}
          class="rounded-lg border border-zinc-700 px-3 py-1.5 hover:bg-zinc-900"
        >
          Next →
        </.link>
      </div>
    </nav>
    """
  end

  defp page_link(path, params, prefix, page_params) do
    # Drop this table's prior cursor (both directions), then layer the
    # new direction in. Other tables' cursors keyed under different
    # prefixes are preserved so multi-table pages don't reset each
    # other on every prev/next click.
    keys_to_drop = ["#{prefix}before", "#{prefix}after"]
    rest = Map.drop(params, keys_to_drop)

    query =
      Map.merge(
        rest,
        Map.new(page_params, fn {k, v} -> {"#{prefix}#{k}", v} end)
      )

    base = path_to_binary(path)
    if query == %{}, do: base, else: base <> "?" <> URI.encode_query(query)
  end

  defp path_to_binary(p) when is_binary(p), do: p
  defp path_to_binary(other), do: to_string(other)

  # -- params → list/3 opts ------------------------------------------

  @doc """
  Translates incoming `params` (from `handle_params/3`) into the
  `[filter: ..., page: ...]` keyword list that `Emisar.Repo.list/3`
  expects. Unknown params are ignored.

  Options:

    * `:prefix` — when multiple tables share a page, prefix each
      table's URL keys with `<prefix>` (matches the `:prefix` passed
      to `<.paginator>` / `<.live_table>`).
  """
  def params_to_opts(params, filters \\ [], opts \\ []) when is_map(params) do
    prefix = Keyword.get(opts, :prefix, "")

    filter_kv =
      for f <- filters,
          v = Map.get(params, "#{prefix}#{f.name}"),
          v not in [nil, ""] do
        {f.name, cast_filter_value(f, v)}
      end

    page_kv =
      cond do
        c = params["#{prefix}after"] -> [cursor: c]
        c = params["#{prefix}before"] -> [cursor: c]
        true -> []
      end

    [filter: filter_kv, page: page_kv]
  end

  defp cast_filter_value(%Filter{type: {:list, _}}, value) when is_binary(value),
    do: [value]

  defp cast_filter_value(%Filter{type: {:list, _}}, values) when is_list(values),
    do: values

  defp cast_filter_value(%Filter{type: :boolean}, "true"), do: true
  defp cast_filter_value(%Filter{type: :boolean}, _), do: false

  defp cast_filter_value(_, value), do: value
end
