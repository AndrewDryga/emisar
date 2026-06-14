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

  attr :prefix, :string,
    default: "",
    doc:
      "URL-param prefix for the embedded paginator. Use when a page hosts multiple paginated lists (e.g. approvals: pending_/grants_/decided_) so each list's prev/next cursors don't collide"

  attr :layout, :atom,
    default: :table,
    values: [:table, :cards],
    doc:
      "`:table` renders `<table>` with `:col` slots (data dense); `:cards` renders `<ul>/<li>` with the `:item` slot (operator-friendly card rows)"

  attr :overflow, :atom,
    default: :hidden,
    values: [:hidden, :visible],
    doc:
      "`:cards` only. Set `:visible` when the rendered rows include floating popovers / dropdowns that need to escape the rounded card boundary (TeamLive's per-row <details> popover)"

  attr :wrapper_class, :string,
    default: nil,
    doc:
      "`:cards` only. Replaces the default `<ul>` class entirely. Use for visually distinct lists that share the LiveTable shell but break the divide-y card pattern (ApprovalsLive pending — gapped attention cards)"

  attr :group_by, :any,
    default: nil,
    doc:
      "`:cards` only. `fn row -> group_label end`. When set, rows are scanned in order and a group-header `<li>` is inserted before the first row of each new label. The `:group_header` slot renders the divider; falls back to a plain text header"

  attr :row_id, :any, default: nil, doc: "fn row -> dom id end"

  attr :row_click, :any,
    default: nil,
    doc: "fn row -> JS command end — applied to <tr> in :table mode, <li> in :cards mode"

  attr :class, :string, default: nil

  slot :col, doc: "`:table` layout column. Required when `layout == :table`." do
    attr :label, :string
    attr :class, :string
  end

  slot :item, doc: "`:cards` layout row body — receives `row`. Required when `layout == :cards`."

  slot :group_header,
    doc: "`:cards` + `:group_by` only — receives the group label, renders the divider"

  slot :empty

  slot :action,
    doc:
      "right-side actions for each row (`:table` only — for `:cards`, render them inside `:item`)"

  def live_table(%{layout: :cards} = assigns) do
    assigns =
      assigns
      |> assign(:grouped_rows, group_rows(assigns.rows, assigns.group_by))
      |> assign_new(:resolved_wrapper_class, fn ->
        assigns.wrapper_class || default_cards_wrapper_class(assigns.overflow)
      end)

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
        <div
          id={"#{@id}-empty"}
          class="rounded-xl border border-zinc-900 bg-zinc-950/40 px-5 py-10 text-center text-sm text-zinc-500"
        >
          {render_slot(@empty) || "Nothing to show."}
        </div>
      <% else %>
        <ul id={@id} class={[@resolved_wrapper_class, @class]}>
          <%= for {group_label, rows} <- @grouped_rows do %>
            <%= if group_label != nil do %>
              <%= if @group_header != [] do %>
                {render_slot(@group_header, group_label)}
              <% else %>
                <li class="bg-zinc-950/60 px-5 py-2 text-xs font-semibold uppercase tracking-wider text-zinc-400">
                  {group_label}
                </li>
              <% end %>
            <% end %>
            <%= for row <- rows do %>
              {render_slot(@item, row)}
            <% end %>
          <% end %>
        </ul>

        <%!-- Padded footer so the paginator chrome gets the same px-5
             inset as the rows above instead of hugging the panel edge,
             with a top-border seam separating it from the card list. --%>
        <div
          :if={
            @metadata.previous_page_cursor || @metadata.next_page_cursor || (@metadata.count || 0) > 0
          }
          class="border-t border-zinc-900 px-5 py-3"
        >
          <.paginator
            id={@id}
            path={@path}
            metadata={@metadata}
            filter_params={@filter_params}
            prefix={@prefix}
          />
        </div>
      <% end %>
    </div>
    """
  end

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
        <div
          id={"#{@id}-empty"}
          class="rounded-lg border border-zinc-800 bg-zinc-900/30 p-8 text-center text-sm text-zinc-400"
        >
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

        <.paginator
          id={@id}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix={@prefix}
        />
      <% end %>
    </div>
    """
  end

  defp default_cards_wrapper_class(:visible),
    do: "divide-y divide-zinc-900 rounded-xl border border-zinc-900 bg-zinc-950/40"

  defp default_cards_wrapper_class(_),
    do:
      "divide-y divide-zinc-900 overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40"

  # When `:group_by` is set, walk the rows preserving order and bucket
  # them by label — returns `[{label, [row, …]}, …]`. Without group_by
  # the whole list comes back as a single nil-label bucket so the
  # render path doesn't need to special-case "no grouping".
  defp group_rows(rows, nil), do: [{nil, rows}]

  defp group_rows(rows, group_by) when is_function(group_by, 1) do
    rows
    |> Enum.chunk_by(group_by)
    |> Enum.map(fn chunk -> {group_by.(hd(chunk)), chunk} end)
  end

  # -- Filter form ----------------------------------------------------

  attr :id, :string, required: true
  attr :path, :any, required: true
  attr :filters, :list, required: true
  attr :params, :map, required: true

  defp filter_form(assigns) do
    ~H"""
    <form id={@id} phx-change="filter" phx-submit="filter" class="flex flex-wrap items-end gap-3">
      <.filter_input
        :for={filter <- @filters}
        filter={filter}
        value={Map.get(@params, to_string(filter.name))}
      />
      <.link
        :if={has_active_filters?(@params, @filters)}
        patch={@path}
        title="Clear filters"
        aria-label="Clear filters"
        class="inline-flex h-[34px] w-[34px] items-center justify-center rounded-lg text-lg leading-none text-zinc-500 hover:bg-zinc-900 hover:text-zinc-300"
      >
        &times;
      </.link>
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
        class="rounded-lg border border-zinc-700 bg-zinc-950 py-1.5 pl-2.5 pr-8 text-xs text-zinc-200"
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
        phx-debounce="300"
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
  defp normalize_groups([{_label, list} | _] = values) when is_list(list), do: values
  defp normalize_groups(flat), do: [{nil, flat}]

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

  @doc """
  Patch to the filtered URL from a `phx-change` on the filter form.

  The component is state-free, so the host LiveView owns the patch and its
  route. Wire it with a one-liner:

      def handle_event("filter", params, socket) do
        {:noreply, LiveTable.apply_filter(socket, ~p"/app/things", params)}
      end

  Empty values are dropped (so clearing a filter leaves the URL), the
  phx-change `_target` marker is stripped, and `handle_params/3` re-loads
  from the patched params as usual. Filtering on change resets to page 1
  by design — the cursor params aren't carried over.
  """
  def apply_filter(socket, path, params) when is_map(params) do
    query =
      params
      |> Map.drop(["_target"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    to = if query == "", do: path, else: "#{path}?#{query}"
    Phoenix.LiveView.push_patch(socket, to: to)
  end

  defp cast_filter_value(%Filter{type: {:list, _}}, value) when is_binary(value),
    do: [value]

  defp cast_filter_value(%Filter{type: {:list, _}}, values) when is_list(values),
    do: values

  defp cast_filter_value(%Filter{type: :boolean}, "true"), do: true
  defp cast_filter_value(%Filter{type: :boolean}, _), do: false

  defp cast_filter_value(_, value), do: value
end
