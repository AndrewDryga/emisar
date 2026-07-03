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
        path={~p"/app/\#{@current_account}/audit"}
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
  alias EmisarWeb.CoreComponents

  attr :id, :string, required: true
  attr :path, :any, required: true, doc: "verified route the form/page links navigate to"
  attr :rows, :list, required: true
  attr :metadata, :any, required: true, doc: "%Paginator.Metadata{} from Repo.list/3"
  attr :filter_params, :map, default: %{}, doc: "params currently driving the filter form"
  attr :filters, :list, default: [], doc: "list of %Filter{} from the entity's Query module"

  attr :filter_layout, :atom,
    default: :inline,
    values: [:inline, :stacked],
    doc:
      "`:inline` flows the filters in one wrapping row of compact controls (a few filters, no dynamically-added ones — most pages); `:stacked` lays them in a two-column grid where each filter's `span` picks its row/cell (the audit panel, whose Actor/Subject kind pickers pair with a revealed value dropdown)"

  attr :filter_visibility, :atom,
    default: :always,
    values: [:always, :collapsible],
    doc:
      "`:collapsible` renders the filter form only while `filters_open` — for a page whose facet set is large enough to wall off the data (audit). The host LiveView owns the toggle control + the open flag as SERVER state (LiveView strips a native `<details open>` on re-render), typically opening it on mount when the URL already carries an active facet so a shared filtered link never hides its controls."

  attr :filters_open, :boolean,
    default: false,
    doc: "`:collapsible` only — whether the filter form is currently shown"

  attr :prefix, :string,
    default: "",
    doc:
      "URL-param prefix for the embedded paginator. Use when a page hosts multiple paginated lists (e.g. approvals: pending_/grants_/decided_) so each list's prev/next cursors don't collide"

  attr :layout, :atom,
    default: :table,
    values: [:table, :cards],
    doc:
      "`:table` renders `<table>` with `:col` slots (data dense); `:cards` renders `<ul>/<li>` with the `:item` slot (operator-friendly card rows)"

  attr :responsive, :boolean,
    default: false,
    doc:
      "`:table` only. Below `sm`, re-render each row as a label/value card (reusing the same `:col` slots + their labels) instead of letting a dense table overflow and clip. The card shows ALL columns — including the ones the table hides on small screens — since it has the vertical room. Enable on wide tables (runs, audit)."

  attr :card_accent, :any,
    default: nil,
    doc:
      "`:responsive` only. `fn row -> :pass | :pending | :deny | :neutral`. Colors a left spine on each mobile card so problem/pending rows pop in a long scroll; routine rows get a transparent spine (no shift). Without it every card reads the same weight."

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

    attr :card, :boolean,
      doc:
        "set false to skip this column in the responsive mobile card — for a " <>
          "column whose value the card already carries elsewhere (runs' in-cell " <>
          "source badge) or that earns no phone space (audit's IP)"
  end

  slot :item, doc: "`:cards` layout row body — receives `row`. Required when `layout == :cards`."

  slot :group_header,
    doc: "`:cards` + `:group_by` only — receives the group label, renders the divider"

  slot :list_header,
    doc:
      "`:cards` only — rendered ONCE as the list's first row (an `<li>`), before any group header. Column headers for `:item` rows that lay out as a grid (the audit stream's xl+ forensic columns)."

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
        :if={@filters != [] and filters_visible?(@filter_visibility, @filters_open)}
        id={"#{@id}-filter"}
        path={@path}
        filters={@filters}
        params={@filter_params}
        layout={@filter_layout}
        disabled={filters_inert?(@rows, @filter_params, @filters)}
      />

      <%= if Enum.empty?(@rows) do %>
        <div
          id={"#{@id}-empty"}
          class="rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] px-5 py-10 text-center text-sm text-zinc-500"
        >
          {render_slot(@empty) || "Nothing to show."}
        </div>
      <% else %>
        <ul id={@id} class={[@resolved_wrapper_class, @class]}>
          {render_slot(@list_header)}
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

        <%!-- Footer keeps the rows' px-5 inset; no top padding, so the "N total" /
             prev-next sits tight under the list (the wrapper's space-y is the gap). --%>
        <div
          :if={
            @metadata.previous_page_cursor || @metadata.next_page_cursor || (@metadata.count || 0) > 0
          }
          class="px-5 pb-1"
        >
          <.paginator
            id={@id}
            path={@path}
            metadata={@metadata}
            filter_params={@filter_params}
            prefix={@prefix}
            page_count={length(@rows)}
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
        :if={@filters != [] and filters_visible?(@filter_visibility, @filters_open)}
        id={"#{@id}-filter"}
        path={@path}
        filters={@filters}
        params={@filter_params}
        layout={@filter_layout}
        disabled={filters_inert?(@rows, @filter_params, @filters)}
      />

      <%= if Enum.empty?(@rows) do %>
        <div
          id={"#{@id}-empty"}
          class="rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] p-8 text-center text-sm text-zinc-400"
        >
          {render_slot(@empty) || "Nothing to show."}
        </div>
      <% else %>
        <%!-- The dense table sits DIRECTLY on the canvas — terminal-calm, no
             frame. Readability comes from structure, not a box: a quiet
             uppercase header over a stronger rule, then thin-but-VISIBLE row
             separators (white/[0.08] — 0.06 was below the legibility line). --%>
        <div class={[
          "overflow-x-auto",
          @responsive && "hidden sm:block"
        ]}>
          <table id={@id} class={["w-full text-sm text-left", @class]}>
            <thead class="text-xs uppercase tracking-wider text-zinc-500">
              <tr class="border-b border-zinc-700/80">
                <th :for={col <- @col} class={["px-3 py-2.5 font-medium", col[:class]]}>
                  {col.label}
                </th>
                <th :if={@action != []} class="px-3 py-2.5 text-right font-medium">
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody id={"#{@id}-rows"} class="divide-y divide-zinc-800/70 text-zinc-200">
              <tr
                :for={row <- @rows}
                id={@row_id && @row_id.(row)}
                phx-click={@row_click && @row_click.(row)}
                class={["hover:bg-white/[0.04]", @row_click && "cursor-pointer"]}
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

        <%!-- Below sm a dense table overflows and clips (status badges, long
             action ids). Re-render each row as a label/value card reusing the
             same :col slots + labels — so the page authors the table once, and
             the card restores the columns the table hides on small screens. --%>
        <ul
          :if={@responsive}
          id={"#{@id}-cards"}
          class="divide-y divide-zinc-800/70 overflow-hidden rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] sm:hidden"
        >
          <li
            :for={row <- @rows}
            id={@row_id && "#{@row_id.(row)}-card"}
            phx-click={@row_click && @row_click.(row)}
            class={[
              "space-y-2 border-l-2 px-4 py-3.5",
              card_spine_class(@card_accent && @card_accent.(row)),
              @row_click && "cursor-pointer hover:bg-white/[0.04]"
            ]}
          >
            <div
              :for={col <- @col}
              :if={col[:card] != false}
              class="flex items-baseline gap-3"
            >
              <span
                :if={col[:label] not in [nil, ""]}
                class="w-24 shrink-0 text-[10px] font-semibold uppercase tracking-wider text-zinc-400"
              >
                {col.label}
              </span>
              <div class="min-w-0 flex-1 text-sm text-zinc-200">{render_slot(col, row)}</div>
            </div>
            <div :if={@action != []} class="flex justify-end gap-2 pt-1">
              {render_slot(@action, row)}
            </div>
          </li>
        </ul>

        <.paginator
          id={@id}
          path={@path}
          metadata={@metadata}
          filter_params={@filter_params}
          prefix={@prefix}
          page_count={length(@rows)}
        />
      <% end %>
    </div>
    """
  end

  # Left status spine on a responsive card. Every card carries `border-l-2` so
  # the inset is uniform (no content shift between rows); only the COLOR varies —
  # rose/amber make problem + pending rows pop in a scroll, pass is a quiet
  # healthy edge, and routine/neutral stays transparent so it recedes.
  defp card_spine_class(:deny), do: "border-l-rose-500"
  defp card_spine_class(:pending), do: "border-l-amber-500"
  defp card_spine_class(:pass), do: "border-l-brand-500/40"
  defp card_spine_class(_), do: "border-l-transparent"

  defp default_cards_wrapper_class(:visible) do
    "divide-y divide-zinc-800/70 rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07]"
  end

  defp default_cards_wrapper_class(_) do
    "divide-y divide-zinc-800/70 overflow-hidden rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07]"
  end

  # `:always` pages render the form unconditionally; a `:collapsible` page
  # renders it only while its host says so — the data leads, the facets wait.
  defp filters_visible?(:always, _open?), do: true
  defp filters_visible?(:collapsible, open?), do: open?

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
  attr :layout, :atom, default: :inline
  attr :disabled, :boolean, default: false

  defp filter_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="filter"
      phx-submit="filter"
      class={["space-y-3", @disabled && "opacity-50"]}
      aria-disabled={@disabled}
    >
      <%!-- `:inline` — a few compact controls flow in one wrapping row. `:stacked`
           — a two-column grid where each filter's `span` picks its row/cell, so a
           kind picker can pair with a revealed value dropdown beside it. Every
           filter is always visible either way (no "more filters" disclosure). --%>
      <div class={filter_container_class(@layout)}>
        <div :for={filter <- @filters} class={filter_item_class(@layout, filter)}>
          <.filter_input
            filter={filter}
            value={filter_value(@params, to_string(filter.name), filter)}
            disabled={@disabled}
          />
        </div>
      </div>
      <.link
        :if={has_active_filters?(@params, @filters)}
        patch={@path}
        class="inline-flex items-center gap-1 text-xs font-medium text-zinc-400 hover:text-zinc-200"
      >
        <span aria-hidden="true" class="text-base leading-none">&times;</span> Clear filters
      </.link>
    </form>
    """
  end

  # One column on a phone (the paired kind/value pickers stack, and the datetime
  # inputs get their full width) → two columns from `sm` up, where `span` pairs
  # them. `col-span-2`/`col-start-1` are no-ops in the single-column grid.
  defp filter_container_class(:stacked),
    do: "grid max-w-xl grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2"

  defp filter_container_class(:inline), do: "flex flex-wrap items-end gap-3"

  # Inline gives every filter the same compact width so a handful of controls sit
  # in one tidy row; stacked defers to the filter's `span` for its grid cell.
  defp filter_item_class(:inline, _filter), do: "w-full sm:w-48"
  defp filter_item_class(:stacked, filter), do: filter_span_class(filter)

  attr :filter, :any, required: true
  attr :value, :any, default: nil
  attr :disabled, :boolean, default: false

  # Searchable combobox for a large {:list, _} filter (`%Filter{search: true}` —
  # the audit Type picker's ~90 grouped options). Server renders the full option
  # list once; the Combobox hook does client-side open/close + type-to-filter +
  # selection (writing the hidden input and firing the form's phx-change).
  # `phx-update="ignore"` + a VALUE-KEYED id make the state model work: unrelated
  # live re-renders (a busy audit stream) leave an open panel + typed query
  # untouched, while an actual value change (selection, Clear filters) renders a
  # fresh node under a new id — server-rendered label, active tint, closed panel.
  defp filter_input(%{filter: %Filter{search: true}} = assigns) do
    assigns =
      assigns
      |> assign(:selected, assigns.value |> List.wrap() |> List.first())
      |> assign(:groups, normalize_groups(assigns.filter.values || []))
      |> assign(:active?, filter_active?(assigns.filter, assigns.value))

    ~H"""
    <div
      id={"filter-#{@filter.name}-#{@selected || "all"}"}
      phx-hook="Combobox"
      phx-update="ignore"
      class="relative"
    >
      <label class={filter_label_class(@active?)}>
        <span class="mb-1">{@filter.title}</span>
        <input type="hidden" name={@filter.name} value={@selected} data-combobox-value />
        <button
          type="button"
          data-combobox-trigger
          disabled={@disabled}
          class={[
            "flex w-full items-center justify-between gap-2 rounded-lg border bg-zinc-950 py-1.5 pl-2.5 pr-2 text-left text-xs disabled:cursor-not-allowed",
            if(@selected, do: "text-zinc-200", else: "text-zinc-400"),
            filter_control_class(@active?)
          ]}
        >
          <span class="truncate">{combobox_selected_label(@groups, @selected)}</span>
          <CoreComponents.icon name="hero-chevron-down" class="h-3 w-3 shrink-0 text-zinc-500" />
        </button>
      </label>
      <div
        data-combobox-panel
        hidden
        class="absolute z-20 mt-1 w-full min-w-[18rem] overflow-hidden rounded-lg bg-zinc-900 shadow-xl shadow-black/60 ring-1 ring-white/10"
      >
        <input
          type="text"
          data-combobox-search
          placeholder="Search…"
          autocomplete="off"
          class="w-full border-0 border-b border-zinc-800 bg-zinc-950 px-3 py-2 text-xs text-zinc-200 placeholder:text-zinc-600 focus:border-zinc-800 focus:ring-0"
        />
        <ul class="max-h-72 overflow-y-auto py-1 text-xs">
          <li>
            <button
              type="button"
              data-combobox-option
              data-value=""
              data-search="all"
              class={combobox_option_class()}
            >
              All
            </button>
          </li>
          <%= for {group_label, [{group_value, group_option_label} | options]} <- @groups do %>
            <li>
              <button
                type="button"
                data-combobox-option
                data-value={group_value}
                data-search={String.downcase("#{group_label} #{group_option_label}")}
                class={[combobox_option_class(), "font-medium text-zinc-200"]}
              >
                {group_option_label}
              </button>
            </li>
            <li :for={{value, label} <- options}>
              <button
                type="button"
                data-combobox-option
                data-value={value}
                data-search={String.downcase("#{group_label} #{label} #{value}")}
                class={[combobox_option_class(), "pl-6 text-zinc-300"]}
              >
                {label}
              </button>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  defp filter_input(%{filter: %Filter{type: {:list, _}}} = assigns) do
    assigns =
      assigns
      |> assign(:selected, List.wrap(assigns.value))
      |> assign(:groups, normalize_groups(assigns.filter.values || []))
      |> assign(:active?, filter_active?(assigns.filter, assigns.value))

    ~H"""
    <label class={filter_label_class(@active?)}>
      <span class="mb-1">{@filter.title}</span>
      <select
        name={"#{@filter.name}"}
        disabled={@disabled}
        class={[
          "w-full rounded-lg border bg-zinc-950 py-1.5 pl-2.5 pr-8 text-xs text-zinc-200 disabled:cursor-not-allowed",
          filter_control_class(@active?)
        ]}
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
    assigns = assign(assigns, :active?, filter_active?(assigns.filter, assigns.value))

    ~H"""
    <label class="flex w-full flex-col text-xs font-medium text-zinc-400">
      <span class="mb-1 invisible">{@filter.title}</span>
      <span class={[
        "flex h-[34px] w-full items-center gap-2 rounded-lg border bg-zinc-950 px-3 text-xs",
        filter_control_class(@active?),
        if(@active?, do: "text-brand-300", else: "text-zinc-300")
      ]}>
        <input
          type="checkbox"
          name={@filter.name}
          value="true"
          checked={@value == "true"}
          disabled={@disabled}
          class="h-4 w-4 rounded border-zinc-700 bg-zinc-950 text-brand-500 focus:ring-brand-500 disabled:cursor-not-allowed"
        />
        {@filter.title}
      </span>
    </label>
    """
  end

  defp filter_input(%{filter: %Filter{type: :datetime}} = assigns) do
    assigns = assign(assigns, :active?, filter_active?(assigns.filter, assigns.value))

    ~H"""
    <label class={filter_label_class(@active?)}>
      <span class="mb-1">{@filter.title}</span>
      <%!-- Apply on blur, not per spinner tick: a datetime-local emits an
           event for every field edit, and a half-typed value parses to nil
           (no bound) — debouncing to blur waits for the committed value. --%>
      <input
        type="datetime-local"
        name={@filter.name}
        value={@value}
        phx-debounce="blur"
        disabled={@disabled}
        class={[
          "w-full rounded-lg border bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200 [color-scheme:dark] disabled:cursor-not-allowed",
          filter_control_class(@active?)
        ]}
      />
    </label>
    """
  end

  defp filter_input(assigns) do
    assigns = assign(assigns, :active?, filter_active?(assigns.filter, assigns.value))

    ~H"""
    <label class={filter_label_class(@active?)}>
      <span class="mb-1">{@filter.title}</span>
      <input
        type="text"
        name={@filter.name}
        value={@value}
        phx-debounce="300"
        disabled={@disabled}
        class={[
          "w-full rounded-lg border bg-zinc-950 px-2 py-1.5 text-xs text-zinc-200 disabled:cursor-not-allowed",
          filter_control_class(@active?)
        ]}
      />
    </label>
    """
  end

  defp combobox_option_class do
    "block w-full truncate px-3 py-1.5 text-left transition hover:bg-white/[0.06] data-[hidden]:hidden"
  end

  # The trigger's face: the selected value's label (searching group headers and
  # their children), or "All" when nothing is picked.
  defp combobox_selected_label(_groups, nil), do: "All"

  defp combobox_selected_label(groups, selected) do
    groups
    |> Enum.flat_map(fn {_group, options} -> options end)
    |> List.keyfind(selected, 0)
    |> case do
      {_value, label} -> label
      nil -> selected
    end
  end

  # Filter.values may be either a flat list of `{value, label}` OR a
  # list of `{group_label, [{value, label}, …]}` for grouped renders
  # (audit event types are grouped by domain prefix). Normalize to
  # `[{group_label_or_nil, [{value, label}, …]}, …]` so the template
  # can take one path.
  defp normalize_groups([{_label, list} | _] = values) when is_list(list), do: values
  defp normalize_groups(flat), do: [{nil, flat}]

  # A filter is "active" when its value differs from the default (blank / "All"
  # / unchecked). Drives the brand highlight below so an operator sees at a
  # glance which filters are narrowing the list.
  # A filter reads as "active" only when the operator moved it AWAY from its
  # default — a value that equals the filter's `default` (e.g. status="live" on
  # the agents list) is the baseline view, not an applied filter, so it stays
  # un-highlighted and doesn't raise the "clear filters" ×.
  defp filter_active?(%Filter{type: :boolean, default: default}, value),
    do: value == "true" and value != default

  # Active = the value DIFFERS from the filter's default. Blanks (nil / "" / [])
  # all read as "no value", so a filter with no default is inactive when blank —
  # but a filter whose default is non-blank (status="live") is ACTIVE when moved
  # to a blank value ("All"), because that's still a deviation from its baseline.
  defp filter_active?(%Filter{default: default}, value),
    do: blank_or_nil(value) != blank_or_nil(default)

  defp blank_or_nil(value) when value in [nil, "", []], do: nil
  defp blank_or_nil(value), do: value

  # The value a filter is operating at: its URL param when present (even a blank
  # "All"), otherwise the filter's configured `default`. Absent → default; an
  # explicit blank overrides the default. `default` is nil for most filters, so
  # this is just `Map.get` for them.
  defp filter_value(params, key, %Filter{default: default}) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  # An active filter's label and control switch from muted zinc to the brand
  # accent (a tinted border + faint ring) so enabled filters stand out.
  defp filter_label_class(true), do: "flex w-full flex-col text-xs font-medium text-brand-300"
  defp filter_label_class(false), do: "flex w-full flex-col text-xs font-medium text-zinc-400"

  # Stacked-grid placement: `:full` spans both columns (its own row); `:row_start`
  # is forced to column 1 so it begins a new row (its paired value picker then
  # fills the cell beside it); `:half` (default) just flows into the next cell.
  defp filter_span_class(%Filter{span: :full}), do: "col-span-2"
  defp filter_span_class(%Filter{span: :row_start}), do: "col-start-1"
  defp filter_span_class(_), do: nil

  defp filter_control_class(true), do: "border-brand-500/60 ring-1 ring-brand-500/25"
  defp filter_control_class(false), do: "border-zinc-700"

  @doc """
  True if any of `filters` has a non-blank value in `params`. A page uses this
  to tell "no rows because the account is empty" (show a create-CTA empty state)
  from "no rows because a filter excluded them all" (keep the filter bar so the
  operator can clear it, rather than trapping them on a dead empty state).
  """
  def has_active_filters?(params, filters) do
    filters
    |> Enum.any?(fn f ->
      v = filter_value(params, to_string(f.name), f)
      blank_or_nil(v) != blank_or_nil(f.default)
    end)
  end

  @doc """
  How many of `filters` are active (non-default) in `params`. A `:collapsible`
  page's toggle control renders this so a closed panel still communicates that
  facets are narrowing the list ("Filters · 2") — nothing is ever silently
  hidden.
  """
  def count_active_filters(params, filters) do
    Enum.count(filters, fn f ->
      v = filter_value(params, to_string(f.name), f)
      blank_or_nil(v) != blank_or_nil(f.default)
    end)
  end

  # Filters are inert (rendered disabled) only when there's genuinely nothing to
  # filter — no rows AND no active filter. An empty result that IS filtered keeps
  # its controls live so the operator can clear back to the full set.
  defp filters_inert?(rows, params, filters),
    do: Enum.empty?(rows) and not has_active_filters?(params, filters)

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

  attr :page_count, :integer,
    default: nil,
    doc: "rows on THIS page — renders the count as \"50 / 608 total\""

  def paginator(assigns) do
    ~H"""
    <nav
      :if={@metadata.previous_page_cursor || @metadata.next_page_cursor || (@metadata.count || 0) > 0}
      id={"#{@id}-pager"}
      class="grid grid-cols-3 items-center text-xs text-zinc-400"
    >
      <div>
        <%= if @metadata.count != nil do %>
          <span class="tabular-nums">
            <span :if={@page_count}>{@page_count} / </span>{@metadata.count}
          </span>
          total
        <% end %>
      </div>
      <%!-- Prev/Next hold the CENTER of the page column — not the far right
           corner, a long reach from the list they page. --%>
      <div class="flex justify-center gap-2">
        <.link
          :if={@metadata.previous_page_cursor}
          patch={page_link(@path, @filter_params, @prefix, before: @metadata.previous_page_cursor)}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 hover:bg-white/[0.04]"
        >
          ← Prev
        </.link>
        <.link
          :if={@metadata.next_page_cursor}
          patch={page_link(@path, @filter_params, @prefix, after: @metadata.next_page_cursor)}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 hover:bg-white/[0.04]"
        >
          Next →
        </.link>
      </div>
      <div />
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
          v = filter_value(params, "#{prefix}#{f.name}", f),
          v not in [nil, ""] do
        {f.name, cast_filter_value(f, v)}
      end
      # Drop casts that came back nil (an unparseable datetime) so they don't
      # reach Repo.Filter as `{name, nil}` and error the list. A `false`
      # boolean cast is kept — the cast runs in the block, not as a generator,
      # so its falsy value never filters the row out.
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)

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
        {:noreply, LiveTable.apply_filter(socket, ~p"/app/\#{@current_account}/things", params)}
      end

  Empty values are dropped (so clearing a filter leaves the URL), the
  phx-change `_target` marker is stripped, and `handle_params/3` re-loads
  from the patched params as usual. Filtering on change resets to page 1
  by design — the cursor params aren't carried over.

  A page whose filters declare a `%Filter{default:}` must pass them as the
  fourth argument: a defaulted filter's explicit blank ("All") then STAYS in
  the URL, where `filter_value/3` reads it as an override — dropping it would
  resolve back to the default on the next load, snapping the control away
  from the operator's choice.
  """
  def apply_filter(socket, path, params, filters \\ []) when is_map(params) do
    defaulted =
      for %Filter{default: default, name: name} <- filters,
          not is_nil(default),
          do: to_string(name)

    # Plug.Conn.Query.encode (NOT URI.encode_query) so a list-valued filter —
    # `outcome: ["danger", "warn"]` from the "Problems only" toggle, a multi-select
    # picker — encodes as `outcome[]=danger&outcome[]=warn` and round-trips back to
    # a list. URI.encode_query flattens a list to one mangled value ("dangerwarn"),
    # which then crashes `"danger" in "dangerwarn"` on the next render.
    query =
      params
      |> Map.drop(["_target"])
      |> Enum.reject(fn {k, v} -> v in [nil, ""] and k not in defaulted end)
      |> Plug.Conn.Query.encode()

    to = if query == "", do: path, else: "#{path}?#{query}"
    Phoenix.LiveView.push_patch(socket, to: to)
  end

  defp cast_filter_value(%Filter{type: {:list, _}}, value) when is_binary(value),
    do: [value]

  defp cast_filter_value(%Filter{type: {:list, _}}, values) when is_list(values),
    do: values

  defp cast_filter_value(%Filter{type: :boolean}, "true"), do: true
  defp cast_filter_value(%Filter{type: :boolean}, _), do: false

  defp cast_filter_value(%Filter{type: :datetime}, value) when is_binary(value),
    do: parse_datetime_local(value)

  defp cast_filter_value(_, value), do: value

  # datetime-local input ("YYYY-MM-DDTHH:MM") → UTC DateTime. The wallclock
  # value is read as UTC (audit columns render in UTC). An unparseable value
  # casts to nil, which params_to_opts drops — the bound just doesn't apply,
  # rather than erroring the whole list on a half-typed date.
  defp parse_datetime_local(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end
end
