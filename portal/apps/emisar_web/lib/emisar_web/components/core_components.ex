defmodule EmisarWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as modals, tables, and
  forms. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [heroicons](https://heroicons.com). See `icon/1` for usage.
  """
  use Phoenix.Component
  use Gettext, backend: EmisarWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  alias Emisar.Accounts
  alias EmisarWeb.MailTo
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error, :neutral], doc: "used for styling and flash lookup"

  attr :auto_close, :boolean,
    default: true,
    doc: "auto-dismiss after a delay with a countdown bar; off for connection flashes"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      # Errors get a beat longer to read; either way, hovering pauses the countdown.
      |> assign(:close_ms, if(assigns.kind == :error, do: 7000, else: 5000))

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      data-flash
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_close && "FlashAutoClose"}
      data-close-ms={@auto_close && @close_ms}
      role="alert"
      class={
        [
          # z-[60] sits above the sticky marketing nav + console chrome (z-50) so a
          # flash toast is never painted behind them; below the skip-link (z-[100]).
          "fixed top-4 right-4 z-[60] w-80 sm:w-96 overflow-hidden rounded-xl p-4 pr-10 ring-1 backdrop-blur shadow-lg cursor-pointer",
          @kind == :info && "bg-brand-950/80 text-brand-100 ring-brand-500/40",
          @kind == :error && "bg-rose-950/80 text-rose-100 ring-rose-500/40",
          @kind == :neutral && "bg-zinc-900 text-zinc-200 ring-white/10"
        ]
      }
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-2 text-sm font-semibold">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :neutral} name="hero-wifi-mini" class="h-4 w-4" />
        {@title}
      </p>
      <p class="mt-1 text-sm leading-relaxed">{msg}</p>
      <button
        type="button"
        class="absolute top-2 right-2 p-2 opacity-50 hover:opacity-100"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark-solid" class="h-4 w-4" />
      </button>
      <div
        :if={@auto_close}
        data-flash-bar
        class={[
          "absolute inset-x-0 bottom-0 h-0.5 origin-left",
          @kind == :info && "bg-brand-400/70",
          @kind == :error && "bg-rose-400/70",
          @kind == :neutral && "bg-zinc-500/70"
        ]}
      />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title={gettext("Done")} flash={@flash} />
      <.flash kind={:error} title={gettext("Something went wrong")} flash={@flash} />
      <.flash
        id="client-error"
        kind={:neutral}
        title={gettext("Reconnecting")}
        auto_close={false}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Restoring connection…")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:neutral}
        title={gettext("Reconnecting")}
        auto_close={false}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Restoring connection…")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-5">
        {render_slot(@inner_block, f)}
        <%!-- Grouped, not justify-between: a primary + its quiet cancel stay
             associated (design-console-ux — one create-flow footer). A single
             w-full button still spans naturally. --%>
        <div :for={action <- @actions} class="flex items-center gap-3 pt-2">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a button.

  `variant` is STRUCTURE (design-console-ux §2): `:primary` (filled, the default),
  `:secondary` (bordered), `:ghost` (text-only). **A VISIBLE action verb always
  wears a bordered face** — `:ghost` is for menu rows and inline cancel/dismiss
  affordances only (§7.47). A control that merely NAVIGATES is a `<.link>` in the
  house brand-plus-`cta_arrow` grammar **when it stands alone**; a navigation verb
  sharing a row with bordered action buttons takes the `:secondary` face at the
  peers' size, because a row wears ONE button grammar (§7.47). `tone` is the hue atom that
  carries MEANING at the call site — `:brand` (affirmative/primary action),
  `:neutral`, `:amber` (attention-worthy, e.g. trusting a pack's new
  contents), `:rose` (destructive) — defaulting per variant (primary→brand,
  secondary/ghost→neutral) so the common cases stay terse. A destructive
  action is `variant={:secondary} tone={:rose}`. Sizes: `:lg` (default),
  `:md`, `:sm`. An optional leading `icon` (heroicon name) renders before
  the label. `disabled` is honored by every variant. Pass
  `navigate`/`patch`/`href` and it renders a styled `<.link>` instead of a
  `<button>` — so a primary action that navigates reads identically to one
  that submits.

  ## Examples

      <.button>Send!</.button>
      <.button variant={:secondary} tone={:rose} size={:sm} phx-click="revoke">Revoke</.button>
      <.button icon="hero-check">Approve</.button>
      <.button tone={:amber} phx-click="trust">Trust new contents</.button>
      <.button variant={:ghost} type="button" phx-click="cancel_edit">Cancel</.button>
      <.button navigate={~p"/app/\#{@current_account}/runbooks/new"} icon="hero-plus">New runbook</.button>
  """
  attr :type, :string, default: nil
  attr :variant, :atom, default: :primary, values: [:primary, :secondary, :ghost]

  attr :tone, :atom,
    default: nil,
    values: [nil, :neutral, :brand, :amber, :rose],
    doc: "hue atom; nil resolves to the variant's natural tone"

  attr :size, :atom, default: :lg, values: [:sm, :md, :lg]
  attr :icon, :string, default: nil, doc: ~s(leading heroicon name, e.g. "hero-plus")
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value href navigate patch method download)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns)
      when is_map_key(rest, :href) or is_map_key(rest, :navigate) or is_map_key(rest, :patch) do
    ~H"""
    <.link
      class={[button_base(), button_face(@variant, @tone), button_size(@size), @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="h-4 w-4" />{render_slot(@inner_block)}
    </.link>
    """
  end

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[button_base(), button_face(@variant, @tone), button_size(@size), @class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="h-4 w-4" />{render_slot(@inner_block)}
    </button>
    """
  end

  defp button_base do
    "phx-submit-loading:opacity-75 inline-flex items-center justify-center gap-2 rounded-lg transition " <>
      "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 " <>
      "disabled:opacity-50 disabled:cursor-not-allowed"
  end

  # The variant×tone face matrix — only the combinations in use exist, so a
  # meaningless pair (e.g. filled rose) is a FunctionClauseError, not a
  # silently-invented style. nil tone resolves to the variant's natural one.
  defp button_face(variant, nil), do: button_face(variant, default_button_tone(variant))

  defp button_face(:primary, :brand) do
    "bg-brand-500 font-semibold text-zinc-950 shadow-sm hover:bg-brand-400 active:bg-brand-600 focus-visible:outline-brand-400"
  end

  # Filled amber for attention-worthy actions where brand-green would wrongly
  # read as "safe" — e.g. trusting a pack's new contents.
  defp button_face(:primary, :amber) do
    "bg-amber-500 font-semibold text-amber-950 shadow-sm hover:bg-amber-400 active:bg-amber-600 focus-visible:outline-amber-400"
  end

  defp button_face(:secondary, :neutral) do
    "border border-zinc-800 font-medium text-zinc-200 hover:bg-zinc-900 focus-visible:outline-zinc-600"
  end

  # The destructive button: bordered rose, so delete/revoke/disable read
  # identically everywhere without shouting like a filled fill would.
  defp button_face(:secondary, :rose) do
    "border border-rose-500/40 font-medium text-rose-200 hover:bg-rose-500/10 focus-visible:outline-rose-400"
  end

  # The caution twin — bordered amber for a consequential-but-not-destructive
  # confirm (trusting a pack's new code), where rose would over-read as danger.
  defp button_face(:secondary, :amber) do
    "border border-amber-500/40 font-medium text-amber-200 hover:bg-amber-500/10 focus-visible:outline-amber-400"
  end

  # Ghost: a text-only button tinted by tone, for a form's quiet Cancel, an
  # inline dismiss (clearing a chosen upload), and a disclosure toggle. NOT for
  # an entity's action verb — revoke/suspend/delete/edit wear a bordered face so
  # buttons look like buttons (§7.47); the tone ramp below exists so a
  # `<.menu_item>` row can mirror it inside a dropdown panel.
  defp button_face(:ghost, :neutral),
    do: "font-medium text-zinc-300 hover:bg-zinc-900 focus-visible:outline-zinc-600"

  defp button_face(:ghost, :brand),
    do: "font-medium text-brand-300 hover:bg-brand-500/10 focus-visible:outline-brand-400"

  defp button_face(:ghost, :amber),
    do: "font-medium text-amber-300 hover:bg-amber-500/10 focus-visible:outline-amber-400"

  defp button_face(:ghost, :rose),
    do: "font-medium text-rose-300 hover:bg-rose-500/10 focus-visible:outline-rose-400"

  defp default_button_tone(:primary), do: :brand
  defp default_button_tone(:secondary), do: :neutral
  defp default_button_tone(:ghost), do: :neutral

  defp button_size(:lg), do: "px-4 py-2.5 text-sm"
  defp button_size(:md), do: "px-3 py-1.5 text-sm"
  defp button_size(:sm), do: "px-2.5 py-1 text-xs"

  @doc """
  An icon-only button. `label` is REQUIRED — it becomes both `aria-label` and
  `title`, so an icon-only control is never nameless to a screen reader or a
  mouse user. For a text+icon button use `<.button icon=>`. `tone` covers the
  two treatments in use (neutral, danger-on-hover); pass any positioning via
  `class`. Event bindings (`phx-click`, `phx-value-*`, `data-confirm`) and
  `disabled` ride the global `:rest`.
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :rose]
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      aria-label={@label}
      title={@label}
      class={[
        "inline-flex min-h-10 min-w-10 items-center justify-center rounded-md p-2 text-zinc-500 transition-colors hover:bg-zinc-900 disabled:opacity-30 disabled:hover:bg-transparent",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2",
        icon_button_tone(@tone),
        @class
      ]}
      {@rest}
    >
      <.icon name={@icon} class="h-4 w-4" />
    </button>
    """
  end

  defp icon_button_tone(:neutral), do: "hover:text-zinc-200 focus-visible:outline-zinc-600"
  defp icon_button_tone(:rose), do: "hover:text-rose-300 focus-visible:outline-rose-400"

  @doc """
  A click-to-open dropdown built on native `<details>` — no JS, so it opens on
  click and closes on outside-click / Esc / re-click for free, and works before
  LiveView connects.

  The `:trigger` slot is the `<summary>` content (the button/icon the operator
  clicks); the default slot is the panel. The component owns the a11y plumbing
  every site was hand-repeating — hiding the default `<summary>` disclosure
  triangle (`list-none` + the WebKit/standard marker pseudo-elements) — and the
  panel's `absolute` anchor. `group` on the `<details>` lets trigger/panel markup
  use `group-open:` modifiers (e.g. swapping a chevron when open).

  `align` anchors the panel: `:right` (default) right-aligns it under the trigger
  (a per-row actions menu); `:left` left-aligns it; `:stretch` spans the trigger
  width within small insets (the workspace switcher). Per-site skinning rides
  `summary_class` (the trigger's own pill/row styling) and `panel_class` (width,
  padding, text size, and the z-index / offset / shadow each site needs — these
  are deliberately NOT baked in, so a site that must stack above more chrome
  isn't fighting Tailwind utility precedence). `panel_position={:flow_on_narrow}`
  keeps a form menu in document flow until the `xl` layout has room to float it.

  ## Example

      <.dropdown summary_class="rounded px-2 py-1 ring-1 ring-zinc-800" panel_class="z-10 mt-2 w-56 p-1 text-xs shadow-xl">
        <:trigger>Actions <span class="group-open:hidden">▾</span></:trigger>
        <.menu_item phx-click="edit">Edit</.menu_item>
        <.menu_item tone={:rose} phx-click="remove">Remove</.menu_item>
      </.dropdown>
  """
  attr :align, :atom, default: :right, values: [:left, :right, :stretch]
  attr :panel_position, :atom, default: :floating, values: [:floating, :flow_on_narrow]
  attr :summary_class, :string, default: nil, doc: "trigger (summary) skin — pill/row styling"

  attr :panel_class, :string,
    default: nil,
    doc: "panel skin — width, padding, text size, z-index, offset, shadow"

  attr :class, :string, default: nil, doc: "extra classes on the <details> shell"
  attr :rest, :global

  slot :trigger, required: true, doc: "the <summary> content — the control the operator clicks"
  slot :inner_block, required: true, doc: "the panel content (menu items)"

  def dropdown(assigns) do
    ~H"""
    <details class={["group relative", @class]} phx-click-away={JS.remove_attribute("open")} {@rest}>
      <summary class={[
        "cursor-pointer list-none [&::-webkit-details-marker]:hidden [&::marker]:hidden",
        @summary_class
      ]}>
        {render_slot(@trigger)}
      </summary>
      <div class={[
        "rounded-lg bg-zinc-900 shadow-xl shadow-black/60 ring-1 ring-white/10",
        dropdown_panel_position(@panel_position),
        dropdown_align(@align),
        @panel_class
      ]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  defp dropdown_align(:right), do: "right-0"
  defp dropdown_align(:left), do: "left-0"
  defp dropdown_align(:stretch), do: "left-2 right-2 top-full lg:left-4 lg:right-4"

  defp dropdown_panel_position(:floating), do: "absolute"
  defp dropdown_panel_position(:flow_on_narrow), do: "static xl:absolute"

  @doc """
  A searchable single-value picker for bounded catalogs.

  The caller supplies ordered groups of `%{label: ..., options: [...]}`. Each
  option carries `:value`, `:label`, and `:search`; `:description`, `:disabled`,
  and `:variant` (`:default`, `:heading`, or `:child`) are optional. The selected
  face is supplied separately so a compact trigger can omit supporting catalog
  metadata that remains searchable inside the panel.

  The value-keyed `id` is part of the component contract: the picker uses
  `phx-update="ignore"` so an open search survives unrelated LiveView renders.
  Include every server fact that changes the option set in that id.

  When many pickers on one page share one large option catalog, render that
  catalog ONCE with `searchable_select_pool/1` and point each picker at it via
  `source`: the panel then ships only the per-picker `groups` (usually none),
  and the Combobox hook clones the pool's options in on first open. Include the
  pool id in the picker's `id` — a changed catalog is a changed pool id, which
  is what replaces the stale picker.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :selected_label, :string, required: true
  attr :groups, :list, required: true
  attr :blank_label, :string, default: nil
  attr :source, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :active?, :boolean, default: false
  attr :size, :atom, default: :md, values: [:sm, :md]
  attr :aria_label, :string, required: true
  attr :class, :string, default: nil

  def searchable_select(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Combobox"
      phx-update="ignore"
      data-combobox-source={@source}
      class={["relative", @class]}
    >
      <input type="hidden" name={@name} value={@value} data-combobox-value />
      <button
        type="button"
        data-combobox-trigger
        disabled={@disabled}
        aria-label={@aria_label}
        class={[
          "flex w-full items-center justify-between gap-2 rounded-lg border bg-zinc-950 text-left disabled:cursor-not-allowed disabled:opacity-60",
          searchable_select_size(@size),
          if(@value == "", do: "text-zinc-500", else: "text-zinc-200"),
          if(@active?,
            do: "border-brand-500/60 focus:border-brand-400 focus:ring-brand-400/20",
            else: "border-zinc-700 focus:border-zinc-600 focus:ring-zinc-600/20"
          ),
          "focus:outline-none focus:ring-2"
        ]}
      >
        <span class="truncate">{@selected_label}</span>
        <.icon name="hero-chevron-down" class="h-4 w-4 shrink-0 text-zinc-500" />
      </button>

      <div
        data-combobox-panel
        hidden
        class={[
          "absolute z-30 w-full overflow-hidden rounded-b-lg rounded-t-none border border-t-0",
          "bg-zinc-900 shadow-xl shadow-black/60",
          if(@active?, do: "border-brand-500/60", else: "border-zinc-700")
        ]}
      >
        <input
          type="text"
          data-combobox-search
          placeholder="Search…"
          autocomplete="off"
          class={[
            "w-full border-0 border-b border-zinc-800 bg-zinc-950 px-3 py-2 text-zinc-200 placeholder:text-zinc-600 focus:border-zinc-800 focus:ring-0",
            if(@size == :sm, do: "text-xs", else: "text-sm")
          ]}
        />
        <ul
          data-combobox-options
          class={["max-h-72 overflow-y-auto py-1", if(@size == :sm, do: "text-xs", else: "text-sm")]}
        >
          <li :if={@blank_label}>
            <button
              type="button"
              data-combobox-option
              data-value=""
              data-search={String.downcase(@blank_label)}
              class={searchable_select_option_class(:default)}
            >
              {@blank_label}
            </button>
          </li>
          <.combobox_groups groups={@groups} value={@value} />
        </ul>
        <div
          data-combobox-description
          hidden
          class="border-t border-zinc-800 bg-zinc-950 px-3 py-2 text-[11px] leading-relaxed text-zinc-400"
        >
        </div>
      </div>
    </div>
    """
  end

  @doc """
  One shared option catalog for many `searchable_select/1` pickers.

  Renders the groups inside an inert `<template>`, so the browser neither lays
  out nor initializes anything until a picker whose `source` names this id is
  first opened — the Combobox hook clones the content in and applies the
  picker's own selected state. This is what keeps an editor with N pickers over
  one large catalog at one copy of the catalog instead of N.
  """
  attr :id, :string, required: true
  attr :groups, :list, required: true

  def searchable_select_pool(assigns) do
    ~H"""
    <template id={@id} data-combobox-pool>
      <.combobox_groups groups={@groups} value="" />
    </template>
    """
  end

  attr :groups, :list, required: true
  attr :value, :string, required: true

  defp combobox_groups(assigns) do
    ~H"""
    <li :for={group <- @groups} data-combobox-section>
      <span
        :if={group[:label]}
        class="block px-3 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
      >
        {group.label}
      </span>
      <ul>
        <li :for={option <- group.options}>
          <button
            type="button"
            data-combobox-option
            data-value={option.value}
            data-search={option.search}
            data-description={option[:description]}
            disabled={option[:disabled] || false}
            aria-selected={option.value == @value}
            class={[
              searchable_select_option_class(option[:variant] || :default),
              option.value == @value && "bg-white/[0.06] text-zinc-100",
              option[:disabled] && "cursor-not-allowed opacity-50"
            ]}
          >
            {option.label}
          </button>
        </li>
      </ul>
    </li>
    """
  end

  defp searchable_select_size(:sm), do: "py-1.5 pl-2.5 pr-2 text-xs"
  defp searchable_select_size(:md), do: "min-h-10 px-3 py-2 text-sm"

  defp searchable_select_option_class(:heading) do
    "block w-full truncate px-3 py-1.5 text-left font-medium text-zinc-200 transition hover:bg-white/[0.06] data-[hidden]:hidden"
  end

  defp searchable_select_option_class(:child) do
    "block w-full truncate py-1.5 pl-6 pr-3 text-left text-zinc-300 transition hover:bg-white/[0.06] data-[hidden]:hidden"
  end

  defp searchable_select_option_class(_variant) do
    "block w-full truncate px-3 py-1.5 text-left text-zinc-300 transition hover:bg-white/[0.06] data-[hidden]:hidden"
  end

  @doc """
  A full-width menu row for a `<.dropdown>` panel — a left-aligned button (or
  link) with an optional leading `icon`. `tone` mirrors `<.button variant={:ghost}>`
  exactly (neutral → zinc, `caution` → amber, `danger` → rose, `success` →
  brand-green), so an action reads the same color whether it sits inline or in a menu.

  The action rides the global `:rest` — `phx-click`/`phx-value-*`/`data-confirm`
  for a button, or `navigate`/`patch`/`href` to render a `<.link>` instead — so
  each row keeps its own (still server-authz-gated) behavior. `:if` on the call
  site controls whether the row renders at all.

  ## Example

      <.menu_item phx-click="start_edit" phx-value-membership_id={id}>Edit name</.menu_item>
      <.menu_item tone={:rose} phx-click="remove" data-confirm="Sure?">Remove</.menu_item>
  """
  attr :icon, :string, default: nil, doc: "leading heroicon name"
  attr :tone, :atom, default: :neutral, values: [:neutral, :brand, :amber, :rose]
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled href navigate patch method download)

  slot :inner_block, required: true

  def menu_item(%{rest: rest} = assigns)
      when is_map_key(rest, :href) or is_map_key(rest, :navigate) or is_map_key(rest, :patch) do
    ~H"""
    <.link class={[menu_item_base(), menu_item_tone(@tone), @class]} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-4 w-4 shrink-0" />{render_slot(@inner_block)}
    </.link>
    """
  end

  def menu_item(assigns) do
    ~H"""
    <button type="button" class={[menu_item_base(), menu_item_tone(@tone), @class]} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-4 w-4 shrink-0" />{render_slot(@inner_block)}
    </button>
    """
  end

  defp menu_item_base,
    do: "flex w-full items-center gap-2 rounded px-3 py-2 text-left"

  # Toned rows tint like their ghost-button siblings. Neutral steps to
  # zinc-800: menu rows sit on the dropdown's zinc-900 panel, so the ghost
  # button's zinc-900 hover would paint the panel's own color — no visible
  # hover at all (the packs row menu's "Revoke trust" was the correction).
  defp menu_item_tone(:rose), do: "text-rose-300 hover:bg-rose-500/10"
  defp menu_item_tone(:amber), do: "text-amber-300 hover:bg-amber-500/10"
  defp menu_item_tone(:brand), do: "text-brand-300 hover:bg-brand-500/10"
  defp menu_item_tone(:neutral), do: "text-zinc-300 hover:bg-zinc-800"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :label_variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :value, :any

  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :rose],
    doc: ~s(tints the focus ring rose for a destructive field — e.g. a deny reason)

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :size, :atom,
    default: :default,
    values: [:default, :compact],
    doc: "tightens padding/margin for a dense grid — e.g. the runbook editor's arg rows"

  attr :class, :string,
    default: nil,
    doc: "extra (non-conflicting) classes on the input — e.g. font-mono for a slug/id field"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{id: nil, name: name} = assigns) when is_binary(name) do
    assigns
    |> assign(:id, input_id(name))
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-3 text-sm text-zinc-300">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-brand-500 focus:ring-2 focus:ring-brand-500/40 focus:ring-offset-0"
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id} variant={@label_variant}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[
          "block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
          input_size(@size),
          select_chevron_room(@size),
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          input_ring(@errors, @tone),
          @class
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id} variant={@label_variant}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "scrollbar-control block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
          input_size(@size),
          "min-h-[6rem] ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          input_ring(@errors, @tone),
          @class
        ]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc.
  def input(assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id} variant={@label_variant}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
          input_size(@size),
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          input_ring(@errors, @tone),
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Resting + focus ring for an input/select/textarea. An actual validation
  # error always wins with the rose ring; absent errors, `tone={:rose}` tints
  # only the FOCUS ring rose (a destructive field, e.g. a deny reason) while
  # neutral keeps the brand focus.
  defp input_ring([], :rose), do: "ring-zinc-800 focus:ring-rose-500"
  defp input_ring([], :neutral), do: "ring-zinc-800 focus:ring-brand-500"
  defp input_ring(_errors, _tone), do: "ring-rose-500/50 focus:ring-rose-500"

  # Box metrics for an input/select/textarea. `:compact` tightens the padding
  # and label gap for a dense grid (the runbook editor's arg rows); `:default`
  # is the standard comfortable field every other caller renders.
  #
  # The line box is PINNED (`leading-5`), so a caller's `class="text-xs"` or
  # `font-mono` restyles the text without resizing the box: every control in a
  # row keeps one height, whatever face it wears. Tailwind emits `leading-*`
  # after `text-*`, so the pin wins over the size utility's own line-height.
  defp input_size(:compact), do: "mt-1 px-2 py-1.5 text-sm leading-5"
  defp input_size(_default), do: "mt-2 px-3 py-2.5 text-sm leading-5"

  # A native select paints its chevron as a background image (the Tailwind forms
  # plugin: 1.5em wide, 0.5rem in from the right edge) and our own `px-*`
  # overrides the plugin's `padding-right: 2.5rem` — so the room has to come
  # back here, or the longest option runs under the arrow and clips against the
  # box edge ("Require approval" printed over its own chevron).
  defp select_chevron_room(size) when size in [:compact, :filter], do: "pr-8"
  defp select_chevron_room(_default), do: "pr-9"

  defp input_id(name), do: "input-" <> String.replace(name, ~r/[^a-zA-Z0-9_-]+/, "-")

  @doc """
  Renders a `<select>` whose options carry their own `disabled`/`selected` —
  the cases `Phoenix.HTML.Form.options_for_select/2` (and thus `input/1`'s
  `type="select"`) can't express. Each option is a map
  `%{value:, label:, disabled:, selected:}`. For a plain single-value picker
  bound to a form field, reach for `<.input type="select">` instead; this is
  for per-option control (a disabled "already taken" target, a tier floor) and
  multi-selects with computed per-option selection.

  An entry carrying its own `:options` renders as an `<optgroup>` labelled by its
  `:label` — the grouped catalogs a filter bar offers.

  `size` picks the box: `:default` and `:compact` mirror `input/1`'s form-field
  metrics, `:filter` is the filter-bar control (dark ground, hairline border,
  compact text) that `searchable_select/1`'s trigger also wears — so a bar mixing
  the two pickers reads as one family, with `active?` carrying the brand tint that
  says this filter is narrowing the list. The optional rose ring renders when
  `errors` is non-empty. Labels and values render escaped through HEEx (IL-16) —
  option text includes account data.
  """
  attr :id, :any, default: nil
  attr :name, :any, required: true
  attr :label, :string, default: nil
  attr :label_variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :prompt, :string, default: nil, doc: "a leading empty-value option"
  attr :prompt_selected, :boolean, default: false, doc: "marks the prompt option selected"
  attr :multiple, :boolean, default: false
  attr :errors, :list, default: []
  attr :size, :atom, default: :default, values: [:default, :compact, :filter]
  attr :class, :string, default: nil

  attr :active?, :boolean,
    default: false,
    doc: "`size={:filter}` only — this filter holds a value, so it wears the brand tint"

  attr :options, :list,
    required: true,
    doc:
      "option maps `%{value:, label:, disabled:, selected:}`, " <>
        "or group maps `%{label:, options: [option]}`"

  attr :rest, :global, include: ~w(disabled form)

  def select(assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id} variant={@label_variant}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={
          [
            # The top margin is the label gap — a label-less select (aria-label
            # callers) must sit flush, or it reads vertically misaligned beside
            # sibling controls in the same row.
            @label && select_label_gap(@size),
            select_box_class(@size, @active?, @errors),
            select_chevron_room(@size),
            @class
          ]
        }
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="" selected={@prompt_selected}>{@prompt}</option>
        <%= for entry <- @options do %>
          <optgroup :if={entry[:options]} label={entry.label}>
            <.select_option :for={option <- entry.options} option={option} />
          </optgroup>
          <.select_option :if={is_nil(entry[:options])} option={entry} />
        <% end %>
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  attr :option, :map, required: true

  defp select_option(assigns) do
    ~H"""
    <option value={@option.value} disabled={@option.disabled} selected={@option.selected}>
      {@option.label}
    </option>
    """
  end

  defp select_label_gap(:default), do: "mt-2"
  defp select_label_gap(_tighter), do: "mt-1"

  # The form-field box, mirroring `input/1` so a `<.select>` and an `<.input>` in
  # one row are the same control.
  defp select_box_class(size, _active?, errors) when size in [:default, :compact] do
    [
      "block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
      if(size == :compact, do: "px-2 py-1.5", else: "px-3 py-2.5"),
      "text-sm leading-5 ring-1 ring-inset",
      "focus:ring-2 focus:ring-inset",
      input_ring(errors, :neutral)
    ]
  end

  # The filter-bar box: a darker ground than the page's cards and a hairline
  # border that turns brand while the filter is narrowing the list. A filter at
  # its default value is not an active filter, so it stays muted like the
  # searchable picker's blank face.
  defp select_box_class(:filter, active?, _errors) do
    [
      "w-full rounded-lg border bg-zinc-950 py-1.5 pl-2.5 text-xs disabled:cursor-not-allowed",
      if(active?,
        do: "border-brand-500/60 ring-1 ring-brand-500/25 text-zinc-200",
        else: "border-zinc-700 text-zinc-500"
      )
    ]
  end

  @doc """
  A standalone checkbox — the standard brand accent + `focus:ring-2` ring +
  clickable label — for the boxes that are NOT a changeset form field: a bare
  `name`/`checked` driven by `phx-click`/`phx-change`/`phx-value-*` (a toggle,
  an array member like `runner_filter[]`). For a checkbox bound to a form field
  reach for `<.input type="checkbox">` instead — it derives name/checked from
  the field. Sibling to `<.select>`: one place the box styling lives so the
  hand-rolled copies can't drift (e.g. one had dropped `focus:ring-2`).

  The label is either the `label` string or, for rich content, the inner block
  (a truncated runner name, a `<span>` with an `<em>`). `class` styles the
  wrapping `<label>` (the per-site border/hover/text-size). `disabled` rides
  the global `:rest` alongside the event bindings.

  A native checkbox posts nothing when off, so a `phx-change` form that must
  see the unchecked value passes `unchecked_value` (e.g. `"false"`) to emit the
  companion hidden input — omit it for `phx-click` toggles and `name="x[]"`
  array boxes, where a hidden value would be meaningless or corrupt the array.
  Use `tone={:neutral}` for ordinary authoring state that is not a semantic
  pass/allow verdict.

      <.checkbox name="agree" checked={@agreed?} phx-click="toggle" label="I agree" />
      <.checkbox name="x[]" value={id} checked={id in @selected}>
        <span class="truncate">{name}</span>
      </.checkbox>
  """
  attr :checked, :boolean, default: false
  attr :label, :string, default: nil
  attr :tone, :atom, default: :brand, values: [:brand, :neutral]

  attr :unchecked_value, :string,
    default: nil,
    doc: "emit a hidden companion input with this value"

  attr :class, :string,
    default: "flex items-center gap-3 text-sm text-zinc-300",
    doc: "classes on the wrapping <label>"

  attr :rest, :global, include: ~w(name value disabled form)
  slot :inner_block, doc: "rich label content; overrides `label` when given"

  def checkbox(assigns) do
    ~H"""
    <label class={@class}>
      <input
        :if={@unchecked_value}
        type="hidden"
        name={@rest[:name]}
        value={@unchecked_value}
        disabled={@rest[:disabled]}
      />
      <input
        type="checkbox"
        checked={@checked}
        class={[
          "h-4 w-4 rounded border-zinc-700 bg-zinc-900 focus:ring-2 focus:ring-offset-0 disabled:opacity-50",
          checkbox_tone(@tone)
        ]}
        {@rest}
      />
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        {@label}
      <% end %>
    </label>
    """
  end

  defp checkbox_tone(:brand), do: "text-brand-500 focus:ring-brand-500/40"
  defp checkbox_tone(:neutral), do: "text-zinc-500 focus:ring-zinc-500/40"

  @doc """
  Flat multi-pick as a visible checkbox list in a bordered scroll box —
  the replacement for a native `<select multiple>` (OS-white selection
  highlight, an unteachable ⌘-click contract, hostile on touch). Same
  form semantics: checked values POST under `name`. Composes the shared
  `<.checkbox>` row; `RunnerScope.runner_scope_select` is this shape's
  nested group/runner sibling.

      <.checkbox_list name="selector_values[]" options={@options} />
  """
  attr :id, :any, default: nil
  attr :name, :any, required: true, doc: ~s(checkbox field name — use the "field[]" form)

  attr :options, :list,
    required: true,
    doc: "option maps: %{value:, label:, disabled:, selected:}"

  attr :class, :any, default: nil

  def checkbox_list(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "max-h-44 divide-y divide-zinc-800/70 overflow-y-auto overscroll-contain rounded-lg bg-zinc-900 shadow-xl shadow-black/60 ring-1 ring-white/10",
        @class
      ]}
    >
      <.checkbox
        :for={opt <- @options}
        name={@name}
        value={opt.value}
        checked={opt.selected}
        disabled={opt.disabled}
        class={"flex items-center gap-2.5 px-3 py-2 text-xs #{checkbox_row_state(opt.disabled)}"}
      >
        <span class="min-w-0 flex-1 truncate text-zinc-200">{opt.label}</span>
      </.checkbox>
    </div>
    """
  end

  defp checkbox_row_state(true), do: "cursor-not-allowed opacity-50"
  defp checkbox_row_state(false), do: "cursor-pointer hover:bg-zinc-900/60"

  @doc """
  Dashed add-row — the composer-standard affordance at the END of a
  repeating list ("+ Add step"), so the control stays where the new row appears.

      <.add_row label="Add step" phx-click="add_action_step" />
  """
  attr :label, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)

  def add_row(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "flex w-full items-center justify-center gap-2 rounded-lg border border-dashed border-zinc-800 px-4 py-3 text-xs font-medium text-zinc-400 transition-colors enabled:hover:border-zinc-700 enabled:hover:bg-white/[0.04] enabled:hover:text-zinc-200 disabled:opacity-40",
        @class
      ]}
      {@rest}
    >
      <.icon name="hero-plus" class="h-4 w-4" />{@label}
    </button>
    """
  end

  @doc """
  Renders a form label. `:default` is the standard `text-sm` form label;
  `:eyebrow` is the compact small-caps label the dense editors use above their
  fields. One component so the two field-label treatments don't drift into more.
  """
  attr :for, :string, default: nil
  attr :variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :rest, :global, doc: "extra attributes (e.g. title for a tooltip hint)"
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class={label_variant(@variant)} {@rest}>
      {render_slot(@inner_block)}
    </label>
    """
  end

  defp label_variant(:default), do: "block text-sm font-medium text-zinc-200"

  defp label_variant(:eyebrow),
    do: "block text-[10px] font-semibold uppercase tracking-wider text-zinc-400"

  @doc """
  The inline field error — the message sits at the form's own type scale,
  directly under the input it is about.

  `compact` drops it to a dense control's scale and hands the spacing back to
  the caller: inside a picker whose own rows are `text-xs`, the default `text-sm`
  reads a step LOUDER than the thing it is correcting, and a baked-in `mt-2`
  fights the panel's padding.
  """
  attr :compact, :boolean, default: false

  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class={[
      "flex items-center gap-1.5 text-rose-400",
      if(@compact, do: "text-xs", else: "mt-2 text-sm")
    ]}>
      <.icon
        name="hero-exclamation-circle-mini"
        class={"flex-none " <> if(@compact, do: "h-3.5 w-3.5", else: "h-4 w-4")}
      />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  The ONE attention callout — a toned icon capping a quiet vertical spine,
  optional `title`, the message (default slot), and an optional `:action`.
  Every console alert and heads-up renders through this, or through a thin
  domain wrapper that only maps domain state → tone/copy (`<.offline_notice>`,
  `<.subscription_banner>`) — never a fresh class table (design-console-ux §1). The
  message renders escaped through HEEx (IL-16).

  Tones are the house hue atoms (design-console-ux §2), meaning assigned at the call
  site: `:brand` informational/affirmative, `:amber` caution/pending, `:rose`
  danger/error, `:neutral` quiet note. The default `:spine` variant is naked on
  the canvas; `:strip` is the deliberately different flush full-width row with
  a bottom hairline for shell-wide nudges. Pass `navigate` to make the whole
  callout a link — the `:action` then renders as static text inside the link
  (no nested interactive element).

      <.callout tone={:amber}>Copy the token now — we won't show it again.</.callout>

      <.callout tone={:rose} icon="hero-no-symbol" title="Cancelled">
        {@run.reason_text}
        <:action><.button variant={:secondary} tone={:rose} size={:md} navigate={...}>Review</.button></:action>
      </.callout>

      <.callout tone={:amber} title="2 packs need trust review" navigate={~p"/app/…/packs"}>
        Dispatch is blocked until an admin decides.
        <:action>Review pack trust →</:action>
      </.callout>
  """
  attr :tone, :atom, default: :neutral, values: [:neutral, :brand, :amber, :rose]
  attr :variant, :atom, default: :spine, values: [:spine, :strip]
  attr :title, :string, default: nil
  attr :icon, :string, default: nil, doc: "heroicon override"
  attr :navigate, :any, default: nil, doc: "makes the whole callout a link"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true
  slot :action, doc: "right-aligned action — a button/link, or static text under `navigate`"

  def callout(%{variant: :spine, navigate: nil} = assigns) do
    ~H"""
    <.event_block
      icon={callout_icon_name(@icon, @tone)}
      tone={@tone}
      title={@title}
      class={@class}
      {@rest}
    >
      <:body>{render_slot(@inner_block)}</:body>
      <%!-- text-sm on the wrapper: a bare-text action would otherwise inherit
           the page-base 16px and tower over the text-sm body (buttons carry
           their own size and are unaffected). --%>
      <div :if={@action != []} class="mt-3 text-sm">{render_slot(@action)}</div>
    </.event_block>
    """
  end

  def callout(%{variant: :spine} = assigns) do
    ~H"""
    <%!-- `group` lets an action's <.cta_arrow> nudge on the card hover. --%>
    <.link
      navigate={@navigate}
      class={["group block rounded-md p-2 transition-colors hover:bg-white/[0.04]", @class]}
      {@rest}
    >
      <.event_block
        icon={callout_icon_name(@icon, @tone)}
        tone={@tone}
        title={@title}
      >
        <:body>{render_slot(@inner_block)}</:body>
        <div :if={@action != []} class="mt-3 text-sm">{render_slot(@action)}</div>
      </.event_block>
    </.link>
    """
  end

  def callout(%{navigate: nil} = assigns) do
    ~H"""
    <div class={[callout_frame(@variant), callout_tone(@tone), @class]} {@rest}>
      <.callout_content
        variant={@variant}
        tone={@tone}
        title={@title}
        icon={@icon}
        body={@inner_block}
        action={@action}
      />
    </div>
    """
  end

  def callout(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[callout_frame(@variant), callout_tone(@tone), callout_hover(@tone), @class]}
      {@rest}
    >
      <.callout_content
        variant={@variant}
        tone={@tone}
        title={@title}
        icon={@icon}
        body={@inner_block}
        action={@action}
      />
    </.link>
    """
  end

  attr :variant, :atom, required: true
  attr :tone, :atom, required: true
  attr :title, :string, required: true
  attr :icon, :any, required: true
  attr :body, :any, required: true
  attr :action, :any, required: true

  defp callout_content(assigns) do
    ~H"""
    <.icon name={callout_icon_name(@icon, @tone)} class={callout_icon_class(@variant)} />
    <div class="min-w-0 flex-1">
      <p :if={@title} class="font-semibold">{@title}</p>
      <div class={@title && "mt-0.5 opacity-90"}>{render_slot(@body)}</div>
    </div>
    <%!-- Below sm the action drops to its own full-width row — a button
         beside an 11-line strangled text column isn't a layout. --%>
    <div :if={@action != []} class="w-full shrink-0 self-center sm:w-auto">
      {render_slot(@action)}
    </div>
    """
  end

  defp callout_frame(:strip),
    do: "flex flex-wrap items-center gap-3 border-b px-4 py-2.5 text-sm sm:px-6"

  defp callout_icon_class(:strip), do: "h-4 w-4 flex-none"

  defp callout_tone(:neutral), do: "border-zinc-700 bg-zinc-900/40 text-zinc-300"
  defp callout_tone(:brand), do: "border-brand-500/30 bg-brand-500/10 text-brand-200"
  defp callout_tone(:amber), do: "border-amber-500/40 bg-amber-500/10 text-amber-100"
  defp callout_tone(:rose), do: "border-rose-500/30 bg-rose-500/10 text-rose-200"

  defp callout_hover(:neutral), do: "transition hover:bg-zinc-900/60"
  defp callout_hover(:brand), do: "transition hover:bg-brand-500/[0.16]"
  defp callout_hover(:amber), do: "transition hover:bg-amber-500/[0.16]"
  defp callout_hover(:rose), do: "transition hover:bg-rose-500/[0.16]"

  defp callout_icon(:neutral), do: "hero-information-circle-mini"
  defp callout_icon(:brand), do: "hero-information-circle-mini"
  defp callout_icon(:amber), do: "hero-exclamation-triangle-mini"
  defp callout_icon(:rose), do: "hero-exclamation-triangle-mini"

  defp callout_icon_name(nil, tone), do: callout_icon(tone)
  defp callout_icon_name("hero-" <> _ = icon, _tone), do: icon

  @doc """
  Naked status note — the canvas grammar for a passive fact ABOUT the surface
  it sits on (a posture fact, a reach statement): toned icon
  lead + title + body, no spine. The icon-capped `<.callout>` is for actionable
  interruptions; giving a quiet annotation the alert spine would overstate it
  (design-system §8.1 draws the line). `tone` colors the ICON only —
  the words stay neutral. `primary` lifts the title to the page's strongest
  status voice (semibold/zinc-100); the default is the supporting-note tier
  (medium/zinc-200) that reads one level below it.

      <.status_note icon="hero-shield-check" tone={:brand} title="Signed dispatch only">
        This runner verifies a client signature on every run.
      </.status_note>
  """
  attr :icon, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:amber, :brand, :rose, :neutral]
  attr :title, :string, required: true
  attr :primary, :boolean, default: false, doc: "the page's strongest status voice"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def status_note(assigns) do
    ~H"""
    <div class={["flex items-start gap-3", @class]}>
      <.icon name={@icon} class={"mt-0.5 h-4 w-4 shrink-0 #{status_note_icon_class(@tone)}"} />
      <div class="min-w-0">
        <div class={[
          "text-sm",
          if(@primary, do: "font-semibold text-zinc-100", else: "font-medium text-zinc-200")
        ]}>
          {@title}
        </div>
        <p class="mt-1 text-sm leading-relaxed text-zinc-400">{render_slot(@inner_block)}</p>
      </div>
    </div>
    """
  end

  defp status_note_icon_class(:amber), do: "text-amber-300"
  defp status_note_icon_class(:brand), do: "text-brand-400"
  defp status_note_icon_class(:rose), do: "text-rose-400"
  defp status_note_icon_class(:neutral), do: "text-zinc-400"

  @doc """
  Transient event block — a state the page is passing through (a rotation
  reveal awaiting its copy, a run held on approval, a cancelled/errored
  outcome) interrupting a page whose main content is something else. The
  toned icon CAPS a quiet spine (its own hue faded back) that binds title,
  body, and payload into ONE contained unit — §8.1's containment grammar
  without a wash box. `:amber` = pending/attention, `:rose` = a failed or
  refused outcome, `:brand` = a positive terminal verdict (an approval) that
  carries real content — decider, time, note — never an empty "all good". The payload (a `code_panel`, an action button) renders in
  the default slot beneath the body; give payload children their own `mt-*`.

      <.event_block icon="hero-key" title="Key rotated — copy the new key now">
        <:body>Update the client config, then revoke the old key below.</:body>
        <.code_panel id="new-key" label="API key" copy code={@secret} class="mt-4" />
      </.event_block>
  """
  attr :icon, :string, required: true
  attr :tone, :atom, default: :amber, values: [:amber, :rose, :brand, :neutral]
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :body, required: true
  slot :inner_block

  def event_block(%{icon: "hero-" <> _} = assigns) do
    ~H"""
    <div class={["flex gap-4", @class]} {@rest}>
      <div class="flex w-4 flex-col items-center" aria-hidden="true">
        <.icon name={@icon} class={"mt-0.5 h-4 w-4 shrink-0 #{status_note_icon_class(@tone)}"} />
        <div class={["mt-3 w-0.5 flex-1 rounded-full", event_block_spine_class(@tone)]}></div>
      </div>
      <div class="min-w-0 flex-1">
        <div :if={@title} class="text-sm font-medium text-zinc-200">{@title}</div>
        <div class={[@title && "mt-1", "text-sm leading-relaxed text-zinc-400"]}>
          {render_slot(@body)}
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp event_block_spine_class(:amber), do: "bg-amber-300/40"
  defp event_block_spine_class(:rose), do: "bg-rose-400/40"
  defp event_block_spine_class(:brand), do: "bg-brand-400/40"
  defp event_block_spine_class(:neutral), do: "bg-zinc-700"

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition transform ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(EmisarWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EmisarWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Shell for authenticated product pages: sidebar + topbar + main.
  Expects @current_user, @current_account in assigns.
  `:pending_approvals_count` is set by the `:track_pending_approvals`
  on_mount hook (UserAuth) — defaults to 0 so the shell still renders
  in test contexts that haven't gone through the hook.
  `:switchable_accounts` is the full list of accounts the user can
  pick from (including the current one); defaults to a list with just
  the current account so the shell still renders without the on_mount
  hook in unit tests.
  """
  attr :current_user, :map, required: true
  attr :current_account, :map, required: true
  attr :current_subject, :map, required: true
  # The membership, so the person's name is the one THIS account knows them by. A
  # directory can rename a member per account, and `users.full_name` is
  # cross-account — a multi-account synced member was called two different things
  # depending on which surface you looked at. Defaults to nil so a unit test
  # rendering the shell without the on_mount hook still works.
  attr :current_membership, :map, default: nil
  attr :switchable_accounts, :list, default: nil
  attr :section, :atom, default: :dashboard

  attr :width, :atom,
    default: :detail,
    values: [:table, :detail, :form, :settings],
    doc:
      "content column width: :table (7xl — every operate/list page incl. dashboard/runs/audit), :detail (6xl), :form (3xl), :settings (4xl)"

  attr :pending_approvals_count, :integer, default: 0
  attr :pending_packs_count, :integer, default: 0
  attr :fleet_all_offline?, :boolean, default: false
  attr :no_agents?, :boolean, default: false
  attr :onboarding_incomplete?, :boolean, default: false
  attr :flash, :map, default: %{}

  slot :inner_block, required: true
  slot :title, required: true
  slot :actions

  def dashboard_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Desktop sidebar (lg and up). `sticky top-0 h-screen` pins
           it to the viewport so the bottom user-block (and sign-out
           icon) stays reachable on tall pages instead of being pushed
           off-screen by content height. --%>
      <%!-- The sidebar sits on the SAME black plane as the work canvas — one
           surface, a single landed hairline between nav and work (the old
           zinc-950 panel read as separate admin chrome beside the canvas). --%>
      <aside class="hidden w-64 flex-shrink-0 flex-col border-r border-zinc-800/70 bg-black lg:sticky lg:top-0 lg:flex lg:h-screen">
        <.shell_brand
          current_account={@current_account}
          switchable_accounts={@switchable_accounts || [@current_account]}
        />
        <.shell_nav
          current_account={@current_account}
          current_user={@current_user}
          current_subject={@current_subject}
          section={@section}
          pending_approvals_count={@pending_approvals_count}
          pending_packs_count={@pending_packs_count}
          fleet_all_offline?={@fleet_all_offline?}
          no_agents?={@no_agents?}
          onboarding_incomplete?={@onboarding_incomplete?}
        />
        <.shell_user
          current_user={@current_user}
          current_account={@current_account}
          current_membership={@current_membership}
        />
      </aside>

      <%!-- Mobile drawer (hidden by default; JS toggles `open`). The focus_wrap
           contains Tab inside the open drawer; DialogFocus returns focus to the
           hamburger on close — without both, a keyboard/SR operator tabs into
           the page hidden behind the backdrop and loses their place. --%>
      <div
        id="mobile-nav"
        class="fixed inset-0 z-40 hidden lg:hidden"
        role="dialog"
        aria-modal="true"
        aria-label="Menu"
        phx-hook="DialogFocus"
        phx-window-keydown={close_mobile_nav()}
        phx-key="escape"
      >
        <div class="absolute inset-0 bg-black/60" phx-click={close_mobile_nav()}></div>
        <.focus_wrap
          id="mobile-nav-wrap"
          class="relative flex h-full w-72 max-w-[80vw] flex-col border-r border-zinc-800/70 bg-black shadow-2xl"
        >
          <div class="flex items-center justify-between border-b border-zinc-800/70 px-4 py-3">
            <.shell_brand
              current_account={@current_account}
              switchable_accounts={@switchable_accounts || [@current_account]}
            />
            <button
              type="button"
              aria-label="Close menu"
              class="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
              phx-click={close_mobile_nav()}
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <.shell_nav
            current_account={@current_account}
            current_user={@current_user}
            current_subject={@current_subject}
            section={@section}
            pending_approvals_count={@pending_approvals_count}
            pending_packs_count={@pending_packs_count}
            fleet_all_offline?={@fleet_all_offline?}
            no_agents?={@no_agents?}
            onboarding_incomplete?={@onboarding_incomplete?}
          />
          <.shell_user
            current_user={@current_user}
            current_account={@current_account}
            current_membership={@current_membership}
          />
        </.focus_wrap>
      </div>

      <%!-- The whole console — sidebar AND work column — is one black plane.
           The id is the capture anchor for full-workspace docs shots
           (tools/internal/browser/docs.go): the page without the nav rail. --%>
      <div id="shell-canvas" class="flex min-w-0 flex-1 flex-col bg-black">
        <%!-- Portal-wide nudge: a signed-in user whose email isn't
             confirmed yet. Shown on every page until they verify; the
             "Resend" button is handled by the global `:email_confirmation`
             on_mount hook so it works regardless of which LV is mounted. --%>
        <.callout
          :if={@current_user && is_nil(@current_user.confirmed_at)}
          tone={:amber}
          variant={:strip}
          icon="hero-envelope"
        >
          Verify your email — we sent a confirmation link to <span class="font-medium text-amber-100">{@current_user.email}</span>.
          <:action>
            <.button variant={:secondary} size={:sm} phx-click="resend_confirmation">
              Resend email
            </.button>
          </:action>
        </.callout>

        <%!-- The no-LLM nudge is ONE signal: the nav item's attention dot.
             The page-wide banner strip died — three signals for one fact (a
             brand-washed banner on every page + the nav dot + the dashboard
             pillar) shouted an invitation, and green belongs to pass/healthy,
             not to "nothing connected yet". --%>
        <%!-- min-h (not h): the title WRAPS on a phone instead of ellipsizing —
             a truncated machine id ("api-iad-…") is useless on an audit-grade
             surface, so the bar grows to fit and break-words splits an unbroken
             id token only when it must. --%>
        <%!-- The title floats ON the canvas — no bar, no border, no blur. A
             gray sticky strip with a lone word was pure admin-template chrome;
             the page title is the first line of the content, set large, and the
             page begins. --%>
        <header class="px-4 pb-2 pt-7 sm:px-8 sm:pt-9">
          <%!-- items-center, not items-start: a taller action button (a :md
               control beside the H1) would otherwise stretch the row's bottom
               below the title and inflate the gap to the page intro — the gap
               read larger on Audit / Runbooks than on action-less pages. --%>
          <div class={[
            "mx-auto flex w-full flex-wrap items-center gap-x-3 gap-y-3",
            shell_width(@width)
          ]}>
            <%!-- Mobile hamburger (hidden on lg) — the 36px button centers on
                 the title's 35px first line; a top margin pushed the icon
                 visibly below the title's optical center. --%>
            <button
              type="button"
              id="mobile-nav-open"
              aria-label="Open menu"
              aria-controls="mobile-nav"
              aria-expanded="false"
              class="-ml-1.5 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 lg:hidden"
              phx-click={open_mobile_nav()}
            >
              <.icon name="hero-bars-3" class="h-5 w-5" />
            </button>
            <%!-- basis-0 + a generous min width: while the title has room it
                 shares the row with the actions; on a phone the actions WRAP
                 to their own line below instead of crushing the h1 into
                 mid-word breaks ("Run/ner/s"). --%>
            <h1 class="min-w-[12rem] flex-1 basis-0 break-words font-display text-[28px] font-bold leading-tight tracking-[-0.03em] text-zinc-50">
              {render_slot(@title)}
            </h1>
            <%!-- ml-auto: actions hold the RIGHT edge on the shared row AND
                 when they wrap to their own line on a phone. --%>
            <div class="ml-auto flex shrink-0 flex-wrap items-center gap-2 sm:gap-3">
              {render_slot(@actions)}
            </div>
          </div>
        </header>

        <%!-- The work canvas is clean flat BLACK. Most content sits DIRECTLY on
             it — typography and space carry the structure; a contained surface
             (island) is reserved for things where the box MEANS something (a
             code artifact, a form, an attention panel). --%>
        <main class="flex-1 overflow-x-hidden bg-black px-4 pb-10 pt-2 sm:px-8">
          <div class={["mx-auto w-full space-y-6", shell_width(@width)]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  # Content width tiers: one column width per page kind so every screen lines up
  # (the shell owns it — pages pass `width=`, never hand-roll `mx-auto max-w-*`).
  # Dense DATA TABLES go FULL-BLEED (founder: "centering tables like the audit log
  # is a no-go — too much data") for column density; card-lists + dashboard stay
  # capped so a single-column card doesn't stretch thin; reading/forms bounded for
  # line length. Literal classes so Tailwind's purge keeps them.
  # ONE operating width: every top-level console page caps at 7xl (`:full`
  # died — dashboard/runs/audit stretching edge-to-edge beside 7xl-capped
  # peers made adjacent clicks feel like different products). The ladder:
  # 7xl operate/list · 6xl detail · 4xl settings · 3xl focused flow.
  defp shell_width(:table), do: "max-w-7xl"
  defp shell_width(:detail), do: "max-w-6xl"
  defp shell_width(:form), do: "max-w-3xl"
  defp shell_width(:settings), do: "max-w-4xl"

  # The drawer opens/closes entirely client-side, so these commands own the
  # hamburger's aria-expanded state too; focus_first moves focus inside on open
  # (the focus_wrap sentinels are aria-hidden, so it lands on a real control)
  # and the DialogFocus hook restores it to the hamburger on close.
  defp open_mobile_nav do
    JS.show(to: "#mobile-nav", display: "block")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#mobile-nav-open")
    |> JS.focus_first(to: "#mobile-nav")
  end

  defp close_mobile_nav do
    JS.hide(to: "#mobile-nav")
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-nav-open")
  end

  # -- shell sub-components (shared between desktop + mobile) ----------

  attr :current_account, :map, required: true
  attr :switchable_accounts, :list, required: true

  defp shell_brand(assigns) do
    others =
      Enum.reject(assigns.switchable_accounts, &(&1.id == assigns.current_account.id))

    assigns = assign(assigns, :other_accounts, others)

    ~H"""
    <.dropdown
      class="border-b border-zinc-800/70"
      align={:stretch}
      summary_class="flex h-16 items-center gap-3 px-2 transition hover:bg-white/[0.04] lg:px-6"
      panel_class="z-30 mt-1 overflow-hidden shadow-2xl"
    >
      <:trigger>
        <img src={~p"/images/brand/emisar-icon.svg"} alt="" class="h-8 w-8 shrink-0" />
        <div class="min-w-0 flex-1 translate-y-[2px]">
          <img
            src={~p"/images/brand/emisar-wordmark.svg"}
            alt="emisar"
            class="h-2.5 w-auto opacity-75"
          />
          <div class="mt-0.5 truncate text-sm font-semibold leading-tight text-zinc-100">
            {@current_account.name}
          </div>
        </div>
        <.icon
          name="hero-chevron-up-down"
          class="h-4 w-4 shrink-0 text-zinc-500 transition group-open:text-zinc-300"
        />
      </:trigger>

      <div class="border-b border-zinc-900 px-3 py-2">
        <p class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Switch workspace
        </p>
      </div>

      <ul class="scrollbar-subtle max-h-[60vh] overflow-y-auto py-1">
        <li>
          <div class="flex items-center gap-2 px-3 py-2 text-sm">
            <.icon name="hero-check" class="h-4 w-4 shrink-0 text-brand-400" />
            <span class="truncate font-medium">{@current_account.name}</span>
          </div>
        </li>
        <%= for account <- @other_accounts do %>
          <li>
            <form action={~p"/app/accounts/switch"} method="post" class="contents">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <input type="hidden" name="account_id" value={account.id} />
              <button
                type="submit"
                class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-zinc-200 transition hover:bg-zinc-900"
              >
                <.avatar name={account.name} shape={:square} size={:xs} />
                <span class="truncate">{account.name}</span>
              </button>
            </form>
          </li>
        <% end %>
      </ul>

      <div class="border-t border-zinc-800/70 p-1">
        <.link
          navigate={~p"/onboarding"}
          class="flex items-center gap-2 rounded-md px-3 py-2 text-sm text-zinc-300 transition hover:bg-zinc-900 hover:text-zinc-100"
        >
          <.icon name="hero-plus" class="h-4 w-4 shrink-0" />
          <span>Create new workspace</span>
        </.link>
      </div>
    </.dropdown>
    """
  end

  attr :section, :atom, required: true
  attr :current_subject, :map, required: true
  attr :pending_approvals_count, :integer, default: 0
  attr :pending_packs_count, :integer, default: 0
  attr :fleet_all_offline?, :boolean, default: false
  attr :no_agents?, :boolean, default: false
  attr :onboarding_incomplete?, :boolean, default: false
  attr :current_account, :map, required: true
  attr :current_user, :map, required: true

  defp shell_nav(assigns) do
    # One domain predicate per section — the nav shows only what the member
    # can actually open (a billing_manager sees Billing + Team, not six dead
    # links). Courtesy only: every context still denies server-side (IL-15).
    subject = assigns.current_subject

    assigns =
      assign(assigns,
        can_view_runners?: Emisar.Runners.subject_can_view_runners?(subject),
        can_view_agents?: Emisar.ApiKeys.subject_can_view_api_keys?(subject),
        can_view_runs?: Emisar.Runs.subject_can_view_runs?(subject),
        can_view_approvals?: Emisar.Approvals.subject_can_view_approvals?(subject),
        can_view_audit?: Emisar.Audit.subject_can_view_audit?(subject),
        can_view_packs?: Emisar.Catalog.subject_can_view_packs?(subject),
        can_view_policies?: Emisar.Policies.subject_can_view_policies?(subject),
        can_view_runbooks?: Emisar.Runbooks.subject_can_view_runbooks?(subject)
      )

    support_context =
      MailTo.context(%{
        current_account: assigns.current_account,
        current_user: assigns.current_user
      })

    assigns =
      assign(
        assigns,
        :support_mailto,
        MailTo.support(
          subject: "Support request - #{assigns.current_account.name}",
          context: support_context
        )
      )

    ~H"""
    <%!-- pt-2/pb-4 + the tightened group air below keep the WHOLE nav (18 links,
         5 groups) under ~730px, so at common laptop heights (≥860px with the
         brand + user blocks) nothing sits half-clipped at the scroll fold —
         "Support" cut in half read as a rendering defect on every screenshot. --%>
    <nav class="scrollbar-subtle flex-1 space-y-0.5 overflow-y-auto px-3 pb-4 pt-2 text-sm">
      <.nav_link
        to={~p"/app/#{@current_account}"}
        active={@section == :dashboard}
        icon="hero-home"
        alert={@onboarding_incomplete?}
        alert_label="Finish setup — add a runner or an agent"
      >
        Dashboard
      </.nav_link>

      <%!-- Connect — the two things you need to USE emisar: a runner to execute and
           an agent to call it. Surfaced at the top so setup is one glance away. --%>
      <.nav_group :if={@can_view_runners? or @can_view_agents?} label="Connect" />
      <.nav_link
        :if={@can_view_runners?}
        to={~p"/app/#{@current_account}/runners"}
        active={@section == :runners}
        icon="hero-cpu-chip"
        alert={@fleet_all_offline?}
        alert_label="All runners offline"
      >
        Runners
      </.nav_link>
      <.nav_link
        :if={@can_view_agents?}
        to={~p"/app/#{@current_account}/agents"}
        active={@section == :agents}
        icon="hero-sparkles"
        alert={@no_agents?}
        alert_label="No LLM agent connected yet"
      >
        LLM agents
      </.nav_link>

      <.nav_group
        :if={@can_view_runs? or @can_view_approvals? or @can_view_audit?}
        label="Operate"
      />
      <.nav_link
        :if={@can_view_runs?}
        to={~p"/app/#{@current_account}/runs"}
        active={@section == :runs}
        icon="hero-bolt"
      >
        Runs
      </.nav_link>
      <.nav_link
        :if={@can_view_approvals?}
        to={~p"/app/#{@current_account}/approvals"}
        active={@section == :approvals}
        icon="hero-shield-check"
        badge={@pending_approvals_count}
      >
        Approvals
      </.nav_link>
      <.nav_link
        :if={@can_view_audit?}
        to={~p"/app/#{@current_account}/audit"}
        active={@section == :audit}
        icon="hero-list-bullet"
      >
        Audit
      </.nav_link>

      <.nav_group
        :if={@can_view_packs? or @can_view_policies? or @can_view_runbooks?}
        label="Control"
      />
      <.nav_link
        :if={@can_view_packs?}
        to={~p"/app/#{@current_account}/packs"}
        active={@section == :packs}
        icon="hero-cube"
        badge={@pending_packs_count}
      >
        Packs
      </.nav_link>
      <.nav_link
        :if={@can_view_policies?}
        to={~p"/app/#{@current_account}/policies"}
        active={@section == :policies}
        icon="hero-document-text"
      >
        Policy
      </.nav_link>
      <.nav_link
        :if={@can_view_runbooks?}
        to={~p"/app/#{@current_account}/runbooks"}
        active={@section == :runbooks}
        icon="hero-book-open"
      >
        Runbooks
      </.nav_link>

      <.nav_group label="Settings" />
      <.nav_link
        to={~p"/app/#{@current_account}/settings/team"}
        active={@section == :team}
        icon="hero-user-group"
      >
        Team
      </.nav_link>
      <.nav_link
        to={~p"/app/#{@current_account}/settings/billing"}
        active={@section == :billing}
        icon="hero-credit-card"
      >
        Billing
      </.nav_link>

      <.nav_group label="Resources" />
      <.nav_link_external href={~p"/docs"} icon="hero-book-open">Docs</.nav_link_external>
      <.nav_link_external href={~p"/changelog"} icon="hero-megaphone">Changelog</.nav_link_external>
      <.nav_link_external
        href={Application.get_env(:emisar_web, :status_page_url, "https://status.emisar.dev")}
        icon="hero-signal"
      >
        Status
      </.nav_link_external>
      <.nav_link_external href={@support_mailto} icon="hero-lifebuoy">
        Support
      </.nav_link_external>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link_external(assigns) do
    ~H"""
    <.link
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="flex items-center gap-3 rounded-lg px-3 py-1.5 text-zinc-400 transition hover:bg-white/[0.04] hover:text-zinc-100"
    >
      <.icon name={@icon} class="h-4 w-4 text-zinc-500" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5 text-zinc-500" />
    </.link>
    """
  end

  attr :label, :string, required: true

  defp nav_group(assigns) do
    ~H"""
    <div class="pb-1 pt-2.5 first:pt-0">
      <p class="px-3 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
        {@label}
      </p>
    </div>
    """
  end

  attr :current_user, :map, required: true
  attr :current_account, :map, required: true
  attr :current_membership, :map, default: nil

  defp shell_user(assigns) do
    ~H"""
    <div class="border-t border-zinc-800/70 p-4 text-sm">
      <div class="flex items-center gap-3">
        <.link
          navigate={~p"/app/#{@current_account}/settings/profile"}
          phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
          class="flex min-w-0 flex-1 items-center gap-3 rounded-lg p-1 -m-1 transition hover:bg-white/[0.04]"
          aria-label="Open profile settings"
        >
          <.avatar
            name={Accounts.member_display_name(@current_membership, @current_user)}
            size={:sm}
          />
          <div class="min-w-0 flex-1">
            <div class="truncate font-medium">
              {Accounts.member_display_name(@current_membership, @current_user)}
            </div>
            <div
              :if={email = Accounts.secondary_user_email(@current_user)}
              class="truncate text-xs text-zinc-400"
            >
              {email}
            </div>
          </div>
        </.link>
        <.link
          href={~p"/sign_out"}
          method="delete"
          class="grid h-8 w-8 shrink-0 place-items-center rounded-md text-zinc-500 transition hover:bg-zinc-900 hover:text-zinc-200"
          title="Sign out"
          aria-label="Sign out"
        >
          <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
        </.link>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true

  attr :badge, :any,
    default: nil,
    doc:
      "Optional notification count rendered as a pill on the right edge. `nil` / `0` / `false` " <>
        "hide the badge; positive integers render as e.g. `3`; values ≥ 100 render as `99+` so " <>
        "the pill never overflows the rail."

  attr :alert, :boolean,
    default: false,
    doc:
      "A small amber alert dot on the right edge (e.g. the whole fleet is offline), independent " <>
        "of the count `badge`. Pair with `alert_label` for the screen-reader text."

  attr :alert_label, :string, default: nil, doc: "Visually-hidden text announcing the alert dot."

  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <%!-- Active = the house light wash + bright text, with the ICON carrying
         the one quiet brand signal — the old filled green pill (fill + ring)
         was the last admin-template artifact in the shell, and green-as-
         selection diluted "emerald = passed the gate". --%>
    <.link
      navigate={@to}
      phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-1.5 transition",
        @active && "bg-white/[0.06] font-medium text-zinc-50",
        !@active && "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-100"
      ]}
    >
      <.icon
        name={@icon}
        class={"h-4 w-4 #{if @active, do: "text-brand-400", else: "text-zinc-500"}"}
      />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <span
        :if={badge_visible?(@badge)}
        class="rounded-full bg-amber-500/20 px-2 py-0.5 text-[10px] font-semibold leading-none tabular-nums text-amber-200 ring-1 ring-inset ring-amber-500/30"
      >
        {badge_label(@badge)}
      </span>
      <span :if={@alert} class="h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400" aria-hidden="true"></span>
      <span :if={@alert} class="sr-only">{@alert_label}</span>
    </.link>
    """
  end

  defp badge_visible?(n) when is_integer(n) and n > 0, do: true
  defp badge_visible?(_), do: false

  defp badge_label(n) when is_integer(n) and n >= 100, do: "99+"
  defp badge_label(n) when is_integer(n), do: Integer.to_string(n)

  @doc """
  Placeholder for the brief pre-connect render pass of a LiveView whose
  data loads only once the socket is `connected?/1` (IL-18) — keeps
  `mount/3` free of DB work without flashing a misleading empty state.
  """
  def loading_state(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-2 py-20 text-sm text-zinc-400">
      <.icon name="hero-arrow-path" class="h-5 w-5 animate-spin" />
      <span>Loading…</span>
    </div>
    """
  end

  @doc """
  A dotted mono identifier (an action id, an event type) rendered with a
  `<wbr>` break opportunity after each dot, so a narrow screen wraps it at a
  segment boundary — `caddy.` / `reverse_proxy_upstreams` — never sheared
  mid-token the way `break-all` does. `<wbr>` adds nothing to copied text.
  Pair with `break-words` on the container (the wbr points do the breaking;
  break-words only backstops a single over-long segment).

      <div class="break-words font-mono"><.dotted_mono value={run.action_id} /></div>
  """
  attr :value, :string, required: true

  def dotted_mono(assigns) do
    # Each segment keeps its trailing separator (dot or dash — action ids,
    # hostnames, UUIDs), so a <wbr> BEFORE the next segment breaks the line
    # cleanly after the separator ("api-iad-02.northstar." / "example"), never
    # mid-token ("norths / tar").
    assigns = assign(assigns, :segments, Regex.split(~r/(?<=[.-])/, assigns.value))

    ~H"""
    <%!-- phx-no-format: any formatter-introduced whitespace inside the repeated
         span renders as a visible gap in the id ("caddy .reload_config"). --%>
    <span
      :for={{segment, index} <- Enum.with_index(@segments)}
      phx-no-format
    ><wbr :if={index > 0} />{segment}</span>
    """
  end

  @doc """
  The ONE status dot — the colored circle every live-state indicator composes
  (design-console-ux §1): posture-line stats, the status badge, connection dots,
  audit outcome dots, SCIM sync health, wait-room pings. Tones are the house
  hue atoms; `pulse` is the gentle in-progress fade (a running run), `ping`
  the radiating "live/waiting" ring (a connected runner, a wait-room). Extra
  attributes (e.g. `title`) ride `@rest`.

      <.status_dot tone={:brand} />
      <.status_dot tone={:brand} ping size={:md} title="Connected" />
      <.status_dot tone={:amber} pulse />
  """
  attr :tone, :atom, default: :neutral, values: [:neutral, :brand, :amber, :rose]
  attr :pulse, :boolean, default: false
  attr :ping, :boolean, default: false
  attr :size, :atom, default: :sm, values: [:sm, :md, :lg]
  attr :class, :any, default: nil
  attr :rest, :global

  def status_dot(%{ping: true} = assigns) do
    ~H"""
    <span
      class={["relative flex shrink-0", status_dot_size(@size), @class]}
      aria-hidden="true"
      {@rest}
    >
      <span class={[
        "absolute inline-flex h-full w-full animate-ping rounded-full opacity-75",
        status_dot_bg(@tone)
      ]}></span>
      <span class={["relative inline-flex rounded-full", status_dot_size(@size), status_dot_bg(@tone)]}></span>
    </span>
    """
  end

  def status_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block shrink-0 rounded-full",
        status_dot_size(@size),
        status_dot_bg(@tone),
        @pulse && "animate-pulse",
        @class
      ]}
      aria-hidden="true"
      {@rest}
    ></span>
    """
  end

  defp status_dot_size(:sm), do: "h-1.5 w-1.5"
  defp status_dot_size(:md), do: "h-2 w-2"
  defp status_dot_size(:lg), do: "h-2.5 w-2.5"

  defp status_dot_bg(:neutral), do: "bg-zinc-600"
  defp status_dot_bg(:brand), do: "bg-brand-400"
  defp status_dot_bg(:amber), do: "bg-amber-400"
  defp status_dot_bg(:rose), do: "bg-rose-400"

  @doc """
  Initial-letter avatar — the ONE identity disc (design-console-ux §1): a person or
  workspace rendered as the first letter of its name. `:circle` for people
  (the shell user block, the team roster), `:square` for workspaces (the
  account switcher rows).

      <.avatar name={Accounts.user_display_name(@current_user)} size={:sm} />
      <.avatar name={account.name} shape={:square} size={:xs} />
  """
  attr :name, :string, required: true
  attr :size, :atom, default: :md, values: [:xs, :sm, :md]
  attr :shape, :atom, default: :circle, values: [:circle, :square]
  attr :class, :string, default: nil

  def avatar(assigns) do
    ~H"""
    <span class={[
      "grid shrink-0 place-items-center bg-zinc-800 font-semibold uppercase",
      avatar_size(@size),
      avatar_shape(@shape),
      @class
    ]}>
      {String.first(@name || "?")}
    </span>
    """
  end

  # :sm carries no text color on purpose — the shell user block inherits its
  # link's foreground so the avatar dims/brightens with the hover state.
  defp avatar_size(:xs), do: "h-4 w-4 text-[10px] text-zinc-400"
  defp avatar_size(:sm), do: "h-8 w-8 text-xs"
  defp avatar_size(:md), do: "h-10 w-10 text-sm text-zinc-300"

  defp avatar_shape(:circle), do: "rounded-full"
  defp avatar_shape(:square), do: "rounded-sm"

  @doc "Run/runner status — a tone dot + the plain word (no pill). String or Ecto.Enum atom."
  attr :status, :any, required: true

  attr :tone, :atom,
    default: nil,
    values: [nil, :brand, :amber, :rose, :neutral],
    doc:
      "override the word-derived tone for a status that is TRUE but degraded — " <>
        "a connected runner on an unsupported version reads amber, not emerald"

  attr :class, :string, default: ""

  def status_badge(assigns) do
    status = to_string(assigns.status)
    {derived_tone, dot_pulse?} = status_dot_spec(status)

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:dot_tone, assigns.tone || derived_tone)
      |> assign(:dot_pulse?, dot_pulse?)

    ~H"""
    <%!-- A dot + a toned WORD, not a filled capsule — the pill was the last
         admin-template artifact in every list; terminal-calm statuses read as
         text. The dot carries the semantics for color-blind scanning too. --%>
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium",
      (@tone && tone_text_class(@tone)) || status_word_class(@status),
      @class
    ]}>
      <.status_dot tone={@dot_tone} pulse={@dot_pulse?} />
      {format_status(@status)}
    </span>
    """
  end

  # The word wears its outcome tone (readable-but-quiet 300-tier); routine
  # neutral states stay muted. Offline is the one bucket exception: it's a
  # CAUTION (needs attention), not neutral — amber, one tone for the fact
  # everywhere (summary strip, row status, dashboard posture).
  defp status_word_class("offline"), do: "text-amber-300"
  # Planned (a runbook slot not yet dispatched) is the quietest state — but a
  # status word an operator reads must clear AA, so it wears the neutral muted
  # tier (zinc-400); the de-pilled word, not a sub-AA gray, marks it not-yet.
  # Expired and cancelled are
  # different: in a run/decision log they're OUTCOMES (nobody decided in time;
  # an operator pulled the run back), and an uncolored verdict beside
  # approved/denied/error reads as a bug — they wear amber via the :pending
  # bucket below.
  defp status_word_class("planned"), do: "text-zinc-400"

  defp status_word_class(status) do
    case status_tone(status) do
      :pass -> "text-brand-300"
      :pending -> "text-amber-300"
      :deny -> "text-rose-300"
      :neutral -> "text-zinc-400"
    end
  end

  # The word tone for an EXPLICIT `status_badge` tone override (bypassing the
  # word-derived bucket above) — same 300-tier palette, keyed by the dot tone.
  defp tone_text_class(:brand), do: "text-brand-300"
  defp tone_text_class(:amber), do: "text-amber-300"
  defp tone_text_class(:rose), do: "text-rose-300"
  defp tone_text_class(:neutral), do: "text-zinc-400"

  @doc """
  The coarse semantic bucket for a status string — `:pass | :pending | :deny |
  :neutral`. Used where a caller needs the OUTCOME tone without the full badge
  (e.g. the mobile card's left status spine). The detailed `status_classes`/
  `status_dot` below carry the per-status visual specifics (the running pulse,
  the amber "refused" security-block) that this coarse bucket flattens.
  """
  def status_tone(status) do
    case to_string(status) do
      s
      when s in ~w[success succeeded connected approved published active running sent cancelling] ->
        :pass

      s
      when s in ~w[pending pending_approval queued waiting refused rejected expired cancelled] ->
        :pending

      s
      when s in ~w[failed halted error validation_failed unknown_action timed_out dispatch_failed denied retired] ->
        :deny

      _ ->
        :neutral
    end
  end

  # The badge dot's {tone, pulse?} per status. In-flight runs pulse so they
  # read as "still happening", not done — the one cue that separates
  # sent/running (and a held pending_approval) from a static same-hue dot.
  defp status_dot_spec(s)
       when s in ~w[success succeeded connected approved published trusted enabled],
       do: {:brand, false}

  defp status_dot_spec(s) when s in ~w[active running sent cancelling], do: {:brand, true}

  defp status_dot_spec(s) when s in ~w[pending_approval waiting],
    do: {:amber, true}

  defp status_dot_spec("queued"), do: {:amber, false}
  defp status_dot_spec("refused"), do: {:amber, false}
  defp status_dot_spec("offline"), do: {:amber, false}
  defp status_dot_spec("pending"), do: {:amber, false}
  defp status_dot_spec("rejected"), do: {:amber, false}
  defp status_dot_spec("expired"), do: {:amber, false}
  defp status_dot_spec("cancelled"), do: {:amber, false}
  defp status_dot_spec("denied"), do: {:rose, false}
  defp status_dot_spec("retired"), do: {:rose, false}

  defp status_dot_spec(s)
       when s in ~w[failed halted error validation_failed unknown_action timed_out dispatch_failed],
       do: {:rose, false}

  defp status_dot_spec(_), do: {:neutral, false}

  defp format_status("pending_approval"), do: "awaiting approval"
  defp format_status("validation_failed"), do: "validation failed"
  defp format_status("unknown_action"), do: "unknown action"
  defp format_status("timed_out"), do: "timed out"
  defp format_status("dispatch_failed"), do: "dispatch failed"
  defp format_status("not_run"), do: "not run"
  defp format_status(other), do: other

  @doc """
  The ONE `<details>` disclosure — a bordered box whose summary row toggles a
  bordered body, with the chevron affordance (design-console-ux §6: advanced or
  optional content collapses behind this). `:sm` is the quiet inline helper
  ("Can't scan? Use a setup URI"); `:md` the prominent option block.

  LiveView strips browser-set open state on re-render (design-console-ux §7.6) —
  when the content must stay open across re-renders, own the state
  server-side and pass `open`.

      <.disclosure>
        <:summary>Can't scan? Use a setup URI</:summary>
        …
      </.disclosure>

      <.disclosure size={:md} open={@scoped?}>
        <:summary><span class="font-medium">Key scope</span> <.chip>…</.chip></:summary>
        …
      </.disclosure>
  """
  attr :id, :string, default: nil
  attr :open, :boolean, default: false
  attr :size, :atom, default: :sm, values: [:sm, :md]
  attr :class, :string, default: nil

  attr :summary_click, :any,
    default: nil,
    doc:
      "phx-click fired by the SUMMARY row only (body clicks never toggle) — " <>
        "pair with server-owned `open` when expanding has a side effect (a lazy mint)"

  attr :rest, :global
  slot :summary, required: true
  slot :inner_block, required: true

  def disclosure(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      class={["group/disc rounded-lg bg-zinc-900/40 ring-1 ring-white/[0.08]", @class]}
      {@rest}
    >
      <summary
        phx-click={@summary_click}
        class={[
          "flex cursor-pointer list-none items-center justify-between gap-3 [&::-webkit-details-marker]:hidden",
          disclosure_summary_class(@size)
        ]}
      >
        <span class="flex min-w-0 flex-wrap items-center gap-2">{render_slot(@summary)}</span>
        <.icon
          name="hero-chevron-down"
          class="h-4 w-4 shrink-0 text-zinc-500 transition-transform group-open/disc:rotate-180"
        />
      </summary>
      <div class={["border-t border-zinc-800/70", disclosure_body_class(@size)]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  defp disclosure_summary_class(:sm),
    do: "px-3 py-2 text-xs font-medium text-zinc-400 hover:text-zinc-200"

  defp disclosure_summary_class(:md),
    do: "px-4 py-3 text-sm font-medium text-zinc-200 hover:bg-white/[0.04]"

  defp disclosure_body_class(:sm), do: "p-3"
  defp disclosure_body_class(:md), do: "px-4 pb-4 pt-3"

  @doc """
  The ONE radio choice-card group — a deliberate pick between a few options,
  each a full-card `<label>` (optional meaning-icon disc, title, one-line
  rationale) wrapping an sr-only radio. Selection is NEUTRAL by design
  (design-console-ux: a chosen risky option must never wear the safe brand hue);
  the check icon marks the current pick. Values compare as strings.

      <.choice_cards name="invite[role]" value={@form[:role].value}>
        <:card :for={role <- @roles} value={role} title={Emisar.Auth.role_label(role)}>
          {role_description(role)}
        </:card>
      </.choice_cards>
  """
  attr :name, :string, required: true
  attr :value, :any, required: true, doc: "the currently selected value; compared as strings"
  attr :disabled, :boolean, default: false
  attr :columns, :integer, default: 1, values: [1, 2]
  attr :class, :string, default: nil

  attr :attached_value, :string,
    default: nil,
    doc: "selected value whose dependent panel visually continues its card"

  slot :card, required: true do
    attr :value, :string, required: true
    attr :icon, :string
    attr :title, :string, required: true
  end

  def choice_cards(assigns) do
    ~H"""
    <div class={[choice_cards_grid(@columns), @class]}>
      <label
        :for={card <- @card}
        class={
          choice_card_class(
            to_string(@value) == card.value,
            @disabled,
            to_string(@value) == card.value and @attached_value == card.value
          )
        }
      >
        <input
          type="radio"
          name={@name}
          value={card.value}
          checked={to_string(@value) == card.value}
          disabled={@disabled}
          class="sr-only"
        />
        <span :if={card[:icon]} class={choice_card_icon_class(to_string(@value) == card.value)}>
          <.icon name={card.icon} class="h-4 w-4" />
        </span>
        <span class="min-w-0 flex-1">
          <span class="flex items-center gap-1.5">
            <span class="text-sm font-medium text-zinc-100">{card.title}</span>
            <%!-- Every card shows a pick affordance: the quiet radio ring says
                 "choose one" before any hover; the check marks the current
                 pick. Both stay NEUTRAL (selection never wears a hue). --%>
            <.icon
              :if={to_string(@value) == card.value}
              name="hero-check-circle-solid"
              class="ml-auto h-4 w-4 shrink-0 text-zinc-300"
            />
            <span
              :if={to_string(@value) != card.value}
              class="ml-auto h-4 w-4 shrink-0 rounded-full border border-zinc-700"
            ></span>
          </span>
          <span class="mt-0.5 block text-xs leading-relaxed text-zinc-400">
            {render_slot(card)}
          </span>
        </span>
      </label>
    </div>
    """
  end

  defp choice_cards_grid(1), do: "peer/attached-panel grid grid-cols-1 gap-2"
  defp choice_cards_grid(2), do: "peer/attached-panel grid grid-cols-1 gap-2 sm:grid-cols-2"

  # Neutral-bright when selected — never a semantic safe/warn hue on a
  # selection affordance. focus-within lifts the ring for keyboard users
  # (the radio itself is sr-only).
  defp choice_card_class(selected?, disabled?, attached?) do
    [
      "flex items-start gap-3 p-3 transition-[background-color,border-color,box-shadow]",
      choice_card_frame(selected?, attached?),
      if(disabled?, do: "cursor-not-allowed opacity-70", else: "cursor-pointer")
    ]
    |> Enum.join(" ")
  end

  defp choice_card_frame(_selected?, true) do
    "rounded-t-lg border border-b-0 border-white/25 bg-white/[0.04] " <>
      "focus-within:border-brand-500/70"
  end

  defp choice_card_frame(true, false) do
    "rounded-lg bg-white/[0.04] ring-1 ring-white/25 " <>
      "focus-within:ring-2 focus-within:ring-brand-500/50"
  end

  defp choice_card_frame(false, false) do
    "rounded-lg bg-black/20 ring-1 ring-zinc-800 hover:ring-zinc-700 " <>
      "focus-within:ring-2 focus-within:ring-brand-500/50"
  end

  defp choice_card_icon_class(selected?) do
    "grid h-8 w-8 shrink-0 place-items-center rounded-lg " <>
      if(selected?, do: "bg-zinc-700 text-zinc-100", else: "bg-zinc-800/80 text-zinc-500")
  end

  @doc """
  The ONE enforcement toggle — a two-state `role="switch"` action button:
  solid brand while OFF (the enabling action), rose outline while ON (the
  disabling action). The caller supplies both labels and, via the global
  attrs, `phx-click` and the state-dependent `data-confirm`.

      <.switch
        on={@current_account.settings.require_mfa}
        on_label="Stop enforcing 2FA"
        off_label="Enforce 2FA"
        aria-label="Enforce 2FA account-wide"
        phx-click="toggle_require_mfa"
        data-confirm={...}
      />
  """
  attr :on, :boolean, required: true
  attr :on_label, :string, required: true, doc: "shown while ON — the turn-off action"
  attr :off_label, :string, required: true, doc: "shown while OFF — the turn-on action"
  attr :rest, :global, include: ~w(phx-click data-confirm aria-label)

  def switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@on)}
      class={
        [
          "shrink-0 rounded-lg px-3 py-1.5 text-xs font-semibold",
          if(@on,
            do: "border border-rose-500/40 text-rose-200 hover:bg-rose-500/10",
            # Bordered neutral, not a brand fill: a settings toggle is not the
            # page's primary action (ONE emerald fill per viewport).
            else: "border border-zinc-800 text-zinc-200 hover:bg-zinc-900"
          )
        ]
      }
      {@rest}
    >
      {if @on, do: @on_label, else: @off_label}
    </button>
    """
  end

  @doc """
  The ONE ordered-work list for setup guides and runbook plans. Numbers
  derive from slot order; `marker={:parallel}` replaces them with the shared
  parallel icon when order does not apply. `variant={:guide}` is the compact
  instructional list; `:plan` is the full-width divide-y row grammar.

      <.steps class="mt-3">
        <:step>Create an OAuth web app in your IdP.</:step>
        <:step>Register the redirect URI below.</:step>
      </.steps>
  """
  attr :variant, :atom, default: :guide, values: [:guide, :plan]
  attr :marker, :atom, default: :number, values: [:number, :parallel]
  attr :class, :string, default: nil

  slot :step, required: true do
    attr :boxed, :boolean,
      doc:
        "render THIS row as a self-contained panel — it drops the rail, because a panel already says where the row starts and the rail would only indent its contents"
  end

  def steps(assigns) do
    ~H"""
    <ol class={[steps_list_class(@variant), @class]}>
      <li :for={{step, idx} <- Enum.with_index(@step)} class={steps_row_class(@variant, step[:boxed])}>
        <%!-- `!`, not `not`: a slot that never set the attr reads back nil. --%>
        <span
          :if={!step[:boxed]}
          class={steps_marker_class(@variant)}
          data-steps-marker={@marker}
        >
          <.icon :if={@marker == :parallel} name="hero-arrows-right-left" class="h-3.5 w-3.5" />
          <span :if={@marker == :number}>{steps_marker(@variant, idx)}</span>
        </span>
        <div class={steps_content_class(@variant)}>
          {render_slot(step)}
        </div>
      </li>
    </ol>
    """
  end

  defp steps_list_class(:guide), do: "space-y-3 text-sm leading-relaxed text-zinc-400"
  defp steps_list_class(:plan), do: "divide-y divide-zinc-800/70"

  # A boxed row IS the panel, so the enclosure sits on the row itself — the
  # marker inside it would only be an indent the panel already provides.
  defp steps_row_class(_variant, true),
    do: "my-3 flex items-start rounded-xl border border-dashed border-zinc-800 p-4 sm:p-5"

  # Baseline-aligned: the guide marker is TYPE (a quiet "1."), not a widget,
  # so it sits on the text baseline like any numeral.
  defp steps_row_class(:guide, _boxed), do: "flex items-baseline gap-2.5"
  # No horizontal padding — the plan list sits on the canvas (runbook run
  # page), not inside a panel gutter.
  defp steps_row_class(:plan, _boxed), do: "flex items-start gap-3 py-3"

  # A bare ordered-list numeral — a filled disc per row read as chrome and
  # outweighed the instructions it was numbering.
  defp steps_marker_class(:guide) do
    "w-4 shrink-0 text-right text-xs font-medium tabular-nums text-zinc-400"
  end

  # The mark reads at the size of the row title beside it, which rules the disc
  # out twice over: a disc that small cannot hold a two-digit step (a stage
  # takes 32), and it was chrome the row never asked for — the guide variant
  # dropped its own for that same reason. The box stays 20px so a `32` and a
  # `1` share one column and sit on the title's first line.
  defp steps_marker_class(:plan) do
    "grid h-5 w-5 shrink-0 place-items-center text-sm font-semibold leading-5 tabular-nums text-zinc-500"
  end

  # The plan variant keeps its circled step marker — a run sequence in a dense
  # card row; the guide numeral takes the list period.
  defp steps_marker(:guide, idx), do: "#{idx + 1}."
  defp steps_marker(:plan, idx), do: idx + 1

  defp steps_content_class(:guide), do: "min-w-0 flex-1"
  defp steps_content_class(:plan), do: "min-w-0 flex-1 text-sm"

  @doc """
  The ONE middot meta row — `a · b · c` under a row title (the `list_row`
  `:meta` convention, but also standalone). Segments ride `:seg` slots and
  the separator renders only BETWEEN visible segments, so a conditional
  segment can never leave a dangling or doubled middot — and no call site
  fights HEEx newline-trimming with `{" "}` hacks or the non-idempotent
  trailing `{expr} ·` the formatter loops on.

      <.meta_line class="text-[11px]">
        <:seg mono>{key.key_prefix}…</:seg>
        <:seg>last used{" "}<.local_time id={"key-used-\#{key.id}"} value={key.last_used_at} mode={:relative} /></:seg>
        <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
      </.meta_line>
  """
  attr :class, :any, default: nil

  attr :wrap, :boolean,
    default: false,
    doc:
      "For a line carrying a `<.tooltip>` or other absolutely-positioned child: drop the clamp so the bubble isn't clipped by its overflow, and let the segments wrap instead."

  slot :seg, required: true do
    attr :mono, :boolean,
      doc: "render THIS segment mono — identifiers only, never a timestamp/email"

    attr :truncate, :boolean,
      doc:
        "give THIS segment the line's flexible width and ellipsize it HERE. Marking the prose segment is how a machine id later in the line still reaches the view in full (the whole-line truncate always eats the LAST segment, which is where an id usually sits)."
  end

  def meta_line(assigns) do
    assigns = assign(assigns, :flexible?, Enum.any?(assigns.seg, & &1[:truncate]))

    ~H"""
    <%!-- Mobile wraps to two lines (security meta like "last used" must
         never silently truncate away); sm+ restores the single-line
         truncate. Mirrors list_row's :meta wrapper. Mono is PER SEGMENT — the
         id segment carries it, but a prose segment (a timestamp, an email)
         stays in the reading face; the line as a whole is never mono. Both
         clamps are `overflow: hidden`, so a segment's tooltip bubble is clipped
         away entirely — `wrap` is how such a line opts out (§7.35). --%>
    <%!-- A whole-line truncate has no idea which segment matters: it simply cuts
         from the right, so a trailing slug/hash loses its tail while the prose
         before it survives intact. When a `:seg` asks to `truncate`, the line
         becomes a flex row at sm+ instead — that segment takes the slack and
         ellipsizes, every other segment keeps its full width. Mobile keeps the
         two-line clamp either way. --%>
    <%!-- No `line-clamp-*` on the flexible branch: it is a composite utility that
         also sets `display`, so `sm:line-clamp-none`'s `display: block` and
         `sm:flex` collide at the same breakpoint and Tailwind's source order — not
         this class list — decides the winner. Block won, and the slug wrapped to a
         second line instead of sitting beside the truncated description. On a
         phone the segments simply wrap; `list_row`'s own `:meta` wrapper still
         caps that at two lines. `items-center`, not `items-baseline`: a flex item
         with `overflow: hidden` — which `truncate` sets — synthesizes its baseline
         from its bottom margin edge, so baseline alignment dropped the segments
         after it by a full line. Peer segments share a line-height, so centering
         lands in the same place without that trap. --%>
    <div class={[
      (not @flexible? and not @wrap) && "line-clamp-2 sm:line-clamp-none sm:truncate",
      @flexible? && "sm:flex sm:items-center",
      @class
    ]}>
      <%!-- `!`, never `not`, on a slot attr: an undeclared one is nil, and
           `not nil` is an ArgumentError that only fires once a caller opts in. --%>
      <%!-- The separator and slot GLUE to the tags (§7.48): `whitespace-pre` keeps
           the leading space that survives the flex item's line start, and it keeps
           this template's indentation just as literally — a newline here rendered
           an empty first line box, dropping every meta line 16px below its title
           and growing every row by the same. --%>
      <span
        :for={{seg, idx} <- Enum.with_index(@seg)}
        class={[
          seg[:mono] && "font-mono",
          @flexible? && seg[:truncate] && "sm:min-w-0 sm:truncate",
          @flexible? && !seg[:truncate] && "sm:shrink-0 sm:whitespace-pre"
        ]}
      >{if idx > 0, do: " · "}{render_slot(seg)}</span>
    </div>
    """
  end

  @doc """
  Renders text that may carry markdown-style backtick spans — pack
  descriptions, side-effect notes — with the `` `code` `` parts as inline
  mono instead of leaking literal backticks into the UI. Everything is
  escaped as usual; only the presentation changes. Odd/unbalanced
  backticks degrade to plain text for the trailing segment.

      <.inline_code text={@action.description} />
  """
  attr :text, :string, required: true

  def inline_code(assigns) do
    assigns = assign(assigns, :segments, Enum.with_index(String.split(assigns.text, "`")))

    ~H"""
    <%= for {segment, idx} <- @segments do %>
      <code
        :if={rem(idx, 2) == 1}
        class="rounded bg-zinc-900 px-1 py-0.5 font-mono text-[0.92em] text-zinc-300"
      >
        {segment}
      </code>
      <span :if={rem(idx, 2) == 0}>{segment}</span>
    <% end %>
    """
  end

  @doc """
  One code value with its copy button — a sign-in link, a callback URI, a
  SCIM base URL, or a short command inside a callout. Pass `label` when a setup
  flow needs to map the value to a named field in another product. The preview
  stays on one clipped line while Copy preserves the complete value. The framed
  multi-line snippet is `code_panel`; this is the compact value row.

      <.code_line id="sso-sign-in-link" value={@sign_in_url} class="mt-3" />
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :value, :string, required: true
  attr :copy_label, :string, default: "Copy"
  attr :prompt, :boolean, default: false
  attr :class, :any, default: nil

  def code_line(assigns) do
    ~H"""
    <div class={@class}>
      <p
        :if={@label}
        class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400"
      >
        {@label}
      </p>
      <div class={[
        "flex min-h-9 items-center gap-2 rounded-lg bg-zinc-950/80 px-2.5 py-1 ring-1 ring-zinc-800",
        @label && "mt-1.5"
      ]}>
        <span :if={@prompt} class="select-none font-mono text-xs text-zinc-500">$</span>
        <code
          id={@id}
          phx-no-format
          class="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap font-mono text-xs leading-5 text-zinc-300"
        >{@value}</code>
        <.copy_button text={@value} class="shrink-0">
          {@copy_label}
        </.copy_button>
      </div>
    </div>
    """
  end

  @doc """
  An inline machine identifier with the ONE copy affordance — a hostname, IP,
  request/event id, external id. Renders the value mono beside a compact
  clipboard button that copies the literal value (CSP-safe, via the delegated
  `[data-copy-text]` listener). Every inline mono id uses this instead of a bare
  `<span class="font-mono">` plus a bespoke `copy_button`, so copy looks and
  behaves the same everywhere. The value never free-space-truncates — a machine
  id you can't read in full is useless — it wraps (`break-all`); tune size/color
  through `class`.

      <.copyable_id value={@runner.hostname} />
      <.copyable_id value={@event.request_id} class="text-xs text-zinc-400" />
  """
  attr :value, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def copyable_id(assigns) do
    ~H"""
    <span
      class={["group/copy inline-flex min-w-0 max-w-full items-center gap-1 font-mono", @class]}
      {@rest}
    >
      <%!-- dotted_mono + break-words: a hostname/UUID wraps AFTER a dot or dash
           ("api-iad-02.northstar." / "example"), never sheared mid-token
           ("norths / tar") the way break-all did; the copy button carries the
           literal value, so the <wbr>s never pollute a copy. --%>
      <span class="min-w-0 break-words"><.dotted_mono value={@value} /></span>
      <%!-- Always-visible dim clipboard (not hover-reveal — touch has no hover);
           brightens on hover/focus. The value stays a selectable span, so a
           manual select-copy still works alongside the one-click button. --%>
      <button
        type="button"
        data-copy-text={@value}
        data-copy-label-copied="✓"
        aria-label="Copy"
        title="Copy"
        class="shrink-0 rounded p-0.5 leading-none text-zinc-500 transition hover:text-zinc-200 focus-visible:text-zinc-200"
      >
        <.icon name="hero-clipboard-document" class="h-3.5 w-3.5" />
      </button>
    </span>
    """
  end

  @doc """
  The ONE framed code surface — an eyebrow-labeled header (optional
  `annotation`, optional copy button, `:badge` extras) over a mono `<pre>`.
  Every static code/JSON/argv/snippet block composes this (design-console-ux §1).
  The code rides the `code` ATTR, not a slot, so the formatter can never leak
  indentation into the whitespace-significant `<pre>`. The run-output
  terminal (streamed spans) is the sanctioned hand-rolled exception.

      <.code_panel
        id="run-args"
        label="Arguments"
        annotation={"sha256:" <> sha}
        max_h="max-h-64"
        code={format_json(@action_args)}
      />
      <.code_panel label="Command" annotation="what the runner will execute" prompt code={@argv} />
  """
  attr :code, :string, required: true
  attr :label, :string, required: true
  attr :id, :string, default: nil, doc: "pre id — required with `copy`"
  attr :annotation, :string, default: nil, doc: "right-side header meta"
  attr :copy, :boolean, default: false, doc: "copy button targeting the pre by `id`"
  attr :copy_label, :string, default: "Copy"
  attr :prompt, :boolean, default: false, doc: ~S(render a select-none "$ " shell prompt)
  attr :max_h, :string, default: nil, doc: ~S(scroll clamp on the pre, e.g. "max-h-64")

  attr :wrap, :boolean,
    default: false,
    doc: "wrap long lines instead of scrolling — for prose-y content like an example prompt"

  attr :class, :string, default: nil
  attr :rest, :global
  slot :badge, doc: "header extras next to the label (e.g. a streaming pill)"

  def code_panel(assigns) do
    ~H"""
    <%!-- The island recipe, but with the ARTIFACT edge: a solid zinc-800 ring
         (the install-wizard command-box grammar) instead of the faint
         white/[0.07] surface ring — a code panel usually sits directly on the
         black canvas, where the light ring + a near-black code recess made the
         body blend into the page. --%>
    <div
      class={[
        "overflow-hidden rounded-xl bg-zinc-900/60",
        "shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-zinc-800",
        @class
      ]}
      {@rest}
    >
      <%!-- The label eyebrow is short by design, so it holds its width; the
           annotation cluster is the one that shrinks — its truncate ellipsizes
           a long value (a sha256, an event id) instead of colliding with the
           label or pushing Copy off-viewport on a phone. --%>
      <header class="flex items-center justify-between gap-3 border-b border-zinc-800/70 px-4 py-2">
        <div class="flex shrink-0 items-center gap-2">
          <%!-- The label is a section TITLE (the 16px tier), not a field-key
               eyebrow — a code artifact's header follows the same grammar as
               every sibling panel on the page. --%>
          <h3 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            {@label}
          </h3>
          {render_slot(@badge)}
        </div>
        <div class="flex min-w-0 items-center gap-2">
          <span
            :if={@annotation}
            class="truncate font-mono text-[11px] text-zinc-400"
            title={@annotation}
          >
            {@annotation}
          </span>
          <.copy_button
            :if={@copy}
            target={"##{@id}"}
            class="shrink-0 bg-zinc-800 px-2 text-zinc-200 hover:bg-zinc-700"
          >
            {@copy_label}
          </.copy_button>
        </div>
      </header>
      <pre
        id={@id}
        tabindex={if not @wrap or not is_nil(@max_h), do: "0"}
        aria-label={@label}
        class={[
          "bg-black/40 p-4 font-mono text-xs text-zinc-300 [font-variant-ligatures:none]",
          if(@wrap, do: "whitespace-pre-wrap break-words", else: "overflow-auto"),
          @max_h
        ]}
      ><span :if={@prompt} class="select-none text-zinc-500">$ </span>{@code}</pre>
    </div>
    """
  end

  @doc """
  A card whose body collapses behind a clickable header. Built on `<details>`,
  so it's keyboard-accessible and toggles with no JS; the `CollapsibleSection`
  hook then persists the open/closed choice per `id` in `localStorage`, so it
  sticks across navigations and reloads. Collapsed by default — pass
  `open={true}` to default-expand. The `:summary` slot renders on the right of
  the header and stays visible when collapsed — use it for an at-a-glance
  current value (a `<.chip>`), so a collapsed section still tells you its state.

      <.collapsible_section id="approvals-grant-cap" title="Maximum grant lifetime">
        <:summary><.chip>No cap</.chip></:summary>
        … controls …
      </.collapsible_section>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  attr :class, :string, default: nil
  slot :summary
  slot :inner_block, required: true

  def collapsible_section(assigns) do
    ~H"""
    <details
      id={@id}
      phx-hook="CollapsibleSection"
      data-collapse-key={@id}
      open={@open}
      class={["group/sect border-t border-zinc-800/70", @class]}
    >
      <%!-- CONTENT ON CANVAS: a disclosure LINE on a hairline, not a boxed
           card (the audit Filters-line grammar). The whole row is the toggle;
           the chevron rotates for state; the summary slot rides just left of
           the chevron. --%>
      <summary class="flex cursor-pointer list-none items-center gap-3 py-3.5 transition-colors [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="h-3 w-3 shrink-0 text-zinc-500 transition duration-200 group-hover/sect:text-zinc-300 group-open/sect:rotate-90"
        />
        <h2 class="min-w-0 flex-1 truncate text-sm font-medium text-zinc-300 transition group-hover/sect:text-zinc-100">
          {@title}
        </h2>
        <div class="flex shrink-0 items-center gap-2.5">
          {render_slot(@summary)}
        </div>
      </summary>
      <div class="pb-5 pl-5 pt-1">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  @doc """
  The intro line that sits directly under an index page's title — one place so
  every list page opens the same way (a `<.dashboard_shell>` `:title` carries
  the page name; this carries the explanation under it). The default slot is the
  subtitle (a readable-width lead paragraph); `:actions` right-aligns alongside
  it; `:help` renders a longer "how it works" card below, for pages that need to
  teach the model before the list (Policy). Pass whichever slots the page needs.

      <.page_intro>
        Each <em>(pack, version)</em> has a pinned trusted hash…
      </.page_intro>

      <.page_intro>
        <:help>
          Every action has a <strong>risk tier</strong> from the catalog…
        </:help>
      </.page_intro>
  """
  attr :class, :string, default: nil
  slot :inner_block, doc: "the subtitle lead line (rich inline markup allowed)"
  slot :actions, doc: "right-aligned buttons beside the subtitle"

  def page_intro(assigns) do
    ~H"""
    <div :if={@inner_block != [] or @actions != []} class={["space-y-4", @class]}>
      <div class="flex items-start justify-between gap-4">
        <p :if={@inner_block != []} class="max-w-2xl text-sm leading-relaxed text-zinc-400">
          {render_slot(@inner_block)}
        </p>
        <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  @doc """
  A subtle "read the docs" link from a console page intro to its docs page. Opens
  the public, server-rendered docs in a new tab with an external glyph.

      <.doc_link href="/docs/runners">Runner docs</.doc_link>
  """
  attr :href, :string, required: true
  slot :inner_block, required: true

  def doc_link(assigns) do
    ~H"""
    <.link
      href={@href}
      target="_blank"
      class="inline-flex items-center gap-0.5 whitespace-nowrap font-medium text-brand-400 hover:text-brand-300"
    >
      {render_slot(@inner_block)}<.icon name="hero-arrow-up-right" class="h-3 w-3" />
    </.link>
    """
  end

  @doc """
  A short teaching rail for a list page — "what is this, in plain terms" beside
  the list (the aside of a main+aside grid), ended with a link into the full
  docs. The caller gives it a fixed 22rem track that only splits off at xl, so
  its prose never squeezes; below xl it stacks full-width under the list.

      <.docs_rail title="What's a runner?" doc_href="/docs/runners" doc_label="Runner docs">
        <p>A runner is the small emisar agent on one of your hosts…</p>
      </.docs_rail>
  """
  attr :title, :string, required: true

  attr :doc_href, :string,
    default: nil,
    doc: "omit (with doc_label) when the page intro already links the same docs"

  attr :doc_label, :string, default: nil
  slot :inner_block, required: true

  def docs_rail(assigns) do
    # No column span — the caller's grid gives this a FIXED 22rem track (never a
    # squeezed fraction), and the whole thing stacks full-width below the list on
    # anything narrower than the split. Nothing is hidden; it just reflows.
    ~H"""
    <aside>
      <h3 class="text-sm font-semibold text-zinc-200">{@title}</h3>
      <div class="mt-3 space-y-3 text-sm leading-relaxed text-zinc-400">
        {render_slot(@inner_block)}
      </div>
      <%!-- text-sm on the HOST, not the component: doc_link carries no text-*
           (so it adapts to context), and this <p> would otherwise inherit the
           dashboard's page-base 16px — bigger than the rail's text-sm prose. --%>
      <p :if={@doc_href} class="mt-4 text-sm">
        <.doc_link href={@doc_href}>{@doc_label}</.doc_link>
      </p>
    </aside>
    """
  end

  @doc """
  The bare heading-row above a canvas section — the console's ONE section
  heading (boxed panels are dead, §8.1). A `text-sm` section title, an
  optional inline `<.count_badge>`, an optional `:subtitle` line, and a
  right-aligned `:actions` slot.

      <.section_header title="Pending" count={@pending_metadata.count} count_tone={:amber} />
      <.section_header title="Targeted rulesets">
        <:subtitle>A ruleset replaces the default policy for one runner or group.</:subtitle>
        <:actions><.button phx-click="add_ruleset">Add ruleset</.button></:actions>
      </.section_header>
  """
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :count_tone, :atom, default: :neutral, values: [:amber, :neutral, :brand]
  attr :class, :string, default: nil
  slot :subtitle
  slot :actions

  def section_header(assigns) do
    ~H"""
    <header class={["mb-4 flex flex-wrap items-end justify-between gap-3", @class]}>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h2 class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100">
            {@title}
          </h2>
          <.count_badge count={@count} tone={@count_tone} />
        </div>
        <p :if={@subtitle != []} class="mt-0.5 max-w-xl text-xs text-zinc-400">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Small count pill beside a section title. Renders nothing for a nil/zero count.
  """
  attr :count, :integer, default: nil
  attr :tone, :atom, default: :neutral, values: [:amber, :neutral, :brand]
  attr :class, :string, default: nil

  def count_badge(assigns) do
    ~H"""
    <span
      :if={@count && @count > 0}
      class={[
        "rounded px-1.5 py-0.5 text-xs font-medium tabular-nums",
        count_badge_tone(@tone),
        @class
      ]}
    >
      {@count}
    </span>
    """
  end

  defp count_badge_tone(:amber), do: "bg-amber-500/20 text-amber-200"
  defp count_badge_tone(:neutral), do: "bg-zinc-800 text-zinc-300"
  defp count_badge_tone(:brand), do: "bg-brand-500/20 text-brand-200"

  @doc """
  The uppercase group label that opens a run of grouped `:cards` rows (runners
  by group, agents by owner). Renders the `<li>` the divided list expects, and
  owns the BETWEEN-GROUP rhythm (`pt-8`, dropped for the first group) so every
  grouped list breathes the same. Optional trailing meta — a count — via the
  default slot.

      <.list_group_header label={@group}>{@n} runners total</.list_group_header>
      <.list_group_header label={@owner} />
  """
  attr :label, :string, required: true
  slot :inner_block

  def list_group_header(assigns) do
    ~H"""
    <li class="flex items-baseline gap-2 pb-2 pt-8 first:pt-0">
      <h2 class="text-[11px] font-medium uppercase tracking-wider text-zinc-400">{@label}</h2>
      <span :if={@inner_block != []} class="text-[11px] text-zinc-400">
        {render_slot(@inner_block)}
      </span>
    </li>
    """
  end

  @doc """
  Key-value row for detail panes. `:row` (default) is a label-left /
  value-right flex row; `:grid` emits a bare `<dt>`/`<dd>` pair (no wrapper)
  for a mono, column-aligned readout — drop it inside a
  `<dl class="grid grid-cols-[max-content,1fr] gap-x-3">` so labels and values
  line up across rows (the `:grid` value defaults zinc-300; wrap it in a colored
  span to flag a row, e.g. a changed hash):

      <.kv label="Hostname">{@runner.hostname || "—"}</.kv>

      <dl class="grid grid-cols-[max-content,1fr] gap-x-3 gap-y-0.5 text-[11px]">
        <.kv layout={:grid} label="trusted:">{hash || "— (none yet)"}</.kv>
      </dl>
  """
  attr :label, :string, required: true
  attr :layout, :atom, default: :row, values: [:row, :grid]
  slot :inner_block, required: true

  def kv(%{layout: :grid} = assigns) do
    # No wrapping div: the <dt>/<dd> are direct children of the caller's grid
    # <dl> so its columns align label and value across every row.
    ~H"""
    <dt class="font-mono text-zinc-400">{@label}</dt>
    <dd class="break-all font-mono text-zinc-300">{render_slot(@inner_block)}</dd>
    """
  end

  def kv(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3 py-1">
      <dt class="text-zinc-400">{@label}</dt>
      <dd class="text-right font-medium text-zinc-100">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc """
  Single field cell used inside a horizontal meta strip on detail
  pages (run, approval, runner). Tiny uppercase label above the
  value; truncates on overflow so the strip stays the same height.

      <.meta_strip>
        <.meta_field label="Runner">acme-db-01</.meta_field>
        <.meta_field label="Exit">0</.meta_field>
      </.meta_strip>
  """
  attr :label, :string, required: true

  attr :wrap, :boolean,
    default: false,
    doc:
      "For a long, must-read value (an action id): span the full row on mobile and wrap instead of truncating. The default keeps the strip tidy with a one-line ellipsis."

  slot :inner_block, required: true

  def meta_field(assigns) do
    ~H"""
    <div class={["min-w-0", @wrap && "col-span-2 sm:col-span-1"]}>
      <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">{@label}</div>
      <div class={["mt-1.5 text-[15px] leading-tight", if(@wrap, do: "break-words", else: "truncate")]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Horizontal meta strip wrapper — the bordered rounded box that holds
  `<.meta_field>` key-value cells under page titles on DETAIL pages (a run's
  runner / risk / pack / time). Not a list page's naked posture line (a count
  strip). Pass `cols` for an explicit column
  count at `lg+`; defaults to auto-fitting via `sm:grid-cols-3`.

      <.meta_strip cols={6}>
        <.meta_field label="Runner">acme-db-01</.meta_field>
        ...
      </.meta_strip>
  """
  attr :cols, :integer, default: nil, values: [nil, 3, 4, 5, 6]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def meta_strip(assigns) do
    # Static lookup so Tailwind picks up every variant.
    lg_cols =
      %{
        3 => "lg:grid-cols-3",
        4 => "lg:grid-cols-4",
        5 => "lg:grid-cols-5",
        6 => "lg:grid-cols-6"
      }[assigns.cols] || ""

    assigns = assign(assigns, :lg_cols, lg_cols)

    ~H"""
    <div class={[
      "grid grid-cols-2 gap-3 rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] p-4 text-sm sm:grid-cols-3",
      @lg_cols,
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One `<li>` row for a list section, with the icon-disc + content
  + actions layout used by EnrollmentKeys, Agents, Grants, Runbooks, etc.

      <.list_row icon="hero-key">
        <:title>{key.name}</:title>
        <:meta>{key.key_prefix}… · last used {last_used}</:meta>
        <:actions>
          <button>Revoke</button>
        </:actions>
      </.list_row>

  `chips` slot renders inline pills next to the title.
  """
  attr :icon, :string, default: nil
  attr :icon_tone, :atom, default: :neutral, values: [:neutral, :brand, :amber, :rose]
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  # Island rows keep the px-5 gutter; a CONTENT-ON-CANVAS list passes its own
  # (the run_row precedent) so rows align to the page rail instead.
  attr :padding, :string, default: "px-5 py-4"

  attr :meta_wrap, :boolean,
    default: false,
    doc:
      "Drop the `:meta` slot's mobile clamp — for a meta line carrying a `<.tooltip>`, whose bubble the clamp's overflow would otherwise clip away on a phone."

  slot :leading, doc: "a custom leading element (avatar, connection dot) — replaces the icon disc"
  slot :title, required: true
  slot :chips
  slot :meta
  slot :actions

  slot :body,
    doc:
      "full-width content under the row — an expanded detail or disclosure, " <>
        "which must clear the actions column rather than share the title's measure"

  def list_row(assigns) do
    ~H"""
    <li id={@id} class={[@padding, @class]}>
      <div class="flex flex-wrap items-start gap-4 sm:flex-nowrap">
        <div :if={@leading != []} class="shrink-0">{render_slot(@leading)}</div>
        <span
          :if={@leading == [] && @icon}
          class={["grid h-9 w-9 shrink-0 place-items-center rounded-lg", row_icon_class(@icon_tone)]}
        >
          <.icon name={@icon} class="h-4 w-4" />
        </span>

        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            {render_slot(@title)}
            {render_slot(@chips)}
          </div>
          <%!-- Two lines on mobile (a credential row's "last used" is its
               security signal — never silently truncated away), single-line
               truncate from sm up. --%>
          <div
            :if={@meta != []}
            class={[
              "mt-1 text-xs text-zinc-400",
              !@meta_wrap && "line-clamp-2 sm:line-clamp-none"
            ]}
          >
            {render_slot(@meta)}
          </div>
        </div>

        <%!-- Below sm the actions take their own full-width row under the
             content, so the title — the row's identity — owns the width
             instead of being crushed to a clipped glyph by three buttons. --%>
        <div :if={@actions != []} class="flex w-full shrink-0 items-center gap-2 sm:w-auto">
          {render_slot(@actions)}
        </div>
      </div>

      <div :if={@body != []} class="mt-3">{render_slot(@body)}</div>
    </li>
    """
  end

  defp row_icon_class(:brand), do: "bg-brand-500/15 text-brand-300"
  defp row_icon_class(:amber), do: "bg-amber-500/15 text-amber-300"
  defp row_icon_class(:rose), do: "bg-rose-500/15 text-rose-300"
  defp row_icon_class(:neutral), do: "bg-zinc-900 text-zinc-400"

  @doc """
  Small inline chip — the rounded label that sits next to a row title
  or inside a chips slot. Tones name a MEANING, not a hue: `:neutral`
  (zinc — the default, for identity/metadata labels like "You", a mode,
  the current plan), `:brand` (emerald — a healthy/affirmative state:
  trusted, enabled, online, enrolled), `:amber` (pending/caution), `:rose`
  (denied/danger). With `mono`, renders monospace text; with `upcase`, the
  uppercase-semibold status-tag look (a pack's trust state, a plan's
  "Current").

      <.chip>Current</.chip>
      <.chip tone={:rose}>Suspended</.chip>
      <.chip upcase tone={:brand}>Trusted</.chip>
  """
  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :brand, :amber, :rose]

  attr :mono, :boolean, default: false

  attr :upcase, :boolean,
    default: false,
    doc: "uppercase + semibold weight, for status/label tags"

  attr :icon, :string, default: nil, doc: "optional leading heroicon — renders inline-flex"
  attr :class, :string, default: nil
  attr :rest, :global, doc: "extra attributes (e.g. title for a tooltip)"
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span
      class={[
        "whitespace-nowrap rounded px-1.5 py-0.5 text-[10px]",
        @icon && "inline-flex items-center gap-1",
        if(@upcase, do: "font-semibold uppercase tracking-wider", else: "font-medium"),
        chip_class(@tone),
        @mono && "font-mono",
        @class
      ]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="h-3 w-3" />{render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_class(:brand), do: "bg-brand-500/15 text-brand-200 ring-1 ring-brand-500/30"
  defp chip_class(:amber), do: "bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/30"
  defp chip_class(:rose), do: "bg-rose-500/15 text-rose-200 ring-1 ring-rose-500/30"
  defp chip_class(:neutral), do: "bg-zinc-800/80 text-zinc-300"

  @doc """
  Wraps a trigger element with a styled hover/focus tooltip — a dark bubble
  carrying `text`, for the "why" a control is locked/disabled/limited. The reveal
  is CSS (named `group/tooltip`, so it's safe inside a row that has its own
  `group`); the bubble is right-anchored so it grows leftward and won't clip off a
  right-edge badge. `placement` picks which side it opens on — default `:top`, but
  use `:bottom` for a trigger near the top of the viewport (a title-row control),
  where an upward bubble would clip off-screen.

  The `text` carries load-bearing "why locked/limited" copy, so it's a full WCAG
  1.4.13 tooltip, not a hover-only hint:

    * **Perceivable on touch/keyboard/SR** — the wrapper is a focusable trigger
      (`tabindex="0"`) whose reveal also fires on `focus-within`, and
      `aria-describedby` links it to the `role="tooltip"` bubble, so a tap, `Tab`,
      or screen reader all surface the reason.
    * **Hoverable** — the revealed bubble takes pointer events (with a transparent
      bridge spanning the gap to the trigger), so the pointer can move onto it to
      read or select without the tip vanishing.
    * **Dismissable** — the `Tooltip` hook hides the bubble on `Escape` while
      keeping focus on the trigger, re-arming on the next hover/focus.

  Pass an explicit `id` when the same described tip renders more than once on a
  page (a per-row lock) to keep the trigger + bubble ids unique. An icon-only
  trigger instead passes `aria_label`: it uses the same visual hover/focus bubble
  without ids or a hook, so a responsive component may duplicate the slot safely;
  the accessible name already carries the tooltip text.

  When the reason ends in something the operator must RUN, pass `command` rather
  than naming it mid-sentence: the prose stays, and the shared `code_line` row
  carries the command below it — mono, clipped to one line, with the same Copy
  button the page-level notice gives that same command. Copy works because the
  revealed bubble is pointer-interactive (above) and the clipboard listener is
  delegated at the document, so it reaches a control that only exists on hover.

      <.tooltip text="Role is managed by directory sync — change it in your IdP">
        <.chip icon="hero-lock-closed-mini">Operator</.chip>
      </.tooltip>
      <.tooltip text="Audit export is on the Team plan" placement={:bottom}>…</.tooltip>
      <.tooltip id="runner-version-7" text="Runner v0.19.0 is available…" command="sudo emisar update">
        <.icon name="hero-cloud-arrow-down" class="h-3.5 w-3.5" />
      </.tooltip>
  """
  attr :id, :string, default: nil, doc: "bubble id — override when the same tip repeats on a page"
  attr :text, :string, required: true
  attr :command, :string, default: nil, doc: "a command the reason tells the operator to run"
  attr :aria_label, :string, default: nil, doc: "accessible name for an icon-only trigger"
  attr :placement, :atom, default: :top, values: [:top, :bottom]
  attr :align, :atom, default: :right, values: [:left, :right, :responsive]
  attr :class, :any, default: nil, doc: "classes on the wrapper (e.g. shrink-0)"
  slot :inner_block, required: true

  def tooltip(assigns) do
    tooltip_id =
      cond do
        assigns.id -> assigns.id
        # An icon-only trigger needs no ids — its accessible name already says
        # everything the bubble does. A command is the exception: it lives ONLY
        # in the bubble, so that bubble must stay described and identifiable.
        assigns.aria_label && is_nil(assigns.command) -> nil
        true -> "tooltip-#{:erlang.phash2(assigns.text)}"
      end

    assigns = assign(assigns, :tooltip_id, tooltip_id)

    ~H"""
    <span
      id={@tooltip_id && "#{@tooltip_id}-tt"}
      class={["group/tooltip relative inline-flex", @class]}
      tabindex="0"
      aria-label={@aria_label}
      aria-describedby={@tooltip_id}
      phx-hook={@tooltip_id && "Tooltip"}
    >
      {render_slot(@inner_block)}
      <%!-- Revealed, the bubble is pointer-interactive and a transparent `before`
           bridge closes the gap to the trigger (WCAG 1.4.13 hoverable); hidden, it
           stays pointer-events-none so the invisible bubble can't intercept clicks
           over whatever sits above/below the trigger. --%>
      <span
        id={@tooltip_id}
        role="tooltip"
        data-tooltip-bubble
        class={[
          "pointer-events-none absolute z-30 w-max max-w-xs rounded-lg bg-zinc-800 px-2.5 py-1.5",
          "text-[11px] font-medium leading-snug text-zinc-100 opacity-0 shadow-xl ring-1 ring-white/10",
          "transition-opacity duration-100 group-hover/tooltip:opacity-100 group-focus-within/tooltip:opacity-100",
          "group-hover/tooltip:pointer-events-auto group-focus-within/tooltip:pointer-events-auto",
          "before:absolute before:inset-x-0 before:h-2 before:content-['']",
          if(@placement == :bottom,
            do: "top-full mt-2 before:bottom-full",
            else: "bottom-full mb-2 before:top-full"
          ),
          tooltip_align(@align)
        ]}
      >
        {@text}
        <.code_line :if={@command} id={"#{@tooltip_id}-command"} value={@command} class="mt-2" />
      </span>
    </span>
    """
  end

  defp tooltip_align(:left), do: "left-0"
  defp tooltip_align(:right), do: "right-0"
  defp tooltip_align(:responsive), do: "right-0 sm:left-0 sm:right-auto"

  @doc """
  The value slot of an account setting only some members may change — the
  Team roster's role pattern, generalized.

  A member who may change it gets the CONTROL, which already carries the
  current value (a select's selection, a toggle's verb). A member who may not
  gets that same value as a content-sized locked chip whose tooltip names who
  can change *this* setting. So the value is on the surface for everyone, the
  permission is quiet chrome on the lock rather than a prose tail competing
  with the description, and the slot keeps one box across both states (§7.55).

  `value` is only read on the locked branch; it must be the SHORT current
  value, in the control's own vocabulary ("After 1 hour inactive", "No cap"),
  never a sentence. `who_can_change` states that setting's real requirement —
  they differ, so never flatten them to one sentence.

      <.gated_setting
        id="runner-retention"
        can_change?={Runners.subject_can_manage_inactive_retention?(@current_subject)}
        value={retention_value_label(@retention_hours)}
        who_can_change="Owners and admins with full runner access can change this"
        class="mt-3"
      >
        <form phx-change="set_runner_retention"><.select name="hours" options={…} /></form>
      </.gated_setting>
  """
  attr :id, :string, required: true, doc: "unique on the page — the lock tooltip's id"
  attr :can_change?, :boolean, required: true
  attr :value, :string, required: true, doc: "the short current value, for the locked branch"
  attr :who_can_change, :string, required: true, doc: "this setting's real requirement"
  attr :class, :any, default: nil, doc: "the caller's spacing for the slot"
  slot :inner_block, required: true, doc: "the control, for a member who may change it"

  def gated_setting(assigns) do
    ~H"""
    <div class={@class}>
      <%= if @can_change? do %>
        {render_slot(@inner_block)}
      <% else %>
        <.tooltip id={"#{@id}-lock"} text={@who_can_change}>
          <%!-- Content-sized, never stretched to the control's box: a value
               filling that track reads as the control disabled. --%>
          <.chip icon="hero-lock-closed-mini">{@value}</.chip>
        </.tooltip>
      <% end %>
    </div>
    """
  end

  @doc """
  Inline "back" breadcrumb for detail pages. Renders as a small label
  above the page title slot, so the operator always sees where they
  came from without a separate breadcrumb trail.

      <:title>
        <.back_link navigate={~p"/app/\#{@current_account}/runs"}>Runs</.back_link>
        Run output
      </:title>
  """
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def back_link(assigns) do
    ~H"""
    <%!-- On a phone the crumb takes its OWN quiet line above the entity title
         (the shared row rarely fits both), so the separator slash never
         dangles at a wrap point; sm+ restores the inline "Crumb / Entity"
         breadcrumb at the title's size. --%>
    <span class="flex items-center text-base text-zinc-400 sm:inline-flex sm:text-[length:inherit]">
      <.link
        navigate={@navigate}
        class="font-medium text-zinc-400 hover:text-zinc-200"
      >
        {render_slot(@inner_block)}
      </.link>
      <span class="mx-2 hidden text-zinc-700 sm:inline" aria-hidden="true">/</span>
    </span>
    """
  end

  @doc """
  The title block for a title-less detail page (run, approval, runner, audit,
  SSO connection, runbook editor) — a `<.back_link>` breadcrumb to the parent
  list followed by the entity heading. Goes in the `<.dashboard_shell>`
  `:title` slot, so every detail page opens with the same "where am I / what
  is this" shape and one place owns the breadcrumb + heading grammar.

  Most detail pages are titled by an identifier, so `title` + `mono` render it
  in the ONE mono heading face (a step below the shell's display size — mono
  at display weight reads bulky), and `:meta` carries trailing de-emphasized
  context (version · status, the target host). Never prefix the title with its
  type word ("Approval · …") — the breadcrumb already says where you are. A
  heading that needs custom anatomy (the audit event's outcome dot + dual
  title) uses the default slot instead of `title`.

  The horizontal `<.meta_strip>` stays a sibling in the page body — it lives in
  a different region (the scrolling `<main>`, not the sticky title bar), so it
  can't share this DOM node.

      <:title>
        <.detail_header
          back="Runners"
          navigate={~p"/app/\#{@current_account}/runners"}
          title={@runner.name}
          mono
        />
      </:title>
  """
  attr :navigate, :string, required: true
  attr :back, :string, required: true, doc: "the parent list's breadcrumb label"
  attr :title, :string, default: nil, doc: "the entity heading; nil → the default slot carries it"
  attr :mono, :boolean, default: false, doc: "render `title` in the mono machine-id face"
  slot :meta, doc: "trailing de-emphasized context (version · status, on host)"
  slot :inner_block

  def detail_header(assigns) do
    ~H"""
    <.back_link navigate={@navigate}>{@back}</.back_link><span
      :if={@title}
      class={@mono && "font-mono text-lg tracking-tight sm:text-xl"}
    >{@title}</span>{render_slot(@inner_block)}<span
      :if={@meta != []}
      class={[
        "ml-2 font-normal",
        if(@mono,
          do: "font-mono text-lg tracking-tight text-zinc-400 sm:text-xl",
          else: "text-sm text-zinc-400"
        )
      ]}
    ><%!-- A mono title's trailing context ("on edge-fra-01") speaks the SAME
         face and size as the title — just dimmed to the breadcrumb gray —
         so the line reads as one heading, not a heading plus a footnote. --%>{render_slot(
      @meta
    )}</span>
    """
  end

  @doc """
  Copy-to-clipboard button.

  CSP-safe + works on both LiveView and controller-rendered pages.
  Uses the delegated `[data-copy]` click listener in `assets/js/copy.js`
  (shared by the app + marketing bundles; no inline `onclick` — those get
  stripped by CSP in prod, which is why every Copy button across the
  portal was silently broken).

  Pass exactly one of:
    * `target` — CSS selector of the element whose `.innerText` to copy
    * `text`   — literal string to copy

      <.copy_button target="#install-cmd">Copy</.copy_button>
      <.copy_button text="emk-abc123" class="bg-amber-500/20">Copy key</.copy_button>
  """
  attr :target, :string, default: nil, doc: "CSS selector of element whose innerText to copy"
  attr :text, :string, default: nil, doc: "literal string to copy (alternative to :target)"
  attr :class, :any, default: nil
  attr :label_copied, :string, default: "Copied"
  attr :rest, :global, include: ~w(id)

  slot :inner_block, required: true

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      data-copy={@target}
      data-copy-text={@text}
      data-copy-label-copied={@label_copied}
      class={[
        "rounded bg-zinc-800/80 px-2.5 py-1 text-xs font-medium text-zinc-200 hover:bg-zinc-700",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Confirmation-zone card — a bordered container with title + body + a `<.button>`
  it renders itself from the slot label. `tone` colors it and picks the button
  variant: `:danger` (rose — disable/delete, the default) or `:success` (brand-green
  — enable/restore), so every consequential-action panel reads alike. Used on
  detail pages (runner detail, SSO provider, etc.), stacked under a "Danger zone"
  section header in a `divide-y` list.

  A **destructive** action confirms through OUR styled modal, never the native
  browser dialog: pass `id` + `confirm` (the modal body) + `on_confirm` (the JS
  the modal's Confirm runs) and this renders a self-contained plain
  `<.confirm_dialog>`. A **restorative** action (`tone={:success}`) just fires
  its `phx-click`. For the rare irreversible + high-blast action, wire the button
  to open a TYPED `<.confirm_dialog>` you render yourself (`phx-click={show_confirm_dialog(id)}`).

      <.confirm_zone
        id="disable-runner"
        title="Disable this runner"
        confirm="Removes it from the catalog and rejects future reconnects."
        confirm_label="Disable runner"
        on_confirm={JS.push("disable")}
      >
        <:body>Removes from catalog and rejects future reconnects.</:body>
        Disable runner
      </.confirm_zone>

      <.confirm_zone tone={:success} title="Enable this runner" phx-click="enable">
        <:body>Clears the disabled flag so the host can reconnect.</:body>
        Enable runner
      </.confirm_zone>
  """
  slot :body, required: true
  slot :inner_block, required: true
  attr :title, :string, required: true
  attr :tone, :atom, default: :danger, values: [:danger, :success]
  attr :id, :string, default: nil, doc: "modal id — required with :on_confirm"
  attr :confirm, :string, default: nil, doc: "the modal body — set with :on_confirm"
  attr :confirm_label, :string, default: nil, doc: "the modal's Confirm button text"
  attr :on_confirm, :any, default: nil, doc: "JS the modal's Confirm runs (self-contained)"
  attr :rest, :global

  # CONTENT ON CANVAS — a destructive/restorative action is a hairline row
  # (title · consequence · toned button), NOT a rose-boxed island. The danger
  # lives on the ROSE button + the modal it fires, never a tinted frame.
  def confirm_zone(%{on_confirm: on_confirm} = assigns) when not is_nil(on_confirm) do
    ~H"""
    <div class="flex flex-col gap-3 py-5 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
      <div class="min-w-0">
        <h3 class="text-sm font-medium text-zinc-100">{@title}</h3>
        <p class="mt-1 text-xs leading-relaxed text-zinc-400">{render_slot(@body)}</p>
      </div>
      <.button
        class="shrink-0 self-start sm:self-auto"
        variant={confirm_zone_button_variant(@tone)}
        tone={confirm_zone_button_tone(@tone)}
        size={:md}
        type="button"
        phx-click={open_confirm(@id)}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.button>
    </div>
    <.confirm_dialog
      id={@id}
      title={@title}
      confirm_label={@confirm_label || @title}
      on_confirm={@on_confirm |> close_confirm(@id)}
    >
      <:body>{@confirm}</:body>
    </.confirm_dialog>
    """
  end

  def confirm_zone(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 py-5 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
      <div class="min-w-0">
        <h3 class="text-sm font-medium text-zinc-100">{@title}</h3>
        <p class="mt-1 text-xs leading-relaxed text-zinc-400">{render_slot(@body)}</p>
      </div>
      <.button
        class="shrink-0 self-start sm:self-auto"
        variant={confirm_zone_button_variant(@tone)}
        tone={confirm_zone_button_tone(@tone)}
        size={:md}
        type="button"
        {@rest}
      >
        {render_slot(@inner_block)}
      </.button>
    </div>
    """
  end

  # `:danger` is the rose destructive button; `:success` the brand-green twin for
  # a restorative action (enable) — a filled primary so it reads "do this".
  defp confirm_zone_button_variant(:danger), do: :secondary
  defp confirm_zone_button_variant(:success), do: :primary

  defp confirm_zone_button_tone(:danger), do: :rose
  defp confirm_zone_button_tone(:success), do: :brand

  @doc ~S"""
  Centered, danger-toned confirmation modal with a **typed-confirm**: the
  operator must type `confirm_token` (the member's email, the runner's name, …)
  before the Confirm button enables. Reserve it for IRREVERSIBLE destructive
  actions — removing a member, deleting a runner, revoking a key. Lower-stakes
  reversible actions ("End all sessions", "Suspend") use a plain confirm modal.

  **The typed-confirm is UX friction to prevent accidents, NOT authorization.**
  It only decides whether Confirm *dispatches the event in the UI*; the real gate
  stays server-side in the action's `handle_event` (its `Permissions.gated` /
  context `%Subject{}` check). A crafted event that fires `on_confirm` directly,
  bypassing this modal, is still refused by that gate — keep it that way.

  Gating is LiveView-state (verifiable in a test): the `<.input>` is
  `phx-change="confirm_typed"`, so the page holds the typed value in `@typed`
  (via `EmisarWeb.ConfirmDialog`); the Confirm `<.button>` is
  `disabled={@typed != @confirm_token}`. Once it enables, clicking it or pressing
  Enter in the confirmation input runs the same `on_confirm` command. Open the
  dialog from the trigger with `show_confirm_dialog(id)`; it closes on Cancel,
  Escape, or backdrop click, resetting the typed value each time so a stale entry
  can't pre-enable Confirm.

  `on_confirm` is the JS/event the enabled Confirm runs — build it at the call
  site so the destructive event carries its own value and closes the dialog:

      <.button phx-click={show_confirm_dialog("remove-#{m.id}")}>Remove from team</.button>

      <.confirm_dialog
        id={"remove-#{m.id}"}
        title="Remove from team"
        confirm_label="Remove member"
        confirm_token={m.user.email}
        typed={@typed}
        on_confirm={
          JS.push("remove", value: %{membership_id: m.id}) |> hide_confirm_dialog("remove-#{m.id}")
        }
      >
        <:body>
          Permanently removes <span class="font-medium text-zinc-200">{m.user.email}</span>;
          they lose access immediately and need a fresh invite to return.
        </:body>
      </.confirm_dialog>

  The token, title, and body render escaped through HEEx (IL-16) — they carry
  operator/runner data.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  # Type-to-confirm is reserved for the genuinely catastrophic + irreversible
  # (deleting an account, removing a member). A routine, reversible-by-reissue
  # action (revoking a key that doesn't disconnect anyone) is a plain confirm —
  # `confirm_token={nil}` (the default) drops the typed gate and Confirm is
  # enabled immediately. A non-nil token requires the operator to type it.
  attr :confirm_token, :string, default: nil, doc: "when set, the string the operator must type"
  attr :typed, :string, default: "", doc: "the live-typed value held by the page (@typed)"
  attr :on_confirm, :any, required: true, doc: "JS/event the enabled Confirm dispatches"
  # `:rose` (default) is a DESTRUCTIVE confirm; `:amber` a caution-approve one
  # (trusting a pack's new code fleet-wide) where rose would over-read as danger.
  attr :tone, :atom, default: :rose, values: [:rose, :amber]
  slot :body, required: true

  def confirm_dialog(assigns) do
    # A PLAIN dialog (no token) closes client-side with no `confirm_reset` push,
    # so it needs zero page wiring; a TYPED one resets the page's `@typed` on
    # every close. Cancel / backdrop / Escape all use this.
    close =
      if is_nil(assigns.confirm_token),
        do: close_confirm(assigns.id),
        else: hide_confirm_dialog(assigns.id)

    assigns = assign(assigns, :close_dialog, close)

    ~H"""
    <div
      id={@id}
      class="relative z-50 hidden"
      role="dialog"
      aria-modal="true"
      aria-label={@title}
      phx-hook="DialogFocus"
      phx-window-keydown={@close_dialog}
      phx-key="escape"
    >
      <%!-- Backdrop — clicking it closes the dialog. --%>
      <div
        id={"#{@id}-backdrop"}
        class="fixed inset-0 bg-black/70 backdrop-blur-sm"
        phx-click={@close_dialog}
        aria-hidden="true"
      >
      </div>

      <%!-- Neutral raised surface (the console dropdown recipe) — NOT a
           rose-washed box. Danger reads from the toned icon + the destructive
           button + the copy, never an alarm frame around the whole dialog
           (design-system §8.1: tone the icon, keep the surface + words calm). --%>
      <div class="fixed inset-0 flex items-center justify-center p-4">
        <%!-- focus_wrap contains Tab inside the open dialog — without it, Tab
             walks out into the page dimmed behind the backdrop. --%>
        <.focus_wrap
          id={"#{@id}-wrap"}
          class="w-full max-w-md rounded-xl bg-zinc-900 p-6 shadow-2xl ring-1 ring-white/10"
        >
          <%!-- The header IS a status_note (the shared note grammar): a bare
               rose icon lead, a zinc title, zinc body — one voice with every
               other note in the console. The dialog takes its accessible name
               from `aria-label={@title}` above. --%>
          <.status_note icon="hero-exclamation-triangle" tone={@tone} title={@title} primary>
            {render_slot(@body)}
          </.status_note>

          <%!-- Typed-confirm (only when a token is set): the page's
               "confirm_typed" handler holds this in @typed; the Confirm button
               below is disabled until it equals the token. Server authz is
               unaffected — this is friction only. The token renders through
               HEEx escaped (IL-16) — it's operator data. The input lives in a
               form so `phx-change` serializes it; the enabled Confirm button is
               that form's submitter, so click and Enter run the same action. --%>
          <form
            :if={not is_nil(@confirm_token)}
            id={"#{@id}-form"}
            phx-change="confirm_typed"
            phx-submit={@on_confirm}
            class="mt-5"
          >
            <.label for={"#{@id}-input"} variant={:eyebrow}>
              Type <span class="font-mono text-zinc-200">{@confirm_token}</span> to confirm
            </.label>
            <.input
              id={"#{@id}-input"}
              type="text"
              name="confirm_token"
              value={@typed}
              class="font-mono"
              autocomplete="off"
              phx-debounce="50"
            />
          </form>

          <div class="mt-6 flex items-center justify-end gap-3">
            <.button
              variant={:secondary}
              size={:md}
              type="button"
              phx-click={@close_dialog}
            >
              Cancel
            </.button>
            <%!-- `nil` token → plain confirm, enabled immediately. A blank-STRING
                 token stays disabled (a page-level dialog with no target selected
                 yet — packs' reject). A real token enables only once typed matches. --%>
            <.button
              variant={:secondary}
              tone={@tone}
              size={:md}
              type={if is_nil(@confirm_token), do: "button", else: "submit"}
              form={if is_nil(@confirm_token), do: nil, else: "#{@id}-form"}
              disabled={
                @confirm_token == "" or (not is_nil(@confirm_token) and @typed != @confirm_token)
              }
              phx-click={if is_nil(@confirm_token), do: @on_confirm}
            >
              {@confirm_label}
            </.button>
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  # OPACITY-ONLY fades, never the shared `show/2` (which animates a `transform`):
  # a transformed ancestor becomes the containing block for the dialog's
  # `position: fixed` overlay, so during the animation it positions against the
  # collapsed wrapper (jammed to the page edge) and only snaps centered once the
  # transform clears. Fade the wrapper instead.
  defp fade_dialog_in(js, id) do
    js
    |> JS.show(
      to: "##{id}",
      time: 200,
      transition: {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
    )
    # First focusable = the type-to-confirm input when present, else Cancel —
    # never the destructive Confirm.
    |> JS.focus_first(to: "##{id}")
  end

  defp fade_dialog_out(js, id) do
    JS.hide(js,
      to: "##{id}",
      time: 150,
      transition: {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}
    )
  end

  @doc """
  Opens a PLAIN `<.confirm_dialog>` (no typed token) — pure client-side, no
  server round-trip and no `@typed`/`confirm_reset` wiring on the page. This is
  the drop-in for a `data-confirm`; wire it to the trigger's `phx-click`.
  """
  def open_confirm(js \\ %JS{}, id), do: fade_dialog_in(js, id)

  @doc "Closes a PLAIN `<.confirm_dialog>` — client-side, no push. Cancel / backdrop / Escape / on_confirm."
  def close_confirm(js \\ %JS{}, id), do: fade_dialog_out(js, id)

  @doc """
  A destructive button that fires its action behind OUR styled confirm modal —
  the drop-in for `data-confirm` (a dangerous action must never use the native
  browser confirm). Renders the trigger `<.button>` + a PLAIN `<.confirm_dialog>`
  (no typed token, no page wiring — fully client-side); on confirm it runs
  `on_confirm` and closes. For the rare irreversible + high-blast-radius action
  (delete runner, remove member, revoke agent key, reject pack), reach for the
  typed `<.confirm_dialog>` directly instead (design-console-ux §5).

      <.confirm_button
        id={"disable-runner"}
        title="Disable this runner?"
        confirm_label="Disable runner"
        icon="hero-no-symbol"
        on_confirm={JS.push("disable")}
      >
        <:body>Stops new dispatches; in-flight runs finish. Re-enable any time.</:body>
        Disable
      </.confirm_button>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :on_confirm, :any, required: true, doc: "JS for the action; the close is appended for you"
  attr :variant, :atom, default: :secondary
  # `tone` colors the TRIGGER — `:rose` (destructive, default), `:amber` (a
  # caution-approve like pack trust), or `:neutral` (a low-key action the page
  # deliberately doesn't shout — suspend, rotate). The MODAL's Confirm button is
  # ALWAYS toned (rose, or amber) so it can never look identical to Cancel — a
  # neutral trigger still gets a rose confirm; the confirmation moment is where
  # the consequence is emphasized.
  attr :tone, :atom, default: :rose, values: [:rose, :amber, :neutral]
  attr :size, :atom, default: :md
  attr :icon, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(disabled),
    doc: "trigger passthrough — phx-disable-with, aria-label, disabled, :if"

  slot :body, required: true, doc: "the consequence copy, shown in the modal"
  slot :inner_block, required: true, doc: "the trigger label"

  def confirm_button(assigns) do
    assigns = assign(assigns, :modal_tone, if(assigns.tone == :amber, do: :amber, else: :rose))

    ~H"""
    <.button
      variant={@variant}
      tone={@tone}
      size={@size}
      icon={@icon}
      class={@class}
      type="button"
      phx-click={open_confirm(@id)}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.button>
    <.confirm_dialog
      id={@id}
      title={@title}
      confirm_label={@confirm_label}
      tone={@modal_tone}
      on_confirm={@on_confirm |> close_confirm(@id)}
    >
      <:body>{render_slot(@body)}</:body>
    </.confirm_dialog>
    """
  end

  @doc """
  Opens a TYPED `<.confirm_dialog>` by id — reveals it, resets the page's typed
  value (so a prior entry can't pre-enable Confirm), and focuses the
  type-to-confirm input. Wire it to the trigger's `phx-click`.
  """
  def show_confirm_dialog(js \\ %JS{}, id),
    do: js |> JS.push("confirm_reset") |> fade_dialog_in(id)

  @doc """
  Closes a TYPED `<.confirm_dialog>` by id and resets the page's typed value.
  Used by Cancel, the backdrop, and Escape.
  """
  def hide_confirm_dialog(js \\ %JS{}, id),
    do: js |> fade_dialog_out(id) |> JS.push("confirm_reset")

  @doc """
  Empty-state panel: a centered icon + headline + body + optional CTA.
  `:boxed` (the default) is the dashed-border placeholder for a whole empty
  page / table / section — the box anchors the content so an empty area reads
  as an intentional placeholder, not a void. `:bare` is the naked, compact form
  for an empty a SUB-SECTION already frames (a dashboard pillar's zero state, a
  runner-detail column) where a box would be competing chrome. `:hint` is the
  compact dashed body-first placeholder ("No overrides. …").

      <.empty_state icon="hero-cpu-chip" title="No runners yet">
        Mint an enrollment key and run the installer on a host.
        <:cta navigate={~p"/app/\#{@current_account}/runners/keys"}>New enrollment key</:cta>
      </.empty_state>

      <.empty_state variant={:hint}>No overrides. The tier defaults decide.</.empty_state>
  """
  attr :icon, :string, default: nil
  attr :title, :string, default: nil
  attr :variant, :atom, default: :boxed, values: [:boxed, :bare, :hint]
  attr :tone, :atom, default: :zinc, values: [:zinc, :danger]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  slot :cta do
    attr :navigate, :string
    attr :href, :string
  end

  def empty_state(assigns) do
    ~H"""
    <div class={[empty_state_wrapper(@variant), @class]}>
      <.icon :if={@icon} name={@icon} class={empty_state_icon(@variant, @tone)} />
      <h2 :if={@title} class={empty_state_title(@variant, @tone)}>{@title}</h2>
      <p class={empty_state_body(@variant)}>{render_slot(@inner_block)}</p>

      <%= for cta <- @cta do %>
        <.link navigate={cta[:navigate]} href={cta[:href]} class={empty_state_cta(@variant)}>
          {render_slot(cta)} <span aria-hidden="true">→</span>
        </.link>
      <% end %>
    </div>
    """
  end

  # `boxed` — the dashed-border placeholder for a whole page / table / section
  # that's empty; the box anchors the icon+title+body so the empty content area
  # reads as an intentional placeholder, not a naked void. `bare` — naked +
  # compact, for an empty a SUB-SECTION already frames (a dashboard pillar's
  # zero state, a runner-detail column) where a box would be competing chrome.
  defp empty_state_wrapper(:boxed),
    do: "rounded-xl border border-dashed border-zinc-800 bg-zinc-950/40 p-12 text-center"

  defp empty_state_wrapper(:bare), do: "mx-auto max-w-md text-center"

  defp empty_state_wrapper(:hint),
    do: "rounded-lg border border-dashed border-zinc-800 p-6 text-center"

  defp empty_state_icon(:boxed, tone), do: "mx-auto h-10 w-10 " <> empty_state_icon_color(tone)
  defp empty_state_icon(:bare, tone), do: "mx-auto h-8 w-8 " <> empty_state_icon_color(tone)
  defp empty_state_icon(:hint, tone), do: "mx-auto h-6 w-6 " <> empty_state_icon_color(tone)

  defp empty_state_icon_color(:zinc), do: "text-zinc-700"
  defp empty_state_icon_color(:danger), do: "text-rose-400/70"

  defp empty_state_title(:boxed, tone),
    do: "mt-4 text-base font-semibold " <> empty_state_title_color(:boxed, tone)

  defp empty_state_title(:bare, tone),
    do: "mt-3 text-sm font-medium " <> empty_state_title_color(:bare, tone)

  defp empty_state_title(:hint, tone),
    do: "mb-1 text-sm " <> empty_state_title_color(:hint, tone)

  defp empty_state_title_color(:boxed, :zinc), do: "text-zinc-200"
  defp empty_state_title_color(:bare, :zinc), do: "text-zinc-300"
  defp empty_state_title_color(:hint, :zinc), do: "text-zinc-300"
  defp empty_state_title_color(_variant, :danger), do: "text-rose-200"

  # `mt-4` gives the headline room to breathe from the body; `mx-auto max-w-lg`
  # caps the measure so a paragraph reads at a comfortable line length instead
  # of stretching the full width of the placeholder box.
  defp empty_state_body(:boxed), do: "mx-auto mt-4 max-w-lg text-sm text-zinc-400"
  defp empty_state_body(:bare), do: "mt-1 text-xs leading-relaxed text-zinc-400"
  defp empty_state_body(:hint), do: "text-xs leading-relaxed text-zinc-400"

  defp empty_state_cta(:boxed) do
    "mt-6 inline-flex items-center gap-2 rounded-lg bg-brand-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-brand-400"
  end

  # A hint placeholder points at the control that creates content, so its
  # CTA reuses the bare treatment.
  defp empty_state_cta(:hint), do: empty_state_cta(:bare)

  defp empty_state_cta(:bare) do
    "mt-4 inline-flex items-center gap-2 text-sm font-medium text-brand-400 hover:text-brand-300"
  end

  @doc """
  The output text of a run progress event — the runner writes the chunk
  into `payload["chunk"]`. Non-chunk events (transitions, errors) render
  as empty.
  """
  def event_chunk(%{payload: %{"chunk" => chunk}}) when is_binary(chunk), do: chunk
  def event_chunk(_), do: ""

  @doc """
  The ONE "reveal once" amber box for freshly-minted credentials — runner
  keys, SIEM export tokens, SCIM bearers, MFA recovery codes. Warns the
  operator the value won't be shown again. Pass exactly one of `secret`
  (a single value with its copy button) or `codes` (a list rendered as
  per-code copy cells + "Copy all" + an optional "Download .txt" when
  `download_name` is set). `variant={:banner}` is the standalone
  top-of-page box; `:card` sits inside a page section. `on_dismiss` adds
  the X; an acknowledgement control ("I've saved them") rides the
  `:actions` slot instead.

      <.secret_reveal
        :if={@new_secret}
        title="Copy this enrollment key now — it will not be shown again."
        secret={@new_secret}
        on_dismiss="dismiss_secret"
      >
        Treat it like a password. Anyone with this key can register a
        runner under your account.

        <:install_command>
          curl -sSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY={@new_secret} bash
        </:install_command>
      </.secret_reveal>

      <.secret_reveal
        id="mfa-recovery-codes"
        variant={:card}
        title="Save your recovery codes"
        codes={@mfa_recovery_codes}
        download_name="emisar-recovery-codes.txt"
      >
        Each code works once if you can't reach your authenticator.
        <:actions>
          <.button variant={:secondary} size={:sm} phx-click="dismiss_recovery_codes">
            I've saved them
          </.button>
        </:actions>
      </.secret_reveal>
  """
  attr :id, :string, default: "reveal-secret"
  attr :title, :string, required: true
  attr :secret, :string, default: nil
  attr :codes, :list, default: nil, doc: "reveal-once code list (alternative to :secret)"
  attr :download_name, :string, default: nil, doc: "codes mode: offer the set as a .txt file"
  attr :on_dismiss, :string, default: nil
  attr :variant, :atom, default: :banner, values: [:banner, :card]
  slot :inner_block, required: true
  slot :actions, doc: "acknowledgement controls, rendered in the copy-button row"

  slot :install_command do
    attr :label, :string
  end

  def secret_reveal(assigns) do
    ~H"""
    <div id={@id} class={secret_reveal_box(@variant)}>
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <.icon name="hero-key" class="h-4 w-4 shrink-0 text-amber-300" />
            <h2 :if={@variant == :banner} class="text-sm font-semibold text-amber-100">{@title}</h2>
            <h3 :if={@variant == :card} class="text-sm font-semibold text-amber-100">{@title}</h3>
          </div>
          <p class="mt-1.5 text-sm leading-relaxed text-zinc-400">{render_slot(@inner_block)}</p>

          <%!-- Same copy pattern as the dashboard install reveal:
               grab text from the visible `<pre>` instead of
               interpolating into a JS string literal (safer + escape-
               proof), and flip the label to "Copied" for 1.5s as
               visible click feedback. --%>
          <div
            :if={@secret}
            class="mt-4 flex items-center gap-2 rounded-lg bg-black/60 p-3 ring-1 ring-zinc-800"
          >
            <pre
              id={"#{@id}-secret"}
              class="flex-1 whitespace-pre-wrap break-all font-mono text-xs text-zinc-100"
            >{@secret}</pre>
            <.copy_button
              target={"##{@id}-secret"}
              class="bg-brand-500/20 px-2 text-brand-200 hover:bg-brand-500/30 font-semibold"
            >
              Copy
            </.copy_button>
          </div>

          <%!-- Each cell IS a copy button, so one code can be grabbed
               without selecting text; "Copy all" carries the joined set
               as a data-copy-text literal (no hidden blob element). --%>
          <ul :if={@codes} class="mt-3 space-y-1.5">
            <li :for={code <- @codes}>
              <button
                type="button"
                data-copy-text={code}
                data-copy-label-copied="Copied!"
                title="Click to copy this code"
                class="block w-full select-all rounded-md border border-zinc-700 bg-black/60 px-3 py-2 text-left font-mono text-sm tracking-wide text-zinc-100 hover:border-zinc-600 hover:bg-black/80"
              >
                {code}
              </button>
            </li>
          </ul>

          <%= for {cmd, idx} <- Enum.with_index(@install_command) do %>
            <div class="mt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                {cmd[:label] || "Install on a host"}
              </h3>
              <div class="mt-2 flex items-start gap-2 rounded-lg bg-black/60 p-3 ring-1 ring-zinc-800">
                <pre
                  id={"#{@id}-install-#{idx}"}
                  class="flex-1 whitespace-pre-wrap break-all font-mono text-xs text-zinc-300"
                >{render_slot(cmd)}</pre>
                <.copy_button
                  target={"##{@id}-install-#{idx}"}
                  class="shrink-0 self-start bg-brand-500/20 px-2 text-brand-200 hover:bg-brand-500/30 font-semibold"
                >
                  Copy
                </.copy_button>
              </div>
            </div>
          <% end %>

          <div :if={@codes || @actions != []} class="mt-4 flex flex-wrap items-center gap-3">
            <button
              :if={@codes}
              type="button"
              data-copy-text={Enum.join(@codes, "\n")}
              data-copy-label-copied="Copied!"
              class="rounded-lg bg-brand-500/20 px-3 py-1.5 text-xs font-semibold text-brand-200 hover:bg-brand-500/30"
            >
              Copy all
            </button>
            <%!-- A real file beats the volatile clipboard for a credential
                 the operator must keep — clipboards get overwritten. --%>
            <a
              :if={@codes && @download_name}
              href={"data:text/plain;charset=utf-8," <> URI.encode(Enum.join(@codes, "\n"))}
              download={@download_name}
              class="rounded-lg bg-zinc-800 px-3 py-1.5 text-xs font-semibold text-zinc-200 hover:bg-zinc-700"
            >
              Download .txt
            </a>
            {render_slot(@actions)}
          </div>
        </div>

        <button
          :if={@on_dismiss}
          phx-click={@on_dismiss}
          class="rounded-lg p-1 text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200"
          aria-label="Dismiss"
        >
          <.icon name="hero-x-mark" class="h-5 w-5" />
        </button>
      </div>
    </div>
    """
  end

  # Neutral surface with an amber border + key-icon title as the "ephemeral,
  # copy it now" accent — not a full amber wash, which read as a heavy amber
  # block of nested dark boxes (esp. inside a neutral panel like SIEM export).
  defp secret_reveal_box(:banner) do
    "mb-6 rounded-xl bg-zinc-900/60 p-6 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-amber-500/40"
  end

  defp secret_reveal_box(:card) do
    "rounded-xl bg-zinc-900/60 p-4 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-amber-500/40"
  end

  @doc """
  Anchor for outbound links — opens in a new tab with the standard
  `noopener noreferrer` rel pair so the new window can't navigate the
  opener (window.opener tabnabbing). Renders the inner block followed
  by a small arrow-top-right icon so the user sees they're leaving
  the site before clicking. Optional `class` to override the default.

      <.external_link href="https://github.com/...">GitHub repo</.external_link>
      <.external_link href={url} class="text-brand-300 hover:text-brand-200">
        SECURITY.md
      </.external_link>
  """
  attr :href, :string, required: true
  attr :class, :string, default: "text-brand-300 hover:text-brand-200"
  attr :rest, :global
  slot :inner_block, required: true

  def external_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class={["inline-flex items-center gap-1", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
    </a>
    """
  end

  attr :items, :list,
    required: true,
    doc: "list of {label, path}; the last item is the current page (its path may be nil)"

  @doc """
  A visible breadcrumb trail for deep pages — the on-page companion to the
  BreadcrumbList JSON-LD. Chevron-separated, the current page non-linked and
  marked aria-current.
  """
  def breadcrumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class="text-sm">
      <ol class="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-zinc-400">
        <%= for {{label, path}, index} <- Enum.with_index(@items) do %>
          <li class="flex items-center gap-x-1.5">
            <.icon :if={index > 0} name="hero-chevron-right" class="h-3 w-3 text-zinc-700" />
            <.link :if={path} navigate={path} class="transition hover:text-zinc-300">{label}</.link>
            <span :if={is_nil(path)} class="text-zinc-300" aria-current="page">{label}</span>
          </li>
        <% end %>
      </ol>
    </nav>
    """
  end

  @doc """
  A hairline at a decision point — the instant a request is checked at the gate.
  The static track always renders; `animate` adds a single brand sweep that
  honors `prefers-reduced-motion` (the sweep ends off-screen, so opted-out
  visitors never see it). `state` colors it to a policy outcome.

      <.scan_line />
      <.scan_line animate state={:pass} />
  """
  attr :state, :atom, default: :pass, values: [:pass, :pending, :deny, :neutral]
  attr :animate, :boolean, default: false

  attr :loop, :boolean,
    default: false,
    doc: "periodic re-scan (long hold between) vs a single sweep"

  attr :class, :string, default: nil

  def scan_line(assigns) do
    ~H"""
    <div class={["relative h-px w-full overflow-hidden", @class]} aria-hidden="true">
      <div class={[
        "h-px w-full bg-gradient-to-r from-transparent to-transparent",
        scan_via_class(@state)
      ]}>
      </div>
      <div
        :if={@animate}
        class={[
          if(@loop, do: "scan-sweep-loop", else: "scan-sweep"),
          "absolute inset-y-0 left-0 w-1/4 bg-gradient-to-r from-transparent to-transparent blur-[1px]",
          scan_sweep_via_class(@state)
        ]}
      >
      </div>
    </div>
    """
  end

  defp scan_via_class(:pass), do: "via-brand-500/50"
  defp scan_via_class(:pending), do: "via-amber-500/50"
  defp scan_via_class(:deny), do: "via-rose-500/50"
  defp scan_via_class(:neutral), do: "via-zinc-700/60"

  defp scan_sweep_via_class(:pass), do: "via-brand-400/80"
  defp scan_sweep_via_class(:pending), do: "via-amber-400/80"
  defp scan_sweep_via_class(:deny), do: "via-rose-400/80"
  defp scan_sweep_via_class(:neutral), do: "via-zinc-400/70"

  @doc """
  A policy-outcome chip — what the gate decided. `:pass` (brand-green), `:pending`
  (amber — an approval is required), `:deny` (rose). A thin semantic wrapper
  over `<.chip>` so every comparison row, pipeline step, and demo reads the
  same; `label` overrides the default outcome word.

      <.state_chip state={:pass} />
      <.state_chip state={:pending} label="Approval" />
  """
  attr :state, :atom, required: true, values: [:pass, :pending, :deny]
  attr :label, :string, default: nil, doc: "overrides the default outcome word"
  attr :class, :string, default: nil
  attr :rest, :global

  def state_chip(assigns) do
    ~H"""
    <.chip tone={state_tone(@state)} icon={state_icon(@state)} upcase class={@class} {@rest}>
      {@label || state_label(@state)}
    </.chip>
    """
  end

  defp state_tone(:pass), do: :brand
  defp state_tone(:pending), do: :amber
  defp state_tone(:deny), do: :rose

  defp state_icon(:pass), do: "hero-check-circle"
  defp state_icon(:pending), do: "hero-clock"
  defp state_icon(:deny), do: "hero-x-circle"

  defp state_label(:pass), do: "Allowed"
  defp state_label(:pending), do: "Approval"
  defp state_label(:deny), do: "Denied"
end
