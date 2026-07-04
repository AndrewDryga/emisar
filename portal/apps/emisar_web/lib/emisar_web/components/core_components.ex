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

  alias EmisarWeb.TimeHelpers
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
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

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
      |> assign(:close_ms, if(assigns.kind == :info, do: 5000, else: 7000))

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_close && "FlashAutoClose"}
      data-close-ms={@auto_close && @close_ms}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 sm:w-96 overflow-hidden rounded-xl p-4 pr-10 ring-1 backdrop-blur shadow-lg cursor-pointer",
        @kind == :info && "bg-brand-950/80 text-brand-100 ring-brand-500/40",
        @kind == :error && "bg-rose-950/80 text-rose-100 ring-rose-500/40"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-2 text-sm font-semibold">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
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
          @kind == :error && "bg-rose-400/70"
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
        kind={:error}
        title={gettext("Connection lost")}
        auto_close={false}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Trying to reconnect…")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Server didn't respond")}
        auto_close={false}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Recovering…")}
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
             associated (console-ux — one create-flow footer). A single
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

  `variant` is STRUCTURE (console-ux §2): `:primary` (filled, the default),
  `:secondary` (bordered), `:ghost` (text-only). `tone` is the hue atom that
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
      <.button variant={:ghost} tone={:rose} phx-click="remove">Remove</.button>
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

  # Ghost: a text-only button tinted by tone, for low-prominence inline
  # actions (remove, revoke, suspend, restore).
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
        "rounded-md p-1 text-zinc-500 transition-colors hover:bg-zinc-900 disabled:opacity-30 disabled:hover:bg-transparent",
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
  isn't fighting Tailwind utility precedence).

  ## Example

      <.dropdown summary_class="rounded px-2 py-1 ring-1 ring-zinc-800" panel_class="z-10 mt-2 w-56 p-1 text-xs shadow-xl">
        <:trigger>Actions <span class="group-open:hidden">▾</span></:trigger>
        <.menu_item phx-click="edit">Edit</.menu_item>
        <.menu_item tone={:rose} phx-click="remove">Remove</.menu_item>
      </.dropdown>
  """
  attr :align, :atom, default: :right, values: [:left, :right, :stretch]
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
        "absolute rounded-lg bg-zinc-900 shadow-xl shadow-black/60 ring-1 ring-white/10",
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

  # Tone mirrors button_variant("ghost", tone) — same hover tints, so a menu row
  # and an inline ghost button of the same tone are visually identical.
  defp menu_item_tone(:rose), do: "text-rose-300 hover:bg-rose-500/10"
  defp menu_item_tone(:amber), do: "text-amber-300 hover:bg-amber-500/10"
  defp menu_item_tone(:brand), do: "text-brand-300 hover:bg-brand-500/10"
  defp menu_item_tone(:neutral), do: "text-zinc-300 hover:bg-zinc-900"

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
      <.label for={@id} variant={@label_variant}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[
          "block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
          input_size(@size),
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          input_ring(@errors, @tone)
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
          "block w-full rounded-lg border-0 bg-zinc-900 text-zinc-100",
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
  defp input_size(:compact), do: "mt-1 px-2 py-1.5 text-sm"
  defp input_size(_default), do: "mt-2 px-3 py-2.5 text-sm"

  @doc """
  iPhone-style one-box-per-character code entry, driven by the `CodeInput` JS
  hook. The boxes are client-owned and aggregate into a hidden `name` field the
  form submits, so the group carries `phx-update="ignore"` — a LiveView
  re-render (a flash, an expiry countdown) can't wipe what was typed. `numeric`
  switches the filter + `inputmode` to digits-only (TOTP, email step-up); the
  default is the alphanumeric sign-in-code alphabet. An `error` renders inline
  below the boxes (outside the ignored group, so it updates) — a rejected code
  is shown right at the input, never as a far-off flash.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true, doc: "the hidden field the aggregate posts as"
  attr :label, :string, required: true
  attr :length, :integer, default: 6
  attr :numeric, :boolean, default: false
  attr :error, :string, default: nil, doc: "a validation error, rendered inline below the boxes"

  def code_input(assigns) do
    ~H"""
    <div>
      <div id={@id} phx-hook="CodeInput" phx-update="ignore" data-numeric={to_string(@numeric)}>
        <.label for={"#{@id}-1"}>{@label}</.label>
        <div class="mt-2 flex justify-between gap-2 sm:gap-2.5">
          <input
            :for={i <- 1..@length}
            id={"#{@id}-#{i}"}
            data-box
            type="text"
            inputmode={if @numeric, do: "numeric", else: "text"}
            autocapitalize={if @numeric, do: "off", else: "characters"}
            autocomplete={i == 1 && "one-time-code"}
            maxlength="1"
            aria-label={"Character #{i} of #{@length}"}
            class={[
              "h-14 w-full min-w-0 rounded-lg border border-zinc-700 bg-zinc-950 text-center",
              "text-xl font-semibold tracking-widest text-zinc-100 shadow-sm outline-none transition",
              "focus:border-brand-500 focus:ring-2 focus:ring-brand-500/30",
              not @numeric && "uppercase"
            ]}
          />
        </div>
        <input type="hidden" name={@name} data-code />
      </div>
      <.error :if={@error}>{@error}</.error>
    </div>
    """
  end

  @doc """
  Renders a `<select>` whose options carry their own `disabled`/`selected` —
  the cases `Phoenix.HTML.Form.options_for_select/2` (and thus `input/1`'s
  `type="select"`) can't express. Each option is a map
  `%{value:, label:, disabled:, selected:}`. For a plain single-value picker
  bound to a form field, reach for `<.input type="select">` instead; this is
  for per-option control (a disabled "already taken" target, a tier floor) and
  multi-selects with computed per-option selection.

  Styling mirrors `input/1`'s select branch so the two read identically; the
  optional rose ring renders when `errors` is non-empty. Labels and values
  render escaped through HEEx (IL-16) — option text includes account data.
  """
  attr :id, :any, default: nil
  attr :name, :any, required: true
  attr :label, :string, default: nil
  attr :label_variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :prompt, :string, default: nil, doc: "a leading empty-value option"
  attr :prompt_selected, :boolean, default: false, doc: "marks the prompt option selected"
  attr :multiple, :boolean, default: false
  attr :errors, :list, default: []

  attr :options, :list,
    required: true,
    doc: "option maps: %{value:, label:, disabled:, selected:}"

  attr :rest, :global, include: ~w(disabled size form)

  def select(assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id} variant={@label_variant}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          @errors == [] && "ring-zinc-800 focus:ring-brand-500",
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500"
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="" selected={@prompt_selected}>{@prompt}</option>
        <option
          :for={option <- @options}
          value={option.value}
          disabled={option.disabled}
          selected={option.selected}
        >
          {option.label}
        </option>
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
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

      <.checkbox name="agree" checked={@agreed?} phx-click="toggle" label="I agree" />
      <.checkbox name="x[]" value={id} checked={id in @selected}>
        <span class="truncate">{name}</span>
      </.checkbox>
  """
  attr :checked, :boolean, default: false
  attr :label, :string, default: nil

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
        class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-brand-500 focus:ring-2 focus:ring-brand-500/40 focus:ring-offset-0 disabled:opacity-50"
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
  repeating list ("+ Add step"), so a long list doesn't scroll back to a
  header button. The header's own Add stays as the secondary access.

      <.add_row label="Add step" phx-click="add_action_step" />
  """
  attr :label, :string, required: true
  attr :rest, :global

  def add_row(assigns) do
    ~H"""
    <button
      type="button"
      class="flex w-full items-center justify-center gap-2 rounded-lg border border-dashed border-zinc-800 px-4 py-3 text-xs font-medium text-zinc-400 transition hover:border-zinc-700 hover:bg-white/[0.04] hover:text-zinc-200"
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
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-2 flex items-center gap-1.5 text-sm text-rose-400">
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  The ONE tinted callout — leading icon, optional bold `title`, the message
  (default slot), and an optional right-aligned `:action`. Every console
  banner, warning box, and heads-up renders through this, or through a thin
  domain wrapper that only maps domain state → tone/copy (`<.offline_notice>`,
  `<.subscription_banner>`) — never a fresh class table (console-ux §1). The
  message renders escaped through HEEx (IL-16).

  Tones are the house hue atoms (console-ux §2), meaning assigned at the call
  site: `:brand` informational/affirmative, `:amber` caution/pending, `:rose`
  danger/error, `:neutral` quiet note. Variants: `:boxed` (default) is the
  rounded bordered box; `:strip` is the flush full-width row with a bottom
  hairline (shell nudges, in-card warning strips). Pass `navigate` to make the
  whole callout a link — the `:action` then renders as static text inside the
  link (no nested interactive element).

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
  attr :variant, :atom, default: :boxed, values: [:boxed, :strip]
  attr :title, :string, default: nil
  attr :icon, :any, default: nil, doc: "heroicon override; `false` renders no icon"
  attr :navigate, :any, default: nil, doc: "makes the whole callout a link"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block, required: true
  slot :action, doc: "right-aligned action — a button/link, or static text under `navigate`"

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
    <.icon
      :if={@icon != false}
      name={@icon || callout_icon(@tone)}
      class={callout_icon_class(@variant)}
    />
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

  defp callout_frame(:boxed),
    do: "flex flex-wrap items-start gap-3 rounded-lg border px-4 py-3 text-sm sm:flex-nowrap"

  defp callout_frame(:strip),
    do: "flex flex-wrap items-center gap-3 border-b px-4 py-2.5 text-sm sm:px-6"

  # The icon top-nudge only makes sense against the boxed variant's items-start.
  defp callout_icon_class(:boxed), do: "mt-0.5 h-4 w-4 flex-none"
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

  @doc """
  Banner shown above a billing surface when the account's Paddle subscription
  needs attention (past_due / paused / canceled). Healthy/nil/unknown status →
  renders nothing. Shared by the billing page and the dashboard so the copy +
  severity live in one place.

  Copy is purely informational — emisar does NOT gate features on subscription
  status, so it must never imply lost access (that would be a promise the code
  doesn't keep; if enforcement is ever wired, revisit the wording). Pass a
  `:cta` slot for the "Manage billing" affordance — a portal button on the
  billing page, a link to it on the dashboard — and omit it where the viewer
  can't manage billing.

      <.subscription_banner status={@summary.subscription_status}>
        <:cta :if={Billing.subject_can_manage_billing?(@current_subject)}>…</:cta>
      </.subscription_banner>
  """
  attr :status, :any, default: nil
  attr :class, :any, default: nil
  slot :cta

  def subscription_banner(assigns) do
    assigns = assign(assigns, :alert, subscription_alert(assigns.status))

    ~H"""
    <.callout
      :if={@alert}
      tone={@alert.tone}
      icon="hero-exclamation-triangle"
      title={@alert.title}
      class={@class}
    >
      {@alert.body}
      <:action :if={@cta != []}>{render_slot(@cta)}</:action>
    </.callout>
    """
  end

  # Maps a Paddle subscription status to a banner. active/trialing/nil are
  # healthy (no banner); past_due is the loud "fix your card" case; paused and
  # canceled are amber FYIs. An unknown status we don't model gets no banner —
  # don't alarm on a state we can't explain (Paddle owns the value space; see
  # Subscription.Changeset). Copy is advisory only — emisar does not gate on
  # subscription status, so it must not imply lost access.
  defp subscription_alert("past_due"),
    do: %{
      tone: :rose,
      title: "Payment past due",
      body: "Your last payment failed — update your card so the next charge goes through."
    }

  defp subscription_alert("paused"),
    do: %{
      tone: :amber,
      title: "Subscription paused",
      body: "Resume it from the billing portal when you're ready."
    }

  defp subscription_alert("canceled"),
    do: %{
      tone: :amber,
      title: "Subscription canceled",
      body: "Resubscribe from billing to start a new subscription."
    }

  defp subscription_alert(_), do: nil

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

  # -- emisar-specific layout helpers -----------------------------------

  @doc """
  Brand mark used across the marketing site, auth flows, onboarding,
  and the in-app shell. With `wordmark` (default) it renders the full
  horizontal lockup — the gate icon plus the emisar wordmark — otherwise
  just the icon. Both SVGs bake the dark-theme white + emerald palette,
  so they render correctly on any zinc-950 background without tinting.
  """
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :wordmark, :boolean, default: true
  attr :class, :string, default: nil

  def brand(assigns) do
    ~H"""
    <img
      src={
        if @wordmark, do: ~p"/images/brand/emisar-logo.svg", else: ~p"/images/brand/emisar-icon.svg"
      }
      alt="emisar"
      class={[brand_mark_class(@size, @wordmark), @class]}
    />
    """
  end

  defp brand_mark_class(:sm, true), do: "h-7 w-auto"
  defp brand_mark_class(:md, true), do: "h-9 w-auto"
  defp brand_mark_class(:lg, true), do: "h-11 w-auto"
  defp brand_mark_class(:sm, false), do: "h-7 w-7"
  defp brand_mark_class(:md, false), do: "h-9 w-9"
  defp brand_mark_class(:lg, false), do: "h-11 w-11"

  @doc """
  Two-column auth-flow layout: marketing copy on the left, form on the
  right. Used by sign in / sign up / magic link / password reset.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def auth_layout(assigns) do
    ~H"""
    <div class="grid min-h-screen grid-cols-1 lg:grid-cols-2">
      <div class="hidden bg-gradient-to-br from-brand-950 via-zinc-950 to-zinc-950 p-12 lg:flex lg:flex-col">
        <a href="/" class="text-zinc-100">
          <.brand size={:md} />
        </a>

        <div class="flex flex-1 items-center">
          <div class="max-w-md">
            <p class="text-2xl font-semibold leading-snug tracking-tight text-zinc-100">
              Give AI tools approved infrastructure actions, not SSH.
            </p>
            <ul class="mt-6 space-y-3 text-sm text-zinc-400">
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>Pre-approved playbooks instead of arbitrary shell</span>
              </li>
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>Fine-grained policy with human approvals for risky ops</span>
              </li>
              <li class="flex items-start gap-2.5">
                <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-brand-400" />
                <span>
                  Searchable audit of every action and decision, plus a hash-chained host journal
                </span>
              </li>
            </ul>
          </div>
        </div>

        <%!-- Invisible mirror of the logo row above, so the pitch's flex-1
             centering area is vertically symmetric and its optical center
             matches the form column's (which hides its logo at lg). --%>
        <div class="invisible" aria-hidden="true">
          <.brand size={:md} />
        </div>
      </div>

      <div class="flex flex-col p-6 lg:p-12">
        <.link href={~p"/"} class="mb-10 inline-block lg:hidden">
          <.brand size={:md} />
        </.link>

        <%!-- Mobile anchors to a consistent top (centering short content
             leaves a floating dead-zone that varies per sibling page);
             lg keeps the vertical centering. --%>
        <div class="flex flex-1 items-start justify-center pt-2 lg:items-center lg:pt-0">
          <div class="w-full max-w-md">
            <h1 class="text-3xl font-bold tracking-tight text-zinc-50">{@title}</h1>
            <div class="mt-8">
              {render_slot(@inner_block)}
            </div>
          </div>
        </div>

        <div class="flex justify-center">
          <footer class="mt-10 w-full max-w-md border-t border-zinc-800/70 pt-6">
            <nav class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-zinc-500">
              <.link href={~p"/trust"} class="transition-colors hover:text-zinc-300">Trust</.link>
              <.link href={~p"/privacy"} class="transition-colors hover:text-zinc-300">Privacy</.link>
              <.link href={~p"/terms"} class="transition-colors hover:text-zinc-300">Terms</.link>
              <.link href={~p"/security"} class="transition-colors hover:text-zinc-300">
                Security
              </.link>
            </nav>
            <p class="mt-3 text-xs text-zinc-600">
              © {Date.utc_today().year} Andrii Dryga. All rights reserved.
            </p>
          </footer>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The auth pages' footer switch-line — one muted centered paragraph with a
  brand link ("New to emisar? Create an account"). One shape for the whole
  auth family (console-ux §3; the hand-rolled copies drifted mt-6/mt-8 and
  dropped classes). The lead-in rides the `:lead` slot, the link label is the
  default slot, and exactly one of `navigate`/`href` picks the link mode.

      <.auth_footer_link href={~p"/sign_up"}>
        <:lead>New to emisar?</:lead>
        Create an account
      </.auth_footer_link>
  """
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  slot :lead, doc: "the muted lead-in text before the link"
  slot :inner_block, required: true

  def auth_footer_link(assigns) do
    ~H"""
    <p class="mt-6 text-center text-sm text-zinc-400">
      {render_slot(@lead)}
      <.link
        navigate={@navigate}
        href={@href}
        class="font-medium text-brand-400 hover:text-brand-300"
      >
        {render_slot(@inner_block)}
      </.link>
    </p>
    """
  end

  @doc """
  A horizontal rule with a centered label ("or") — separates the primary
  sign-in method from the alternatives so the auth pages read as one path with
  fallbacks, not a wall of equal options. The label background matches the
  auth-page surface (zinc-950) so the rule appears to pass behind it.

      <.or_separator />
      <.or_separator label="or with email" />
  """
  attr :label, :string, default: "or"
  attr :class, :string, default: nil

  def or_separator(assigns) do
    ~H"""
    <div class={["relative my-6", @class]}>
      <div class="absolute inset-0 flex items-center" aria-hidden="true">
        <div class="w-full border-t border-zinc-800/70"></div>
      </div>
      <div class="relative flex justify-center">
        <span class="bg-zinc-950 px-3 text-xs lowercase text-zinc-500">{@label}</span>
      </div>
    </div>
    """
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
          current_subject={@current_subject}
          section={@section}
          pending_approvals_count={@pending_approvals_count}
          pending_packs_count={@pending_packs_count}
          fleet_all_offline?={@fleet_all_offline?}
          no_agents?={@no_agents?}
        />
        <.shell_user current_user={@current_user} current_account={@current_account} />
      </aside>

      <%!-- Mobile drawer (hidden by default; JS toggles `open`) --%>
      <div
        id="mobile-nav"
        class="fixed inset-0 z-40 hidden lg:hidden"
        role="dialog"
        aria-modal="true"
        phx-window-keydown={
          JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")
        }
        phx-key="escape"
      >
        <div
          class="absolute inset-0 bg-black/60"
          phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
        >
        </div>
        <aside class="relative flex h-full w-72 max-w-[80vw] flex-col border-r border-zinc-800/70 bg-black shadow-2xl">
          <div class="flex items-center justify-between border-b border-zinc-800/70 px-4 py-3">
            <.shell_brand
              current_account={@current_account}
              switchable_accounts={@switchable_accounts || [@current_account]}
            />
            <button
              type="button"
              aria-label="Close menu"
              class="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
              phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <.shell_nav
            current_account={@current_account}
            current_subject={@current_subject}
            section={@section}
            pending_approvals_count={@pending_approvals_count}
            pending_packs_count={@pending_packs_count}
            fleet_all_offline?={@fleet_all_offline?}
            no_agents?={@no_agents?}
          />
          <.shell_user current_user={@current_user} current_account={@current_account} />
        </aside>
      </div>

      <%!-- The whole console — sidebar AND work column — is one black plane. --%>
      <div class="flex min-w-0 flex-1 flex-col bg-black">
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
          <div class={[
            "mx-auto flex w-full flex-wrap items-start gap-x-3 gap-y-3",
            shell_width(@width)
          ]}>
            <%!-- Mobile hamburger (hidden on lg) --%>
            <button
              type="button"
              aria-label="Open menu"
              class="-ml-1.5 mt-1 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 lg:hidden"
              phx-click={
                JS.show(to: "#mobile-nav", display: "block")
                |> JS.add_class("overflow-hidden", to: "body")
              }
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
            <div class="flex shrink-0 flex-wrap items-center gap-2 pt-1.5 sm:gap-3">
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
  attr :current_account, :map, required: true

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

    ~H"""
    <%!-- pt-2/pb-4 + the tightened group air below keep the WHOLE nav (18 links,
         5 groups) under ~730px, so at common laptop heights (≥860px with the
         brand + user blocks) nothing sits half-clipped at the scroll fold —
         "Support" cut in half read as a rendering defect on every screenshot. --%>
    <nav class="scrollbar-subtle flex-1 space-y-0.5 overflow-y-auto px-3 pb-4 pt-2 text-sm">
      <.nav_link to={~p"/app/#{@current_account}"} active={@section == :dashboard} icon="hero-home">
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
        to={~p"/app/#{@current_account}/settings/agents"}
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
      <.nav_link_external href="mailto:support@emisar.dev" icon="hero-lifebuoy">
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
      <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5 text-zinc-600" />
    </.link>
    """
  end

  attr :label, :string, required: true

  defp nav_group(assigns) do
    ~H"""
    <div class="pb-1 pt-2.5 first:pt-0">
      <p class="px-3 text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
        {@label}
      </p>
    </div>
    """
  end

  attr :current_user, :map, required: true
  attr :current_account, :map, required: true

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
          <.avatar name={@current_user.full_name || @current_user.email} size={:sm} />
          <div class="min-w-0 flex-1">
            <div class="truncate font-medium">{@current_user.full_name || @current_user.email}</div>
            <div class="truncate text-xs text-zinc-500">{@current_user.email}</div>
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
      <span :if={@alert} class="h-1.5 w-1.5 shrink-0 rounded-full bg-amber-400" aria-hidden="true">
      </span>
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
    <div class="flex items-center justify-center gap-2 py-20 text-sm text-zinc-500">
      <.icon name="hero-arrow-path" class="h-5 w-5 animate-spin" />
      <span>Loading…</span>
    </div>
    """
  end

  @doc """
  A compact run-summary row — the action_id (mono), an optional target-runner +
  relative time, and the run's status badge — linking to the run. Used by the
  "recent runs" lists. Pass `show_runner` where the target isn't already implied
  by the surrounding page (the dashboard); omit it on a runner's own page.
  `show_source` adds the human-vs-LLM origin badge — the product's thesis in
  one glyph — where the digest doesn't have a Source column.
  """
  attr :run, :map, required: true
  attr :show_runner, :boolean, default: false
  attr :show_source, :boolean, default: false
  attr :current_account, :map, required: true

  attr :padding, :string,
    default: "px-5 py-3",
    doc: "row inset — a canvas-naked list passes a flush variant"

  def run_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/app/#{@current_account}/runs/#{@run.id}"}
      class={[
        "flex items-center gap-3 rounded-md transition hover:bg-white/[0.04]",
        @padding
      ]}
    >
      <div class="min-w-0 flex-1">
        <%!-- The action id is the run's identity — on a phone it wraps to show
             in full rather than clipping; the wider desktop row still truncates
             to keep the list scannable. dotted_mono breaks at the id's dots,
             never mid-token ("caddy.reverse_proxy_upstr/eams" read as broken). --%>
        <div class="break-words font-mono text-sm text-zinc-200 sm:truncate">
          <.dotted_mono value={@run.action_id} />
        </div>
        <%!-- Attribution rides the meta line — the accountable HUMAN plus the
             channel: "by maya@… via portal", "by jordan@… via Claude Code -
             on-call" (an MCP run's human is its key's owner). No icon, no
             column — the digest row is content left, status right. --%>
        <div class="truncate text-xs text-zinc-500">
          <span :if={@show_runner && @run.runner}>{"on #{@run.runner.name} · "}</span>
          <TimeHelpers.local_time value={@run.inserted_at} mode={:relative} />
          <span :if={@show_source && run_attribution(@run)}>· {run_attribution(@run)}</span>
        </div>
      </div>
      <%!-- Status hugs the right edge — flush with "View all" and the content
           column. A fixed-width column left it floating ~40px in from the edge,
           reading unanchored; a single trailing status reads cleanest against
           the edge. --%>
      <span class="shrink-0">
        <.status_badge status={@run.status} />
      </span>
    </.link>
    """
  end

  # "by <who>" (+ " via <agent>" for MCP) — who is the accountable HUMAN by
  # NAME (email fallback): the requesting user, or an MCP run's key owner.
  # "via portal" is the default channel and says nothing, so it's dropped;
  # the MCP agent name IS the signal (human vs agent origin) and stays. A run
  # with no recorded human (legacy rows, the runbook engine) shows only its
  # channel; nil hides the segment entirely. Unloaded assocs
  # (%Ecto.Association.NotLoaded{} has no :email/:full_name key) fall through
  # the same clauses as nil.
  defp run_attribution(run) do
    case {attribution_who(run), attribution_channel(run)} do
      {nil, nil} -> nil
      {who, nil} -> "by #{who}"
      {nil, channel} -> "via #{channel}"
      {who, channel} -> "by #{who} via #{channel}"
    end
  end

  # Match on :email presence, not a bare %{} — %Ecto.Association.NotLoaded{}
  # is a struct (so a map) and would match %{}, swallowing the api_key fallback.
  defp attribution_who(%{requested_by: %{email: _} = user}), do: user_display_name(user)

  defp attribution_who(%{api_key: %{created_by: %{email: _} = user}}),
    do: user_display_name(user)

  defp attribution_who(_run), do: nil

  defp user_display_name(%{full_name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}), do: email

  defp attribution_channel(%{source: :mcp, api_key: %{name: name}}) when is_binary(name),
    do: name

  defp attribution_channel(%{source: :mcp}), do: "LLM agent"
  defp attribution_channel(%{source: :runbook}), do: "runbook"
  defp attribution_channel(%{source: :scheduled}), do: "schedule"
  defp attribution_channel(_run), do: nil

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
  The dispatch ORIGIN of a run — a small leading icon + the actor label on one
  truncating line. The ICON (not color) distinguishes an LLM/MCP-dispatched run
  (a bolt — the one an operator scans for) from an operator (a person), a runbook,
  or a schedule, so agent-origin is pre-attentive without spending the
  emerald-means-allowed semantic on it (who dispatched is metadata, not an
  outcome). The canonical origin shape — reuse it instead of re-pairing an icon
  with `run_actor/1`. The caller caps the width (`max-w-*`) where the column is
  tight; the label always stays one line.

      <.source_badge source={run.source} label={run_actor(run)} class="max-w-[12rem] text-xs" />
  """
  attr :source, :any,
    required: true,
    doc: "the run's `source` enum — :operator/:mcp/:runbook/:scheduled"

  attr :label, :string, required: true, doc: "the actor label, e.g. from `run_actor/1`"
  attr :class, :string, default: nil

  def source_badge(assigns) do
    ~H"""
    <span class={["inline-flex min-w-0 items-center gap-1.5 text-zinc-400", @class]} title={@label}>
      <.icon name={source_icon(@source)} class="h-3.5 w-3.5 shrink-0 text-zinc-500" />
      <span class="truncate">{@label}</span>
    </span>
    """
  end

  defp source_icon(:mcp), do: "hero-bolt"
  defp source_icon(:runbook), do: "hero-book-open"
  defp source_icon(:scheduled), do: "hero-clock"
  defp source_icon(_operator), do: "hero-user"

  @doc """
  The ONE status dot — the colored circle every live-state indicator composes
  (console-ux §1): posture-line stats, the status badge, connection dots,
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
      ]}>
      </span>
      <span class={["relative inline-flex rounded-full", status_dot_size(@size), status_dot_bg(@tone)]}>
      </span>
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
    >
    </span>
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
  Initial-letter avatar — the ONE identity disc (console-ux §1): a person or
  workspace rendered as the first letter of its name. `:circle` for people
  (the shell user block, the team roster), `:square` for workspaces (the
  account switcher rows).

      <.avatar name={@current_user.full_name || @current_user.email} size={:sm} />
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
  attr :class, :string, default: ""

  def status_badge(assigns) do
    status = to_string(assigns.status)
    {dot_tone, dot_pulse?} = status_dot_spec(status)

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:dot_tone, dot_tone)
      |> assign(:dot_pulse?, dot_pulse?)

    ~H"""
    <%!-- A dot + a toned WORD, not a filled capsule — the pill was the last
         admin-template artifact in every list; terminal-calm statuses read as
         text. The dot carries the semantics for color-blind scanning too. --%>
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap text-xs font-medium",
      status_word_class(@status),
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
  # Planned (a runbook slot not yet dispatched) and expired recede a step
  # below routine neutral — not-yet / no-longer states shouldn't compete.
  defp status_word_class("planned"), do: "text-zinc-500"
  defp status_word_class("expired"), do: "text-zinc-500"

  defp status_word_class(status) do
    case status_tone(status) do
      :pass -> "text-brand-300"
      :pending -> "text-amber-300"
      :deny -> "text-rose-300"
      :neutral -> "text-zinc-400"
    end
  end

  @doc """
  The coarse semantic bucket for a status string — `:pass | :pending | :deny |
  :neutral`. Used where a caller needs the OUTCOME tone without the full badge
  (e.g. the mobile card's left status spine). The detailed `status_classes`/
  `status_dot` below carry the per-status visual specifics (the running pulse,
  the amber "refused" security-block) that this coarse bucket flattens.
  """
  def status_tone(status) do
    case to_string(status) do
      s when s in ~w[success connected approved published running sent] ->
        :pass

      s when s in ~w[pending_approval refused] ->
        :pending

      s
      when s in ~w[failed error validation_failed unknown_action timed_out dispatch_failed denied] ->
        :deny

      _ ->
        :neutral
    end
  end

  # The badge dot's {tone, pulse?} per status. In-flight runs pulse so they
  # read as "still happening", not done — the one cue that separates
  # sent/running (and a held pending_approval) from a static same-hue dot.
  defp status_dot_spec(s) when s in ~w[success connected approved published trusted],
    do: {:brand, false}

  defp status_dot_spec(s) when s in ~w[running sent], do: {:brand, true}
  defp status_dot_spec("pending_approval"), do: {:amber, true}
  defp status_dot_spec("refused"), do: {:amber, false}
  defp status_dot_spec("offline"), do: {:amber, false}
  defp status_dot_spec("pending"), do: {:amber, false}
  defp status_dot_spec("denied"), do: {:rose, false}

  defp status_dot_spec(s)
       when s in ~w[failed error validation_failed unknown_action timed_out dispatch_failed],
       do: {:rose, false}

  defp status_dot_spec(_), do: {:neutral, false}

  defp format_status("pending_approval"), do: "awaiting approval"
  defp format_status("validation_failed"), do: "validation failed"
  defp format_status("unknown_action"), do: "unknown action"
  defp format_status("timed_out"), do: "timed out"
  defp format_status("dispatch_failed"), do: "dispatch failed"
  defp format_status(other), do: other

  @doc """
  A runner's `Runners.connection_state/1` atom → the display status string that
  `<.status_badge>` understands (`:online` → "connected",
  `:offline` → "offline"). One place so the runners list + detail pages
  can't drift on the connection vocabulary — and ONE word for the offline
  fact console-wide (the MCP wire keeps its own stable "disconnected").
  """
  def connection_status(:online), do: "connected"
  def connection_status(:offline), do: "offline"
  def connection_status(:disabled), do: "disabled"
  def connection_status(:pending), do: "pending"

  # -- Generic page primitives ---------------------------------------

  @doc """
  Canonical "card" surface — the one place the dark border/background combo
  lives, so every page picks it up. `bg-zinc-950/40` and the in-app `p-5`
  density are the defaults; pass `padding` for a looser tile (stat, onboarding).

      <.card>
        ...
      </.card>
      <.card padding="p-6" class="lg:col-span-2">...</.card>
  """
  attr :class, :string, default: nil
  attr :padding, :string, default: "p-5"
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <%!-- The ISLAND surface: a zinc-900 step lifted off the black ground by a
         low-opacity white ring (edge-as-light, not a gray line) and a 1px inset
         top highlight. Elevation comes from the surface step — never a drop
         shadow, which can't read on black. --%>
    <div
      class={[
        "rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07]",
        @padding,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Section card with a header — a `<.card>` plus the canonical title row, so
  every "panel with a heading" reads the same. A hand-rolled `<header>` inside
  a `<.card>` is banned (console-ux §3) — this component IS that header.

  Two variants: `:padded` (default) keeps the header inside the card padding;
  `:split` is the bordered header row (`px-5 py-3` + hairline) over an
  UNpadded body — the shape for `divide-y` lists and framed content.
  `title_variant={:eyebrow}` renders the small uppercase content label (a
  detail card's "Reason") instead of the display title. `:badge` renders
  inline after the title (a `<.count_badge>`, a `<.risk_pill>`); `:annotation`
  is the quiet right-side meta, before `:actions`.

      <.panel title="Default policy">
        <:subtitle>Applies to every runner unless a ruleset overrides it.</:subtitle>
        <.policy_fields ... />
      </.panel>

      <.panel variant={:split} title="Recent runs">
        <:actions><.link navigate={...}>View all</.link></:actions>
        <ul class="divide-y divide-zinc-900">...</ul>
      </.panel>

      <.panel title="Reason" title_variant={:eyebrow} padding="p-4">
        <p class="text-sm text-zinc-200">{@request.reason}</p>
      </.panel>
  """
  attr :title, :string, default: nil
  attr :title_variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :variant, :atom, default: :padded, values: [:padded, :split]
  attr :class, :string, default: nil
  attr :padding, :string, default: "p-5"
  attr :rest, :global
  slot :subtitle
  slot :badge, doc: "inline after the title — a count badge, a risk pill"
  slot :annotation, doc: "quiet right-side meta, before :actions"
  slot :actions
  slot :inner_block, required: true

  def panel(%{variant: :split} = assigns) do
    ~H"""
    <.card padding="" class={"overflow-hidden #{@class}"} {@rest}>
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-800/70 px-5 py-3">
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-2">
            <h2 :if={@title} class={panel_title_class(@title_variant)}>{@title}</h2>
            {render_slot(@badge)}
          </div>
          <p :if={@subtitle != []} class="mt-0.5 text-xs leading-relaxed text-zinc-500">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div class="flex min-w-0 shrink-0 items-center gap-3">
          <div :if={@annotation != []} class="text-xs text-zinc-500">{render_slot(@annotation)}</div>
          {render_slot(@actions)}
        </div>
      </header>
      {render_slot(@inner_block)}
    </.card>
    """
  end

  def panel(assigns) do
    ~H"""
    <.card padding={@padding} class={@class} {@rest}>
      <header
        :if={@title || @subtitle != [] || @actions != []}
        class="mb-4 flex items-start justify-between gap-4"
      >
        <div class="min-w-0">
          <div class="flex min-w-0 items-center gap-2">
            <h2 :if={@title} class={panel_title_class(@title_variant)}>{@title}</h2>
            {render_slot(@badge)}
          </div>
          <p :if={@subtitle != []} class="mt-1 text-xs leading-relaxed text-zinc-500">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div class="flex shrink-0 items-center gap-3">
          <div :if={@annotation != []} class="text-xs text-zinc-500">{render_slot(@annotation)}</div>
          {render_slot(@actions)}
        </div>
      </header>
      {render_slot(@inner_block)}
    </.card>
    """
  end

  defp panel_title_class(:default),
    do: "font-display text-base font-semibold tracking-[-0.012em] text-zinc-100"

  defp panel_title_class(:eyebrow),
    do: "text-xs font-semibold uppercase tracking-wider text-zinc-400"

  @doc """
  The ONE `<details>` disclosure — a bordered box whose summary row toggles a
  bordered body, with the chevron affordance (console-ux §6: advanced or
  optional content collapses behind this). `:sm` is the quiet inline helper
  ("Can't scan? Use a setup URI"); `:md` the prominent option block.

  LiveView strips browser-set open state on re-render (console-ux §7.6) —
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
      <summary class={[
        "flex cursor-pointer list-none items-center justify-between gap-3 [&::-webkit-details-marker]:hidden",
        disclosure_summary_class(@size)
      ]}>
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
  (console-ux: a chosen risky option must never wear the safe brand hue);
  the check icon marks the current pick. Values compare as strings.

      <.choice_cards name="invite[role]" value={@form[:role].value}>
        <:card :for={role <- @roles} value={role} title={Emisar.Auth.Role.label(role)}>
          {role_description(role)}
        </:card>
      </.choice_cards>
  """
  attr :name, :string, required: true
  attr :value, :any, required: true, doc: "the currently selected value; compared as strings"
  attr :disabled, :boolean, default: false
  attr :columns, :integer, default: 1, values: [1, 2]
  attr :class, :string, default: nil

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
        class={choice_card_class(to_string(@value) == card.value, @disabled)}
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
            >
            </span>
          </span>
          <span class="mt-0.5 block text-xs leading-relaxed text-zinc-500">
            {render_slot(card)}
          </span>
        </span>
      </label>
    </div>
    """
  end

  defp choice_cards_grid(1), do: "grid grid-cols-1 gap-2"
  defp choice_cards_grid(2), do: "grid grid-cols-1 gap-2 sm:grid-cols-2"

  # Neutral-bright when selected — never a semantic safe/warn hue on a
  # selection affordance. focus-within lifts the ring for keyboard users
  # (the radio itself is sr-only).
  defp choice_card_class(selected?, disabled?) do
    [
      "flex items-start gap-3 rounded-lg p-3 ring-1 transition",
      "focus-within:ring-2 focus-within:ring-brand-500/50",
      if(selected?,
        do: "bg-white/[0.04] ring-white/25",
        else: "bg-black/20 ring-zinc-800 hover:ring-zinc-700"
      ),
      if(disabled?, do: "cursor-not-allowed opacity-70", else: "cursor-pointer")
    ]
    |> Enum.join(" ")
  end

  defp choice_card_icon_class(selected?) do
    "grid h-8 w-8 shrink-0 place-items-center rounded-lg " <>
      if(selected?, do: "bg-zinc-700 text-zinc-100", else: "bg-zinc-800/80 text-zinc-500")
  end

  @doc """
  The ONE bordered navigation card — icon + title + one-line description,
  whole card clickable. `href` means an external destination (new tab +
  outward arrow); `navigate` stays in-app (right arrow).

      <.link_card navigate={~p"/packs"} icon="hero-cube-transparent" title="Pack registry">
        Browse linux-core, cassandra, showcase.
      </.link_card>
  """
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  slot :inner_block, required: true

  def link_card(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <.link href={@href} target="_blank" rel="noopener noreferrer" class={link_card_class()}>
      <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
        <.icon name={@icon} class="h-4 w-4 text-brand-400" /> {@title}
        <.icon name="hero-arrow-top-right-on-square" class="ml-auto h-3.5 w-3.5 text-zinc-600" />
      </div>
      <p class="mt-1 text-xs text-zinc-500">{render_slot(@inner_block)}</p>
    </.link>
    """
  end

  def link_card(assigns) do
    ~H"""
    <.link navigate={@navigate} class={link_card_class()}>
      <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
        <.icon name={@icon} class="h-4 w-4 text-brand-400" /> {@title}
        <.cta_arrow class="ml-auto h-3.5 w-3.5 text-zinc-600" />
      </div>
      <p class="mt-1 text-xs text-zinc-500">{render_slot(@inner_block)}</p>
    </.link>
    """
  end

  defp link_card_class do
    "group rounded-xl bg-zinc-900/60 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)] ring-1 ring-white/[0.07] p-4 transition hover:bg-zinc-900/80"
  end

  @doc """
  The trailing "→" of a forward CTA (link or button), sliding right when its
  enclosing `group` is hovered — ONE animated-arrow shape so every
  call-to-action reads the same. **The parent link/button MUST carry
  `class="group"`.** Inherits the current text colour (so it takes on the link's
  tone); `class` overrides the size, default `h-3.5 w-3.5`.

      <.link navigate={~p"/x"} class="group … text-brand-400">
        Connect an agent <.cta_arrow />
      </.link>
  """
  attr :class, :string, default: "h-3.5 w-3.5"

  def cta_arrow(assigns) do
    ~H"""
    <.icon
      name="hero-arrow-right"
      class={"shrink-0 transition-transform duration-150 group-hover:translate-x-0.5 #{@class}"}
    />
    """
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
  The ONE numbered-steps list — a circle-numbered row per step, for any
  "do these in order" sequence (SSO setup guides, agent connect steps,
  install troubleshooting checks, the runbook plan). Numbers derive from
  slot order. `variant={:guide}` is the compact text-xs instructional
  list; `:plan` is the full-width divide-y data rows the runbook plan
  uses inside an unpadded card.

      <.steps class="mt-3">
        <:step>Create an OAuth web app in your IdP.</:step>
        <:step>Register the redirect URI below.</:step>
      </.steps>
  """
  attr :variant, :atom, default: :guide, values: [:guide, :plan]
  attr :class, :string, default: nil
  slot :step, required: true

  def steps(assigns) do
    ~H"""
    <ol class={[steps_list_class(@variant), @class]}>
      <li :for={{step, idx} <- Enum.with_index(@step)} class={steps_row_class(@variant)}>
        <span class={steps_circle_class(@variant)}>
          {idx + 1}
        </span>
        <div class={steps_content_class(@variant)}>
          {render_slot(step)}
        </div>
      </li>
    </ol>
    """
  end

  defp steps_list_class(:guide), do: "space-y-2.5 text-xs leading-relaxed text-zinc-400"
  defp steps_list_class(:plan), do: "divide-y divide-zinc-900"

  defp steps_row_class(:guide), do: "flex items-start gap-2.5"
  defp steps_row_class(:plan), do: "flex items-start gap-3 px-5 py-3"

  defp steps_circle_class(:guide) do
    "grid h-5 w-5 shrink-0 place-items-center rounded-full bg-zinc-800 text-[10px] font-semibold text-zinc-300"
  end

  defp steps_circle_class(:plan) do
    "grid h-6 w-6 shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-semibold text-zinc-300"
  end

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
        <:seg>last used{" "}<.local_time value={key.last_used_at} mode={:relative} /></:seg>
        <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
      </.meta_line>
  """
  attr :class, :any, default: nil

  slot :seg, required: true do
    attr :mono, :boolean,
      doc: "render THIS segment mono — identifiers only, never a timestamp/email"
  end

  def meta_line(assigns) do
    ~H"""
    <%!-- Mobile wraps to two lines (security meta like "last used" must
         never silently truncate away); sm+ restores the single-line
         truncate. Mirrors list_row's :meta wrapper. Mono is PER SEGMENT — the
         id segment carries it, but a prose segment (a timestamp, an email)
         stays in the reading face; the line as a whole is never mono. --%>
    <div class={["line-clamp-2 sm:line-clamp-none sm:truncate", @class]}>
      <span
        :for={{seg, idx} <- Enum.with_index(@seg)}
        class={seg[:mono] && "font-mono"}
      >
        {if idx > 0, do: " · "}{render_slot(seg)}
      </span>
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
  One-line code value with its copy button — a sign-in link, a callback
  URI, a SCIM base URL. The framed multi-line snippet is `code_panel`;
  this is the single-value row.

      <.code_line id="sso-sign-in-link" value={@sign_in_url} class="mt-3" />
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :class, :any, default: nil

  def code_line(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 rounded-lg bg-zinc-950/80 p-2.5 ring-1 ring-zinc-800",
      @class
    ]}>
      <%!-- A URL is a single line — it scrolls horizontally rather than wrapping
           to a ragged block (this row is "one-line code value" by contract). --%>
      <code
        id={@id}
        class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-xs text-zinc-300"
      >
        {@value}
      </code>
      <.copy_button target={"##{@id}"}>Copy</.copy_button>
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
        class="shrink-0 rounded p-0.5 text-zinc-600 transition hover:text-zinc-200 focus-visible:text-zinc-200"
      >
        <.icon name="hero-clipboard-document" class="h-3.5 w-3.5" />
      </button>
    </span>
    """
  end

  @doc """
  The ONE framed code surface — an eyebrow-labeled header (optional
  `annotation`, optional copy button, `:badge` extras) over a mono `<pre>`.
  Every static code/JSON/argv/snippet block composes this (console-ux §1).
  The code rides the `code` ATTR, not a slot, so the formatter can never leak
  indentation into the whitespace-significant `<pre>`. The run-output
  terminal (streamed spans) is the sanctioned hand-rolled exception.

      <.code_panel
        id="run-args"
        label="Arguments"
        annotation={"sha256:" <> sha}
        max_h="max-h-64"
        code={format_json(@run.args)}
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
  attr :class, :string, default: nil
  attr :rest, :global
  slot :badge, doc: "header extras next to the label (e.g. a streaming pill)"

  def code_panel(assigns) do
    ~H"""
    <.card class={"overflow-hidden #{@class}"} padding="" {@rest}>
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
            class="truncate font-mono text-[11px] text-zinc-500"
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
        class={[
          "overflow-auto bg-black/40 p-4 font-mono text-xs text-zinc-300 [font-variant-ligatures:none]",
          @max_h
        ]}
      ><span :if={@prompt} class="select-none text-zinc-600">$ </span>{@code}</pre>
    </.card>
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
  slot :help, doc: "a longer how-it-works body, rendered in a card below"

  def page_intro(assigns) do
    ~H"""
    <div :if={@inner_block != [] or @actions != [] or @help != []} class={["space-y-4", @class]}>
      <div :if={@inner_block != [] or @actions != []} class="flex items-start justify-between gap-4">
        <p :if={@inner_block != []} class="max-w-2xl text-sm leading-relaxed text-zinc-400">
          {render_slot(@inner_block)}
        </p>
        <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
      </div>
      <.panel :if={@help != []} title="How this works">
        <p class="text-sm leading-relaxed text-zinc-400">{render_slot(@help)}</p>
      </.panel>
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
  Upsell marker for a plan-gated feature in the docs: names the plan(s) that
  include it and links to pricing, so a reader on a lower plan sees at a glance
  that the feature isn't on theirs (and where to get it). `tier: :team` →
  available on Team and Enterprise; `tier: :enterprise` → Enterprise only.

  Pass `link={false}` for the non-linking `<span>` variant when the badge sits
  INSIDE another anchor (a docs index card), since anchors can't nest.

      <h2>Directory sync <.plan_badge tier={:enterprise} /></h2>
  """
  attr :tier, :atom, required: true, values: [:team, :enterprise]
  attr :link, :boolean, default: true
  attr :class, :string, default: nil

  def plan_badge(%{link: false} = assigns) do
    ~H"""
    <span title={plan_badge_title(@tier)} class={[plan_badge_class(), @class]}>
      {plan_badge_label(@tier)}
    </span>
    """
  end

  def plan_badge(assigns) do
    ~H"""
    <.link
      href={~p"/pricing"}
      title={plan_badge_title(@tier)}
      class={[plan_badge_class(), "hover:bg-amber-500/20 hover:text-amber-200", @class]}
    >
      {plan_badge_label(@tier)}
    </.link>
    """
  end

  defp plan_badge_class do
    "inline-flex items-center whitespace-nowrap rounded-full bg-amber-500/10 px-2 py-0.5 " <>
      "align-middle text-[11px] font-semibold uppercase tracking-wide text-amber-300 " <>
      "ring-1 ring-amber-500/25 transition-colors"
  end

  defp plan_badge_label(:team), do: "Team & Enterprise"
  defp plan_badge_label(:enterprise), do: "Enterprise"

  defp plan_badge_title(:team), do: "Available on the Team and Enterprise plans — see pricing"
  defp plan_badge_title(:enterprise), do: "Available on the Enterprise plan — see pricing"

  @doc """
  A "pinned to X" filter chip for a row-click / "View activity" pivot — shows what
  the list is scoped to and clears in one click. Shared by the audit actor/subject
  pivots and the runs agent pivot. `clear_to` is a same-LV patch path.

      <.pivot_chip label="Agent" value={@agent_label} clear_to={~p"/app/\#{@acct}/runs"} />
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :clear_to, :string, required: true

  def pivot_chip(assigns) do
    ~H"""
    <div class="mb-4 flex w-max items-center gap-2 rounded-lg bg-brand-500/10 px-3 py-1.5 text-xs text-brand-200 ring-1 ring-brand-500/30">
      <span>{@label}: <span class="font-medium">{@value}</span></span>
      <.link
        patch={@clear_to}
        class="font-semibold text-brand-300 hover:text-brand-100"
        aria-label={"Clear #{String.downcase(@label)} filter"}
      >
        ✕
      </.link>
    </div>
    """
  end

  @doc """
  The bare heading-row above an UNbordered list/table section (distinct from
  `<.panel>`, which owns a bordered header). A `text-sm` section title, an
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
        <p :if={@subtitle != []} class="mt-0.5 max-w-xl text-xs text-zinc-500">
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
    <dt class="font-mono text-zinc-500">{@label}</dt>
    <dd class="break-all font-mono text-zinc-300">{render_slot(@inner_block)}</dd>
    """
  end

  def kv(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3 py-1">
      <dt class="text-zinc-500">{@label}</dt>
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
      <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">{@label}</div>
      <div class={["mt-0.5", if(@wrap, do: "break-words", else: "truncate")]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Horizontal meta strip wrapper — the bordered rounded box that holds
  `<.meta_field>` key-value cells under page titles on DETAIL pages (a run's
  runner / risk / pack / time). Not a list page's naked posture line (a count
  strip) nor `<.stat>` (the dashboard tile). Pass `cols` for an explicit column
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
  + actions layout used by AuthKeys, Agents, Grants, Runbooks, etc.

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
  attr :class, :string, default: nil
  # Island rows keep the px-5 gutter; a CONTENT-ON-CANVAS list passes its own
  # (the run_row precedent) so rows align to the page rail instead.
  attr :padding, :string, default: "px-5 py-4"
  slot :leading, doc: "a custom leading element (avatar, connection dot) — replaces the icon disc"
  slot :title, required: true
  slot :chips
  slot :meta
  slot :actions

  def list_row(assigns) do
    ~H"""
    <li class={["flex flex-wrap items-start gap-4 sm:flex-nowrap", @padding, @class]}>
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
        <div :if={@meta != []} class="mt-1 line-clamp-2 text-xs text-zinc-500 sm:line-clamp-none">
          {render_slot(@meta)}
        </div>
      </div>

      <%!-- Below sm the actions take their own full-width row under the
           content, so the title — the row's identity — owns the width
           instead of being crushed to a clipped glyph by three buttons. --%>
      <div :if={@actions != []} class="flex w-full shrink-0 items-center gap-2 sm:w-auto">
        {render_slot(@actions)}
      </div>
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
  (zinc — the default, for identity/metadata labels like "You", a scope,
  the current plan), `:brand` (emerald — a healthy/affirmative state:
  trusted, enabled, online, enrolled), `:amber` (pending/caution), `:rose`
  (denied/danger). With `mono`, renders monospace text; with `upcase`, the
  uppercase-semibold status-tag look (a pack's trust state, a plan's
  "Current").

      <.chip>group: default</.chip>
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
  Wraps a trigger element with a styled hover/focus tooltip — a dark bubble above
  it carrying `text`, for the "why" a control is locked/disabled/limited. CSS-only
  (named `group/tooltip`, so it's safe inside a row that has its own `group`); the
  bubble is right-anchored so it grows leftward and won't clip off a right-edge
  badge. `text` also rides as `aria-label` for assistive tech.

      <.tooltip text="Role is managed by directory sync — change it in your IdP">
        <.chip icon="hero-lock-closed-mini">Operator</.chip>
      </.tooltip>
  """
  attr :text, :string, required: true
  attr :class, :string, default: nil, doc: "classes on the wrapper (e.g. shrink-0)"
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class={["group/tooltip relative inline-flex", @class]} aria-label={@text}>
      {render_slot(@inner_block)}
      <span
        role="tooltip"
        class="pointer-events-none absolute bottom-full right-0 z-30 mb-2 w-max max-w-xs rounded-lg bg-zinc-800 px-2.5 py-1.5 text-[11px] font-medium leading-snug text-zinc-100 opacity-0 shadow-xl ring-1 ring-white/10 transition-opacity duration-100 group-hover/tooltip:opacity-100"
      >
        {@text}
      </span>
    </span>
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
    <span class="inline-flex items-center text-zinc-500">
      <.link
        navigate={@navigate}
        class="font-medium text-zinc-400 hover:text-zinc-200"
      >
        {render_slot(@inner_block)}
      </.link>
      <span class="mx-2 text-zinc-700" aria-hidden="true">/</span>
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
      class="ml-2 text-sm font-normal text-zinc-500"
    >{render_slot(@meta)}</span>
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
  it renders itself from the slot label and the button's `phx-click` (so call
  sites don't hand-roll the button). `tone` colors it and picks the button
  variant: `:danger` (rose — disable/delete, the default) or `:success` (brand-green
  — enable/restore), so every consequential-action panel reads alike. Pass
  `confirm` for a destructive action's `data-confirm` dialog; omit it for a safe
  restorative one. Used on detail pages (runner detail, team member remove, etc.).

      <.confirm_zone title="Disable this runner" confirm="Disable? It can't reconnect." phx-click="disable">
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
  attr :confirm, :string, default: nil
  attr :rest, :global

  def confirm_zone(assigns) do
    ~H"""
    <section class={[
      "flex items-start justify-between gap-4 rounded-xl border p-5",
      confirm_zone_section(@tone)
    ]}>
      <div>
        <h3 class={["text-sm font-semibold", confirm_zone_title(@tone)]}>{@title}</h3>
        <p class={["mt-1 text-xs", confirm_zone_body(@tone)]}>{render_slot(@body)}</p>
      </div>
      <div class="shrink-0">
        <.button
          variant={confirm_zone_button_variant(@tone)}
          tone={confirm_zone_button_tone(@tone)}
          size={:md}
          data-confirm={@confirm}
          {@rest}
        >
          {render_slot(@inner_block)}
        </.button>
      </div>
    </section>
    """
  end

  # `:danger` keeps the original rose danger-zone styling; `:success` is the
  # brand-green twin for restorative actions, so both read alike structurally.
  defp confirm_zone_section(:danger), do: "border-rose-900/40 bg-rose-950/20"
  defp confirm_zone_section(:success), do: "border-brand-500/30 bg-brand-500/[0.04]"
  defp confirm_zone_title(:danger), do: "text-rose-200"
  defp confirm_zone_title(:success), do: "text-brand-100"
  defp confirm_zone_body(:danger), do: "text-rose-300/70"
  defp confirm_zone_body(:success), do: "text-brand-300/70"
  defp confirm_zone_button_variant(:danger), do: :secondary
  defp confirm_zone_button_variant(:success), do: :primary

  defp confirm_zone_button_tone(:danger), do: :rose
  defp confirm_zone_button_tone(:success), do: :brand

  @doc ~S"""
  Centered, danger-toned confirmation modal with a **typed-confirm**: the
  operator must type `confirm_token` (the member's email, the runner's name, …)
  before the Confirm button enables. Reserve it for IRREVERSIBLE destructive
  actions — removing a member, deleting a runner, revoking a key. Low-stakes
  reversible actions ("End all sessions", "Suspend") keep native `data-confirm`.

  **The typed-confirm is UX friction to prevent accidents, NOT authorization.**
  It only decides whether Confirm *dispatches the event in the UI*; the real gate
  stays server-side in the action's `handle_event` (its `Permissions.gated` /
  context `%Subject{}` check). A crafted event that fires `on_confirm` directly,
  bypassing this modal, is still refused by that gate — keep it that way.

  Gating is LiveView-state (verifiable in a test): the `<.input>` is
  `phx-change="confirm_typed"`, so the page holds the typed value in `@typed`
  (via `EmisarWeb.ConfirmDialog`); the Confirm `<.button>` is
  `disabled={@typed != @confirm_token}`. Open the dialog from the trigger with
  `show_confirm_dialog(id)`; it closes on Cancel, Escape, or backdrop click,
  resetting the typed value each time so a stale entry can't pre-enable Confirm.

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
          Permanently removes <span class="font-medium text-rose-100">{m.user.email}</span>;
          they lose access immediately and need a fresh invite to return.
        </:body>
      </.confirm_dialog>

  The token, title, and body render escaped through HEEx (IL-16) — they carry
  operator/runner data.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :confirm_token, :string, required: true, doc: "the exact string the operator must type"
  attr :typed, :string, default: "", doc: "the live-typed value held by the page (@typed)"
  attr :on_confirm, :any, required: true, doc: "JS/event the enabled Confirm dispatches"
  slot :body, required: true

  def confirm_dialog(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative z-50 hidden"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={hide_confirm_dialog(@id)}
      phx-key="escape"
    >
      <%!-- Backdrop — clicking it closes the dialog (and resets the typed value). --%>
      <div
        id={"#{@id}-backdrop"}
        class="fixed inset-0 bg-black/70 backdrop-blur-sm"
        phx-click={hide_confirm_dialog(@id)}
        aria-hidden="true"
      >
      </div>

      <div class="fixed inset-0 flex items-center justify-center p-4">
        <div class="w-full max-w-md rounded-xl border border-rose-900/50 bg-zinc-950 p-6 shadow-2xl">
          <div class="flex items-start gap-3">
            <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-rose-500/15 text-rose-300">
              <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id={"#{@id}-title"} class="text-sm font-semibold text-rose-100">{@title}</h2>
              <p class="mt-1 text-xs leading-relaxed text-rose-300/70">{render_slot(@body)}</p>
            </div>
          </div>

          <%!-- Typed-confirm: the page's "confirm_typed" handler holds this in
               @typed; the Confirm button below is disabled until it equals the
               token. Server authz is unaffected — this is friction only. The
               token renders through HEEx escaped (IL-16) — it's operator data.
               The input lives in a form so `phx-change` serializes it; Enter
               (`phx-submit`) just re-stores the value — it never dispatches the
               destructive event, which only fires from the Confirm button. --%>
          <form phx-change="confirm_typed" phx-submit="confirm_typed" class="mt-4">
            <.label for={"#{@id}-input"} variant={:eyebrow}>
              Type <span class="font-mono text-rose-200">{@confirm_token}</span> to confirm
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
              phx-click={hide_confirm_dialog(@id)}
            >
              Cancel
            </.button>
            <%!-- Enabled only when the typed value matches a NON-empty token —
                 a blank token can never be confirmed, so a page-level dialog
                 with no target selected yet stays inert. --%>
            <.button
              variant={:secondary}
              tone={:rose}
              size={:md}
              type="button"
              disabled={@confirm_token in ["", nil] or @typed != @confirm_token}
              phx-click={@on_confirm}
            >
              {@confirm_label}
            </.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Opens a `<.confirm_dialog>` by id — reveals it, resets the page's typed value
  (so a prior entry can't pre-enable Confirm), and focuses the type-to-confirm
  input. Wire it to the trigger's `phx-click`.
  """
  def show_confirm_dialog(js \\ %JS{}, id) do
    js
    |> JS.push("confirm_reset")
    |> show("##{id}")
    |> JS.focus(to: "##{id}-input")
  end

  @doc """
  Closes a `<.confirm_dialog>` by id and resets the page's typed value. Used by
  Cancel, the backdrop, and Escape.
  """
  def hide_confirm_dialog(js \\ %JS{}, id) do
    js
    |> hide("##{id}")
    |> JS.push("confirm_reset")
  end

  @doc ~S"""
  Statistic **tile** — a big number in its own card, for the dashboard's metrics
  grid. The widest of the stat pair: a list page's health counts are a naked
  posture line of `<.status_dot>` + count text (the runners/agents grammar);
  `<.meta_field>` is the key-value strip under a detail title.

      <.stat label="Runners online" value={@runners_connected} hint={"of #{@total} total"} />
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  # Outcome lives in the value + this colored hint, NOT a tinted card border —
  # so a stat tile reads the same as every other card (one flat surface) while
  # still signalling state.
  attr :hint_tone, :atom, default: :neutral, values: [:neutral, :rose, :amber, :brand]
  attr :class, :string, default: nil

  def stat(assigns) do
    ~H"""
    <.card padding="p-6" class={@class}>
      <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400">{@label}</div>
      <div class={["mt-2 text-3xl font-semibold tabular-nums", stat_value_class(@value)]}>
        {stat_value(@value)}
      </div>
      <div :if={@hint} class={["mt-1 text-xs", stat_hint_tone(@hint_tone)]}>{@hint}</div>
    </.card>
    """
  end

  defp stat_hint_tone(:rose), do: "text-rose-300"
  defp stat_hint_tone(:amber), do: "text-amber-300"
  defp stat_hint_tone(:brand), do: "text-brand-300"
  defp stat_hint_tone(_), do: "text-zinc-500"

  # `value={:unavailable}` renders a muted em dash so a tile whose read failed
  # reads "couldn't load", not a misleading 0 (the value is otherwise a count
  # or an "N / M" string).
  defp stat_value(:unavailable), do: "—"
  defp stat_value(value), do: value
  defp stat_value_class(:unavailable), do: "text-zinc-600"
  defp stat_value_class(_), do: "text-zinc-50"

  @doc """
  Install-a-runner wizard for the standalone `/app/runners/install` page.
  The caller pre-mints the install command and passes it as a string (or
  `:mint_failed` to render the fallback); after a grace period with no
  runner it flips `show_troubleshooting` to reveal a checklist (the host
  must reach `base_url`).

      <.install_wizard install_command={@install_command} />
  """
  attr :install_command, :any, required: true
  attr :base_url, :string, default: nil
  attr :show_troubleshooting, :boolean, default: false
  attr :keys_path, :string, default: "/app/runners/keys"
  # The multi-use pointer targets a manage-only page — hide it for callers
  # whose subject can't open it (an in-product link must never 404).
  attr :show_keys_link, :boolean, default: true

  def install_wizard(assigns) do
    ~H"""
    <%!-- CONTENT ON CANVAS — no outer grey box. The only contained surfaces
         are the ones a box MEANS something for: the command artifact and the
         live-credential warning. --%>
    <div>
      <p class="text-sm leading-relaxed text-zinc-400">
        Two minutes — pick a Linux or macOS host, paste the one-liner.
      </p>

      <%= cond do %>
        <% is_binary(@install_command) -> %>
          <div class="mt-6 space-y-6">
            <div>
              <div class="text-xs font-semibold uppercase tracking-wider text-zinc-400">
                Run this on the host
              </div>
              <%!-- No wrap: a token broken mid-word ("EMIS AR_URL") reads as
                   corruption in the very command we're asking the operator to
                   trust — scroll on narrow screens; Copy is the real path. --%>
              <div class="mt-2 flex items-center gap-2 rounded-lg border border-zinc-800 bg-black/60 p-4 font-mono text-xs">
                <pre class="flex-1 overflow-x-auto whitespace-pre text-zinc-300">{@install_command}</pre>
                <%!-- Copy the literal string, not the rendered element's
                       innerText: the leading space (HISTCONTROL=ignorespace)
                       is significant and the selector path would strip it. --%>
                <.copy_button
                  text={@install_command}
                  class="self-start bg-brand-500/20 px-2 text-brand-200 hover:bg-brand-500/30 font-semibold"
                >
                  Copy
                </.copy_button>
              </div>
              <%!-- The one-liner embeds a single-use enrollment key shown
                     only here — a root-capable credential. The marketing
                     quickstart tells the trust story, but the operator has left
                     that page; carry it onto the page they actually install
                     from so they don't paste it into a chat/ticket or run an
                     unknown root script blind. --%>
              <div class="mt-3 rounded-lg border border-amber-500/30 bg-amber-500/10 p-4 text-xs leading-5 text-amber-200/90">
                <div class="flex items-center gap-2 font-semibold text-amber-200">
                  <.icon name="hero-key" class="h-4 w-4" /> Live credential — won't be shown again
                </div>
                <p class="mt-1.5">
                  The command runs with <code class="font-mono">sudo</code>
                  and carries a <span class="font-semibold">one-time</span>
                  key: it enrolls
                  exactly one host, then expires. Treat it like a password — paste it straight
                  onto the host, never into a chat or ticket.
                </p>
                <p :if={@show_keys_link} class="mt-1.5">
                  Baking an image, or enrolling a whole fleet with cloud-init? Mint a
                  <span class="font-semibold">multi-use</span>
                  key under
                  <.link
                    navigate={@keys_path}
                    class="font-semibold text-brand-400 hover:text-brand-300"
                  >
                    Runner keys →
                  </.link>
                </p>
              </div>
              <div class="mt-2 text-xs leading-5 text-zinc-500">
                <p>
                  The leading space keeps the key out of your shell history. It's a plain shell
                  script —
                  <.link
                    href="/install.sh"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-semibold text-brand-400 hover:text-brand-300"
                  >
                    read it first →
                  </.link>
                </p>
                <ul class="mt-2 space-y-1">
                  <%!-- mt-[3px]: optically centers the 14px check on the 20px
                       first text line (mt-0.5 sat visibly high). --%>
                  <li class="flex items-start gap-2">
                    <.icon name="hero-check" class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400" />
                    <span>Verifies the download's SHA-256 before running anything</span>
                  </li>
                  <li class="flex items-start gap-2">
                    <.icon name="hero-check" class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400" />
                    <span>
                      Runs the runner as a dedicated
                      <code class="font-mono text-zinc-400">emisar</code>
                      user (not root) under a systemd unit
                    </span>
                  </li>
                  <li class="flex items-start gap-2">
                    <.icon name="hero-check" class="mt-[3px] h-3.5 w-3.5 flex-none text-brand-400" />
                    <span>Only dials out — nothing listens on the host</span>
                  </li>
                </ul>
                <p class="mt-2">
                  Prefer to verify before you run?
                  <.link
                    href={~p"/trust" <> "#release-integrity"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-semibold text-brand-400 hover:text-brand-300"
                  >
                    Check the release's provenance + checksum →
                  </.link>
                </p>
              </div>
            </div>

            <div class="border-t border-zinc-800/70 pt-4">
              <div class="flex items-center gap-3">
                <%!-- Amber: this is a PENDING state — brand-green would read
                     "connected" before anything has connected. Naked on the
                     canvas: a wait line, not a widget. --%>
                <.status_dot tone={:amber} size={:md} ping />
                <div class="text-sm text-zinc-300">
                  Waiting for a runner to connect — this page advances on its own.
                  You can leave; the runner will appear in Runners either way.
                </div>
              </div>

              <%!-- After the grace period with no join (the install page's
                     watchdog flips show_troubleshooting) the likely funnel
                     failure is a wrong/truncated key, :443 firewalled, or a
                     non-systemd host — none of which the pulse alone reveals.
                     Surface the same checks the quickstart doc carries. --%>
              <div
                :if={@show_troubleshooting}
                class="mt-3 border-t border-zinc-800/70 pt-3 text-xs leading-5 text-zinc-400"
              >
                <div class="font-semibold text-zinc-300">Not seeing it yet? Check the host:</div>
                <.steps class="mt-1.5">
                  <:step>
                    It can reach <code class="font-mono text-zinc-300">{@base_url}</code>
                    over outbound HTTPS (nothing needs to listen on it).
                  </:step>
                  <:step>
                    You ran the whole line with <code class="font-mono text-zinc-300">sudo</code>
                    and the key wasn't truncated on paste.
                  </:step>
                  <:step>
                    It runs systemd — watch the runner's own logs with <code class="font-mono text-zinc-300">journalctl -u emisar -f</code>.
                  </:step>
                </.steps>
              </div>
            </div>
          </div>
        <% @install_command == :mint_failed -> %>
          <div class="mt-6 rounded-lg border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-200/90">
            We couldn't mint a runner key just now. Open
            <.link navigate={@keys_path} class="font-semibold underline">
              Runners → Runner keys
            </.link>
            and create one manually, or refresh this page to try again.
          </div>
        <% true -> %>
          <div class="mt-6 flex items-center gap-3 text-sm text-zinc-400">
            <span class="hero-arrow-path h-4 w-4 animate-spin"></span>
            Generating your install command…
          </div>
      <% end %>
    </div>
    """
  end

  @doc """
  TOTP enrollment block — the white QR wrapper, the "Can't scan?" setup-URI
  disclosure, and ONE `code_input` confirm form (`#mfa_form`, submits
  `confirm_mfa` as `mfa[otp]`). Shared by the profile page's voluntary
  setup (`variant={:split}` — QR beside the guidance) and the enforced-MFA
  interstitial (`:stacked` — centered in the narrow auth card). The page
  passes its own submit/cancel buttons via `:actions`.

      <.mfa_enrollment qr_svg={@mfa_qr_svg} uri={@mfa_uri} form={@mfa_form} variant={:split}>
        <:instructions>Scan with your authenticator, then confirm.</:instructions>
        <:actions>
          <.button phx-disable-with="Verifying...">Confirm and enable</.button>
        </:actions>
      </.mfa_enrollment>
  """
  attr :qr_svg, :string, required: true, doc: "server-generated SVG (MfaQr) — never user input"
  attr :uri, :string, required: true, doc: "the otpauth:// provisioning URI"
  attr :form, Phoenix.HTML.Form, required: true
  attr :variant, :atom, default: :stacked, values: [:stacked, :split]
  slot :instructions
  slot :actions, required: true

  def mfa_enrollment(assigns) do
    ~H"""
    <div class={mfa_enrollment_wrapper(@variant)}>
      <div class="flex flex-col items-center gap-2">
        <%!-- raw/1 is safe here: the SVG comes from MfaQr rendering OUR
             provisioning URI server-side, never from user input (IL-16). --%>
        <div class="rounded-lg bg-white p-3 [&>svg]:block [&>svg]:h-60 [&>svg]:w-60">
          {Phoenix.HTML.raw(@qr_svg)}
        </div>
        <p class="text-[11px] text-zinc-500">Scan with your authenticator</p>
      </div>

      <div class="space-y-3">
        <p :if={@instructions != []} class="text-sm text-zinc-300">
          {render_slot(@instructions)}
        </p>

        <.disclosure>
          <:summary>Can't scan? Use a setup URI</:summary>
          <div class="flex items-center gap-2">
            <code id="mfa-uri" class="flex-1 break-all font-mono text-[11px] text-zinc-200">
              {@uri}
            </code>
            <.copy_button
              target="#mfa-uri"
              class="bg-brand-500/20 px-2 text-brand-100 hover:bg-brand-500/30 font-semibold"
            >
              Copy
            </.copy_button>
          </div>
        </.disclosure>

        <.simple_form for={@form} id="mfa_form" phx-submit="confirm_mfa">
          <.code_input id="mfa-otp" name="mfa[otp]" numeric label="6-digit code" />
          <:actions>
            {render_slot(@actions)}
          </:actions>
        </.simple_form>
      </div>
    </div>
    """
  end

  defp mfa_enrollment_wrapper(:stacked), do: "space-y-4"
  defp mfa_enrollment_wrapper(:split), do: "grid grid-cols-1 gap-6 sm:grid-cols-[auto_1fr]"

  @doc """
  Empty-state panel: a centered icon + headline + body + optional CTA.
  `:boxed`/`:bare` expect `icon` + `title`; `:hint` is the compact dashed
  body-first placeholder ("No overrides. …") with an optional small title
  and usually no icon.

      <.empty_state icon="hero-cpu-chip" title="No runners yet">
        Mint a runner key and run the installer on a host.
        <:cta navigate={~p"/app/\#{@current_account}/runners/keys"}>New runner key</:cta>
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

  # `boxed` — the dashed-border standalone empty (a whole page with nothing in
  # it yet). `bare` — borderless + compact, for a LiveTable `:empty` slot that
  # already sits inside a bordered card. Same anatomy, lighter chrome.
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

  defp empty_state_body(:boxed), do: "mt-2 text-sm text-zinc-500"
  defp empty_state_body(:bare), do: "mt-1 text-xs leading-relaxed text-zinc-500"
  defp empty_state_body(:hint), do: "text-xs leading-relaxed text-zinc-500"

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
  "A runner is offline" notice — a `hero-signal-slash` block whose colour
  encodes SEVERITY, the one place that convention lives so it can't drift:

    * `:info` (zinc) — informational, nothing's wrong (e.g. "you can still
      dispatch; the run queues until it reconnects").
    * `:caution` (amber) — this run/action may be affected.
    * `:critical` (rose) — the whole fleet is down; nothing can dispatch.

      <.offline_notice severity={:caution} title="Queued — runner offline">
        Waiting for {name} to reconnect before this run can dispatch.
        <:action><.link navigate={~p"/app/\#{@current_account}/runners"}>View runners</.link></:action>
      </.offline_notice>
  """
  attr :severity, :atom, default: :caution, values: [:info, :caution, :critical]
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :action

  def offline_notice(assigns) do
    assigns = assign(assigns, :tone, offline_tone(assigns.severity))

    ~H"""
    <.callout tone={@tone} icon="hero-signal-slash" title={@title} class={@class}>
      {render_slot(@inner_block)}
      <:action :if={@action != []}>{render_slot(@action)}</:action>
    </.callout>
    """
  end

  # The severity → tone convention this wrapper exists to encode: informational
  # offline (dispatch still works, the run queues) is a quiet note; caution
  # names an affected run/action; critical means the whole fleet is down.
  defp offline_tone(:info), do: :neutral
  defp offline_tone(:caution), do: :amber
  defp offline_tone(:critical), do: :rose

  @doc """
  Risk pill — used on action descriptors. Colours mirror the runner's
  declared risk level (`low|medium|high|critical`); takes the risk as a
  string (pack-manifest data) or an Ecto.Enum atom (catalog rows).
  """
  attr :risk, :any, required: true
  attr :class, :string, default: nil

  def risk_pill(assigns) do
    assigns = assign(assigns, :risk, to_string(assigns.risk))

    ~H"""
    <span
      title={risk_title(@risk)}
      class={[
        "rounded px-2 py-0.5 text-xs font-semibold uppercase tracking-wider ring-1 ring-inset",
        risk_classes(@risk),
        @class
      ]}
    >
      {@risk}
    </span>
    """
  end

  # The severity scale spelled out on hover, so a non-expert approver knows what
  # "HIGH" means and that CRITICAL is above it (the lexicon a single word can't carry).
  defp risk_title("low"), do: "Low — read-only or trivially reversible"
  defp risk_title("medium"), do: "Medium — changes state, easily reversible"
  defp risk_title("high"), do: "High — service-affecting"
  defp risk_title("critical"), do: "Critical — data loss or irreversible"
  defp risk_title(_), do: nil

  # Risk is a SEVERITY ramp, not a policy outcome: low is the quiet neutral floor,
  # NOT brand-green — green means "the gate allowed this", and a risk tier has had
  # no decision. So it climbs neutral → amber → rose → deeper-rose, and the policy
  # editor's tier cards (`tier_border/tier_dot`) mirror it exactly.
  defp risk_classes("low"), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"
  defp risk_classes("medium"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp risk_classes("high"), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"
  defp risk_classes("critical"), do: "bg-rose-600/15 text-rose-200 ring-rose-500/40"
  defp risk_classes(_), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"

  @doc """
  "expires in 3h" badge for a held approval request — amber when under two
  hours remain so an approver can triage by urgency (the requester's run
  auto-cancels at expiry). Renders nothing without an expiry.

      <.approval_expiry expires_at={@request.expires_at} />
  """
  attr :expires_at, :any, default: nil
  attr :class, :string, default: nil

  def approval_expiry(assigns) do
    assigns = assign(assigns, :expired?, approval_expired?(assigns.expires_at))

    ~H"""
    <span
      :if={@expires_at}
      title={expiry_title(@expired?)}
      class={["inline-flex items-center gap-1 text-xs", expiry_class(@expires_at), @class]}
    >
      <%!-- Past tense once it's lapsed ("expired 2m ago") so an at-the-wire
           approval isn't an ambiguous static "expires just now"; {" "} is a
           literal space HEEx won't trim. The title states the on-expiry behavior;
           the LocalTime hook carries the absolute time on hover. --%>
      <.icon name={if @expired?, do: "hero-no-symbol", else: "hero-clock"} class="h-3 w-3" />
      {if @expired?, do: "expired", else: "expires"}{" "}<TimeHelpers.local_time
        value={@expires_at}
        mode={:relative}
      />
    </span>
    """
  end

  defp approval_expired?(%DateTime{} = expires_at),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  defp approval_expired?(_), do: false

  defp expiry_title(true),
    do: "Expired without a decision — it was auto-denied; the action won't run."

  defp expiry_title(false),
    do: "If no one decides by then, it's auto-denied — the action won't run."

  # Under two hours left → amber: an approval lapsing soon needs to stand out
  # in the queue. Already-expired (the sweeper hasn't cancelled it yet) is moot,
  # not urgent — keep it muted.
  defp expiry_class(%DateTime{} = expires_at) do
    seconds_left = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    if seconds_left > 0 and seconds_left <= 7200, do: "text-amber-400", else: "text-zinc-500"
  end

  defp expiry_class(_), do: "text-zinc-500"

  @doc """
  A bounded, static preview of an action run's tail output — the last few
  progress chunks of a finished run, rendered like the live terminal
  (stderr in rose). Pass `events` in chronological order (oldest→newest);
  an empty list renders nothing.
  """
  attr :events, :list, required: true
  attr :class, :string, default: nil

  def output_preview(assigns) do
    ~H"""
    <%!-- Each chunk carries its own trailing newline (the runner streams
         line-by-line), so chunks concatenate as inline spans inside one
         <pre> and only the real newlines break lines — block elements or
         template indentation would double the spacing. --%>
    <pre
      :if={@events != []}
      class={[
        "overflow-auto whitespace-pre-wrap break-all rounded-md bg-black p-2 font-mono text-[11px] leading-snug text-zinc-300",
        @class
      ]}
    ><span
        :for={event <- @events}
        class={event.stream == "stderr" && "text-rose-300"}
      >{event_chunk(event)}</span></pre>
    """
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
        title="Copy this auth key now — it will not be shown again."
        secret={@new_secret}
        on_dismiss="dismiss_secret"
      >
        Treat it like a password. Anyone with this key can register an
        runner under your account.

        <:install_command>
          curl -sSL https://emisar.dev/install.sh | sudo EMISAR_AUTH_KEY={@new_secret} bash
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
          <p class="mt-1 text-xs text-zinc-400">{render_slot(@inner_block)}</p>

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

  # -- Marketing chrome ------------------------------------------------

  @doc """
  Top nav for marketing pages. Pass `current` to highlight the active
  link, and `current_user` so a signed-in visitor sees a Dashboard link
  instead of the Sign in / Start free CTAs.

      <.marketing_nav current={:pricing} current_user={@current_user} />
  """
  attr :current, :atom, default: nil
  attr :current_user, :any, default: nil
  attr :sticky, :boolean, default: false

  def marketing_nav(assigns) do
    ~H"""
    <header class={[
      "border-b border-zinc-900/80 bg-zinc-950/80 backdrop-blur",
      @sticky && "sticky top-0 z-50"
    ]}>
      <div class="mx-auto flex max-w-7xl items-center justify-between px-6 py-5 lg:px-8">
        <.link href={~p"/"}>
          <.brand size={:md} />
        </.link>

        <%!-- Desktop nav: visible md+. Five items — use cases (proof),
             security (trust), pricing, packs (the catalog), and docs. The
             "what your AI gains" pitch leads the home page itself now;
             Changelog and About live in the footer. --%>
        <nav class="hidden items-center gap-8 md:flex">
          <.marketing_nav_link href={~p"/use-cases"} active={@current == :use_cases}>
            Use cases
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/security"} active={@current == :security}>
            Security
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/pricing"} active={@current == :pricing}>
            Pricing
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/packs"} active={@current == :packs}>
            Packs
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/docs"} active={@current == :docs}>Docs</.marketing_nav_link>
        </nav>

        <%!-- Desktop CTAs: visible md+. A signed-in visitor gets a
             Dashboard link; everyone else gets Sign in / Start free. --%>
        <div class="hidden items-center gap-4 md:flex">
          <%= if @current_user do %>
            <.marketing_button size={:sm} href={~p"/app"} icon="hero-arrow-right">
              Dashboard
            </.marketing_button>
          <% else %>
            <.link
              href={~p"/sign_in"}
              class="whitespace-nowrap text-sm font-semibold text-zinc-100 hover:text-brand-300"
            >
              Sign in
            </.link>
            <.marketing_button size={:sm} href={~p"/sign_up"}>Start free</.marketing_button>
          <% end %>
        </div>

        <%!-- Mobile hamburger: visible < md. Toggles the drawer
             below; uses the same JS dance as the in-app shell so
             the body lock works the same. --%>
        <button
          type="button"
          aria-label="Open menu"
          aria-controls="marketing-mobile-nav"
          aria-expanded="false"
          data-mobile-nav-open
          class="-mr-1.5 rounded-md p-2.5 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 md:hidden"
        >
          <.icon name="hero-bars-3" class="h-5 w-5" />
        </button>
      </div>
    </header>

    <%!-- Mobile menu — the "gate". A full-screen takeover (a SIBLING of
         <header>, so the header's `backdrop-blur` doesn't trap this fixed
         overlay in the nav bar) over the SAME contract-grid + grain as the hero,
         so it reads as the site folding open. The routes are nodes on the gate's
         vertical track — the current page lit emerald, like the logo's middle
         node — and reveal in stagger. Toggled by mobile_nav.js (focus-trapped). --%>
    <div
      id="marketing-mobile-nav"
      class="fixed inset-0 z-50 hidden bg-[#07080a] md:hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Site menu"
    >
      <div class="flex h-full flex-col">
        <%!-- Top bar — mirrors the page nav (same border-b + bg-zinc-950/80 backdrop-blur,
             same px-6 py-5 + <.brand size={:md}/>), so the menu reads as the same chrome and
             the checkered body below it lines up with the hero's grid (both sit below an
             equal-height nav). --%>
        <div class="flex shrink-0 items-center justify-between border-b border-zinc-900/80 bg-zinc-950/80 px-6 py-5 backdrop-blur">
          <.link href={~p"/"}>
            <.brand size={:md} />
          </.link>
          <button
            type="button"
            aria-label="Close menu"
            data-mobile-nav-close
            class="-mr-1.5 rounded-md p-2.5 text-zinc-400 transition hover:bg-zinc-900 hover:text-zinc-100"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <%!-- Body — the hero surface below the bar: the SAME .contract-grid + .grain, which
             fade in with the routes + CTAs as the menu opens. --%>
        <div class="relative flex-1">
          <div
            class="contract-grid mobile-nav-grid pointer-events-none absolute inset-0"
            aria-hidden="true"
          >
          </div>
          <div class="grain pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="absolute inset-0 overflow-y-auto">
            <div class="flex min-h-full flex-col">
              <nav class="relative flex flex-1 flex-col px-6 pb-8 pt-8">
                <%!-- the gate track the route-nodes sit on --%>
                <span
                  class="pointer-events-none absolute bottom-16 left-[2.125rem] top-16 w-px -translate-x-1/2 bg-gradient-to-b from-transparent via-zinc-700/60 to-transparent"
                  aria-hidden="true"
                >
                </span>
                <ul class="flex flex-1 flex-col justify-around">
                  <li>
                    <.marketing_gate_link
                      href={~p"/use-cases"}
                      active={@current == :use_cases}
                      idx={1}
                    >
                      Use cases
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/security"} active={@current == :security} idx={2}>
                      Security
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/pricing"} active={@current == :pricing} idx={3}>
                      Pricing
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/packs"} active={@current == :packs} idx={4}>
                      Packs
                    </.marketing_gate_link>
                  </li>
                  <li>
                    <.marketing_gate_link href={~p"/docs"} active={@current == :docs} idx={5}>
                      Docs
                    </.marketing_gate_link>
                  </li>
                </ul>
              </nav>

              <div class="rise-5 relative px-6 pb-9">
                <.scan_line class="mb-7 opacity-50" />
                <div class="space-y-3">
                  <%= if @current_user do %>
                    <.marketing_button block href={~p"/app"} icon="hero-arrow-right">
                      Dashboard
                    </.marketing_button>
                  <% else %>
                    <.marketing_button block href={~p"/sign_up"}>Start free</.marketing_button>
                    <.marketing_button variant={:secondary} block href={~p"/sign_in"}>
                      Sign in
                    </.marketing_button>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
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

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :idx, :integer, default: 1, doc: "1-based position, for the staggered rise on open"
  slot :inner_block, required: true

  defp marketing_gate_link(assigns) do
    ~H"""
    <.link href={@href} class={["group flex items-center gap-4 py-4", "rise-#{@idx}"]}>
      <%!-- the route's node on the gate track; lit emerald when it's the
           current page, like the logo's middle node (a request passing). --%>
      <span class="relative flex h-5 w-5 shrink-0 items-center justify-center" aria-hidden="true">
        <span class={[
          "rounded-full ring-[5px] ring-zinc-950 transition",
          @active && "h-2.5 w-2.5 bg-brand-400 shadow-[0_0_16px_3px] shadow-brand-400/40",
          !@active && "h-2 w-2 bg-zinc-700 group-hover:bg-brand-400/70"
        ]}>
        </span>
      </span>
      <span class={[
        "text-2xl font-semibold tracking-tight transition",
        @active && "text-white",
        !@active && "text-zinc-400 group-hover:text-white"
      ]}>
        {render_slot(@inner_block)}
      </span>
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp marketing_nav_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "relative text-sm font-medium transition",
        @active && "text-zinc-100",
        !@active && "text-zinc-400 hover:text-zinc-100"
      ]}
    >
      {render_slot(@inner_block)}
      <%!-- Subtle brand underline on the active page so the
           current section is identifiable without reading the URL. --%>
      <span
        :if={@active}
        class="absolute -bottom-1 left-0 right-0 h-0.5 rounded-full bg-brand-400"
        aria-hidden="true"
      />
    </.link>
    """
  end

  @doc """
  The one call-to-action button for the marketing site — every "Start free",
  "Get started", "Talk to sales", "Read the docs"-style button routes through
  here so they stay visually identical across the 27 pages. The in-app
  `<.button>` is a separate visual world; marketing buttons live here.

  Renders an `<.link>` when given `href`/`navigate` in `:rest`, otherwise a
  `<button>` (so it works for the sign-up form's submit). Pass `external` for
  an outbound link (adds `target="_blank"` + the `noopener noreferrer` rel),
  and `icon` for a trailing heroicon (the conventional right-arrow affordance).

      <.marketing_button navigate={~p"/sign_up"} icon="hero-arrow-right">Start free</.marketing_button>
      <.marketing_button variant={:secondary} navigate={~p"/docs"}>Read the docs</.marketing_button>
      <.marketing_button external href="https://github.com/...">Read the source</.marketing_button>
  """
  attr :variant, :atom, default: :primary, values: [:primary, :secondary]
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :block, :boolean, default: false, doc: "full-width (pricing-card buttons)"
  attr :external, :boolean, default: false, doc: "outbound link — opens a new, isolated tab"
  attr :icon, :string, default: nil, doc: ~s(trailing heroicon, e.g. "hero-arrow-right")
  attr :type, :string, default: nil, doc: ~s(button type when rendering a <button>, e.g. "submit")
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch form name value)
  slot :inner_block, required: true

  def marketing_button(%{external: true} = assigns) do
    ~H"""
    <.link
      target="_blank"
      rel="noopener noreferrer"
      class={marketing_button_class(@variant, @size, @block, @class)}
      {@rest}
    >
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </.link>
    """
  end

  def marketing_button(%{rest: rest} = assigns)
      when is_map_key(rest, :href) or is_map_key(rest, :navigate) or is_map_key(rest, :patch) do
    ~H"""
    <.link class={marketing_button_class(@variant, @size, @block, @class)} {@rest}>
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </.link>
    """
  end

  def marketing_button(assigns) do
    ~H"""
    <button type={@type} class={marketing_button_class(@variant, @size, @block, @class)} {@rest}>
      {render_slot(@inner_block)}<.icon
        :if={@icon}
        name={@icon}
        class="h-4 w-4 transition-transform group-hover/btn:translate-x-0.5"
      />
    </button>
    """
  end

  # Base: inline flex + gap so a trailing icon sits tight, rounded-lg pill,
  # one type ramp. `block` makes it a full-width card button (pricing tiers).
  defp marketing_button_class(variant, size, block, extra) do
    [
      if(block, do: "flex w-full", else: "inline-flex"),
      "group/btn items-center justify-center gap-2 whitespace-nowrap rounded-lg text-sm font-semibold transition active:scale-[0.96] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 focus-visible:ring-offset-zinc-950",
      marketing_button_size(size),
      marketing_button_variant(variant),
      extra
    ]
  end

  defp marketing_button_size(:sm), do: "px-4 py-2"
  defp marketing_button_size(:md), do: "px-5 py-2.5"
  defp marketing_button_size(:lg), do: "px-6 py-3"

  defp marketing_button_variant(:primary), do: "bg-brand-500 text-zinc-950 hover:bg-brand-400"

  defp marketing_button_variant(:secondary),
    do: "bg-transparent text-zinc-100 ring-1 ring-zinc-800 hover:ring-zinc-700"

  @doc """
  Heading for marketing pages — the type scale lives here so headings at the
  same level look the same across pages. Pass `tag` (the semantic level, kept
  as-is per page — this never changes the HTML hierarchy) and `scale` (the
  visual size). `:hero` is the standard page title; `:display` is the larger
  top-level-landing title (home, pricing, security, about, docs index).

      <.marketing_heading tag="h1" scale={:hero}>Quickstart</.marketing_heading>
      <.marketing_heading tag="h1" scale={:display} class="mt-2">Pricing</.marketing_heading>
  """
  attr :tag, :string, required: true, values: ~w(h1 h2 h3)
  attr :scale, :atom, default: :hero, values: [:display, :hero, :section]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def marketing_heading(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "text-balance font-display font-bold text-zinc-50",
        marketing_heading_scale(@scale),
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  defp marketing_heading_scale(:display),
    do: "text-4xl tracking-[-0.035em] sm:text-6xl md:text-7xl"

  defp marketing_heading_scale(:hero), do: "text-4xl tracking-[-0.03em] md:text-5xl"
  # Big centered section header (CTA blocks, "How it works" section tops).
  defp marketing_heading_scale(:section), do: "text-4xl tracking-[-0.03em] sm:text-5xl"

  @doc """
  Conversion CTA for the foot of a marketing page — a convinced reader gets
  one obvious next step. The primary action is always "Start free"; pass a
  contextual secondary (`secondary_label` + `secondary_path`, the latter a
  `~p` route or a `mailto:`). `note` defaults to the free-tier reassurance.
  """
  attr :headline, :string, required: true
  attr :subcopy, :string, required: true
  attr :secondary_label, :string, required: true
  attr :secondary_path, :string, required: true
  attr :note, :string, default: "Three runners. Seven-day audit. No credit card."

  def marketing_cta(assigns) do
    ~H"""
    <section class="pb-24 sm:pb-32">
      <div class="mx-auto max-w-3xl px-6 lg:px-8">
        <div class="relative overflow-hidden rounded-xl border border-brand-500/30 bg-zinc-950 p-8 text-center sm:p-10">
          <div class="glow-emerald pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="grain pointer-events-none absolute inset-0" aria-hidden="true"></div>
          <div class="relative">
            <h2 class="text-2xl font-bold tracking-tight text-white sm:text-3xl">{@headline}</h2>
            <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-zinc-400">{@subcopy}</p>
            <div class="mt-7 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <.marketing_button
                href={~p"/sign_up"}
                icon="hero-arrow-right"
                class="w-full sm:w-auto"
              >
                Start free
              </.marketing_button>
              <.marketing_button
                variant={:secondary}
                href={@secondary_path}
                class="w-full sm:w-auto"
              >
                {@secondary_label}
              </.marketing_button>
            </div>
            <p class="mt-4 text-xs text-zinc-500">{@note}</p>
          </div>
        </div>
      </div>
    </section>
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
      <ol class="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-zinc-500">
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

  # ============================================================
  #  Marketing "gate" kit
  #
  #  The brand mark is an emerald gate (images/brand/emisar-icon.svg); these
  #  primitives carry it across the marketing site (see creative-director):
  #  `gate_mark` is the logo icon, `scan_line` marks the decision point, and
  #  `state_chip` shows what the gate decided. The accent is `brand-*` (the
  #  exact logo green); pass/pending/deny stay emerald/amber/rose so they
  #  match `<.chip>`/`<.risk_pill>`. Marketing-only — the operator console
  #  keeps its own calm system.
  # ============================================================

  @doc """
  The emisar gate mark — the logo icon as an inline SVG: an ink chevron and an
  emerald chevron flanking a vertical track of three nodes, the middle one
  emerald (a request passing the gate). Inline so it inherits `currentColor`
  for the ink and sits in flows at any size. `animate` pulses the three nodes
  top-to-bottom (a request crossing); base opacity is full, so reduced-motion
  lands them lit and static. The mark is decorative, so it is `aria-hidden`.

      <.gate_mark class="h-9 w-9 text-zinc-100" />
      <.gate_mark animate class="h-12 w-12 sm:h-14 sm:w-14" />
  """
  attr :animate, :boolean, default: false
  attr :class, :string, default: "h-12 w-12"

  def gate_mark(assigns) do
    ~H"""
    <svg viewBox="-18 0 390 390" class={@class} fill="none" aria-hidden="true">
      <g stroke-linejoin="round" stroke-linecap="butt" stroke-width="37">
        <path d="M96 50 L19.5 195 L96 340" stroke="currentColor" />
        <path d="M258 50 L334.5 195 L258 340" stroke="#36E6A5" />
      </g>
      <line x1="177" y1="84" x2="177" y2="153" stroke="currentColor" stroke-width="16" />
      <line x1="177" y1="237" x2="177" y2="306" stroke="currentColor" stroke-width="16" />
      <circle
        cx="177"
        cy="42.5"
        r="34.5"
        stroke="currentColor"
        stroke-width="14"
        class={@animate && "gate-dot"}
      />
      <circle
        cx="177"
        cy="195"
        r="34.5"
        stroke="#36E6A5"
        stroke-width="14"
        class={@animate && "gate-dot gate-dot-2"}
      />
      <circle
        cx="177"
        cy="347.5"
        r="34.5"
        stroke="currentColor"
        stroke-width="14"
        class={@animate && "gate-dot gate-dot-3"}
      />
    </svg>
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

  # The emisar_web app version, read at runtime from the loaded app spec (whose
  # vsn comes from portal/VERSION via mix.exs), so the footer always reflects the
  # running release — a compile-time bake goes stale until something recompiles
  # this module. `vsn` comes back as a charlist; convert to a string.
  defp app_version, do: Application.spec(:emisar_web, :vsn) |> to_string()

  @doc """
  Footer for marketing pages. Same on every page.
  """
  def marketing_footer(assigns) do
    # Render timestamp is stamped per request (server-rendered marketing has no
    # LiveView caching) — behind a CDN/edge it freezes at cache time, so if it
    # trails the real clock the footer is being served from a stale cache. Pairs
    # with the build version as a two-part freshness signal (which build · when
    # rendered).
    assigns =
      assigns
      |> assign(:app_version, app_version())
      |> assign(:rendered_at, TimeHelpers.forensic_time(DateTime.utc_now()))

    ~H"""
    <footer class="border-t border-zinc-800/70 bg-zinc-950">
      <div class="mx-auto max-w-7xl px-6 py-16 lg:px-8">
        <%!-- Product-updates capture — the considered buyer's low-commitment
             path. A server-rendered POST: marketing has no LiveView, so the
             flash renders via the app layout and the redirect anchors back here
             (#updates) rather than jumping to the page top. Honeypot + CSRF + a
             citext-unique idempotent guard back it. --%>
        <div
          id="updates"
          class="mb-12 flex flex-col gap-6 border-b border-zinc-900 pb-12 sm:flex-row sm:items-center sm:justify-between"
        >
          <div>
            <h2 class="font-display text-sm font-semibold tracking-[-0.01em] text-zinc-100">
              Product updates
            </h2>
            <p class="mt-1 max-w-md text-sm text-zinc-500">
              The occasional note when we ship something major — new packs, features, and security
              improvements. No noise.
            </p>
          </div>
          <.form for={%{}} action={~p"/subscribe"} class="w-full sm:w-auto">
            <input type="hidden" name="source" value="footer" />
            <%!-- Honeypot — hidden from people, tempting to bots. --%>
            <input
              type="text"
              name="company"
              tabindex="-1"
              autocomplete="off"
              aria-hidden="true"
              class="hidden"
            />
            <div class="flex max-w-sm gap-2">
              <label for="subscribe-email" class="sr-only">Email address</label>
              <input
                type="email"
                id="subscribe-email"
                name="email"
                required
                placeholder="you@company.com"
                class="min-w-0 flex-1 rounded-md border border-zinc-800 bg-zinc-900/60 px-3 py-2 text-sm text-zinc-100 placeholder:text-zinc-600 focus-visible:border-brand-500 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-brand-500"
              />
              <.marketing_button type="submit" variant={:secondary} size={:sm}>
                Subscribe
              </.marketing_button>
            </div>
            <p class="mt-2 text-xs text-zinc-600">
              No spam, just product news. See our <.link
                navigate={~p"/privacy"}
                class="text-zinc-500 underline decoration-zinc-700 underline-offset-2 hover:text-zinc-300"
              >privacy policy</.link>.
            </p>
          </.form>
        </div>

        <div class="grid grid-cols-1 gap-12 lg:grid-cols-4">
          <div>
            <.link href={~p"/"}>
              <.brand size={:md} />
            </.link>
            <p class="mt-4 max-w-xs text-sm text-zinc-500">
              Give AI tools approved infrastructure actions, not SSH.
            </p>
            <p class="mt-3 max-w-xs text-xs leading-relaxed text-zinc-600">
              The runner and control-plane source are available for inspection and permitted
              internal use under a non-OSI <a
                href="https://github.com/andrewdryga/emisar/blob/main/LICENSE.md"
                target="_blank"
                rel="noopener noreferrer"
                class="text-zinc-400 hover:text-zinc-200"
              >source-available license</a>.
            </p>
          </div>

          <div class="grid grid-cols-2 gap-8 sm:grid-cols-3 lg:col-span-3 lg:grid-cols-5">
            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Product</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/how-it-works"} class="text-zinc-400 hover:text-zinc-100">
                    How it works
                  </.link>
                </li>
                <li>
                  <.link href={~p"/packs"} class="text-zinc-400 hover:text-zinc-100">Packs</.link>
                </li>
                <li>
                  <.link href={~p"/pricing"} class="text-zinc-400 hover:text-zinc-100">Pricing</.link>
                </li>
                <li>
                  <.link href={~p"/security"} class="text-zinc-400 hover:text-zinc-100">
                    Security
                  </.link>
                </li>
                <li>
                  <.link href={~p"/zero-trust"} class="text-zinc-400 hover:text-zinc-100">
                    Zero Trust
                  </.link>
                </li>
                <li>
                  <.link href={~p"/docs"} class="text-zinc-400 hover:text-zinc-100">Docs</.link>
                </li>
                <li>
                  <.link href={~p"/guides"} class="text-zinc-400 hover:text-zinc-100">Guides</.link>
                </li>
                <li>
                  <.link href={~p"/changelog"} class="text-zinc-400 hover:text-zinc-100">
                    Changelog
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Use cases</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link
                    href={~p"/use-cases/csi-data-loss"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    The 33-hour wipe
                  </.link>
                </li>
                <li>
                  <.link href={~p"/use-cases/ingress-502"} class="text-zinc-400 hover:text-zinc-100">
                    The fleet-wide 502
                  </.link>
                </li>
                <li>
                  <.link href={~p"/use-cases"} class="text-zinc-400 hover:text-zinc-100">
                    All use cases
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Compare</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/compare/raw-ssh-for-ai"} class="text-zinc-400 hover:text-zinc-100">
                    SSH vs emisar
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/compare/custom-mcp-server"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    Custom MCP vs emisar
                  </.link>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Company</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/about"} class="text-zinc-400 hover:text-zinc-100">About</.link>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    GitHub <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <a
                    href={
                      Application.get_env(:emisar_web, :status_page_url, "https://status.emisar.dev")
                    }
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    Status <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <a href="mailto:support@emisar.dev" class="text-zinc-400 hover:text-zinc-100">
                    Contact
                  </a>
                </li>
              </ul>
            </div>

            <div>
              <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Legal</h2>
              <ul class="mt-4 space-y-3 text-sm">
                <li>
                  <.link href={~p"/trust"} class="text-zinc-400 hover:text-zinc-100">
                    Trust &amp; compliance
                  </.link>
                </li>
                <li>
                  <.link href={~p"/privacy"} class="text-zinc-400 hover:text-zinc-100">Privacy</.link>
                </li>
                <li>
                  <.link href={~p"/terms"} class="text-zinc-400 hover:text-zinc-100">Terms</.link>
                </li>
                <li>
                  <.link href={~p"/dpa"} class="text-zinc-400 hover:text-zinc-100">DPA</.link>
                </li>
                <li>
                  <.link href={~p"/refund-policy"} class="text-zinc-400 hover:text-zinc-100">
                    Refund Policy
                  </.link>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar/blob/main/.github/SECURITY.md"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    Security policy
                    <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
                <li>
                  <a
                    href="https://github.com/andrewdryga/emisar/blob/main/LICENSE.md"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex items-center gap-1 text-zinc-400 hover:text-zinc-100"
                  >
                    License <.icon name="hero-arrow-top-right-on-square" class="h-3 w-3 opacity-60" />
                  </a>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="mt-12 flex flex-col gap-2 border-t border-zinc-800/70 pt-8 text-xs text-zinc-500 sm:flex-row sm:items-center sm:justify-between">
          <span>
            © {Date.utc_today().year} <a
              href="https://dryga.com"
              target="_blank"
              rel="noopener noreferrer"
              class="text-zinc-400 underline-offset-2 hover:text-zinc-200 hover:underline"
            >Andrii Dryga</a>. All rights reserved.
          </span>
          <span>
            v{@app_version}
            <span
              class="text-zinc-600"
              title="Server-render time (UTC). If it trails the real clock, a CDN/edge is serving this page from cache."
            >
              · {@rendered_at}
            </span>
            — built with
            <a
              href="https://coop.dryga.com/"
              target="_blank"
              rel="noopener noreferrer"
              class="text-zinc-400 underline-offset-2 hover:text-zinc-200 hover:underline"
            >
              co:op
            </a>
          </span>
        </div>
      </div>
    </footer>
    """
  end
end
