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
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 sm:w-96 rounded-xl p-4 pr-10 ring-1 backdrop-blur shadow-lg cursor-pointer",
        @kind == :info && "bg-emerald-950/80 text-emerald-100 ring-emerald-500/40",
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
        <div :for={action <- @actions} class="flex items-center justify-between gap-6 pt-2">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a button.

  Variants: `primary` (default, filled indigo), `secondary` (bordered neutral),
  `danger` (bordered rose — destructive actions read identically everywhere),
  `success` (filled emerald — affirmative), `caution` (filled amber — needs
  attention but isn't "safe", e.g. trusting a pack's new contents), `ghost`
  (text-only; tint with `tone="danger|caution|success"` for low-prominence inline
  actions like remove/revoke/restore). Sizes: `lg` (default), `md`, `sm`. An
  optional leading `icon` (heroicon name) renders before the label. `disabled` is
  honored by every variant. Pass `navigate`/`patch`/`href` and it renders a styled
  `<.link>` instead of a `<button>` — so a primary action that navigates reads
  identically to one that submits.

  ## Examples

      <.button>Send!</.button>
      <.button variant="danger" size="sm" phx-click="revoke" phx-value-id={id}>Revoke</.button>
      <.button variant="success" icon="hero-check">Approve</.button>
      <.button variant="caution" phx-click="trust">Trust new contents</.button>
      <.button variant="ghost" tone="danger" phx-click="remove">Remove</.button>
      <.button navigate={~p"/app/runbooks/new"} icon="hero-plus">New runbook</.button>
  """
  attr :type, :string, default: nil

  attr :variant, :string,
    default: "primary",
    values: ~w(primary secondary danger success caution ghost)

  attr :tone, :string,
    default: "neutral",
    values: ~w(neutral danger caution success),
    doc: ~s(tints a variant="ghost" text button)

  attr :size, :string, default: "lg", values: ~w(sm md lg)
  attr :icon, :string, default: nil, doc: ~s(leading heroicon name, e.g. "hero-plus")
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value href navigate patch method download)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns)
      when is_map_key(rest, :href) or is_map_key(rest, :navigate) or is_map_key(rest, :patch) do
    ~H"""
    <.link
      class={[button_base(), button_variant(@variant, @tone), button_size(@size), @class]}
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
      class={[button_base(), button_variant(@variant, @tone), button_size(@size), @class]}
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

  defp button_variant("primary", _tone),
    do:
      "bg-indigo-500 font-semibold text-zinc-950 shadow-sm hover:bg-indigo-400 active:bg-indigo-600 focus-visible:outline-indigo-400"

  defp button_variant("success", _tone),
    do:
      "bg-emerald-500 font-semibold text-zinc-950 shadow-sm hover:bg-emerald-400 active:bg-emerald-600 focus-visible:outline-emerald-400"

  # Caution: filled amber for attention-worthy actions where success-green
  # would wrongly read as "safe" — e.g. trusting a pack's new contents.
  defp button_variant("caution", _tone),
    do:
      "bg-amber-500 font-semibold text-amber-950 shadow-sm hover:bg-amber-400 active:bg-amber-600 focus-visible:outline-amber-400"

  defp button_variant("danger", _tone),
    do:
      "border border-rose-500/40 font-medium text-rose-200 hover:bg-rose-500/10 focus-visible:outline-rose-400"

  defp button_variant("secondary", _tone),
    do:
      "border border-zinc-800 font-medium text-zinc-200 hover:bg-zinc-900 focus-visible:outline-zinc-600"

  # Ghost is the only tone-aware variant: a text-only button tinted by `tone`,
  # for low-prominence inline actions (remove, revoke, suspend, restore).
  defp button_variant("ghost", "danger"),
    do: "font-medium text-rose-300 hover:bg-rose-500/10 focus-visible:outline-rose-400"

  defp button_variant("ghost", "caution"),
    do: "font-medium text-amber-300 hover:bg-amber-500/10 focus-visible:outline-amber-400"

  defp button_variant("ghost", "success"),
    do: "font-medium text-emerald-300 hover:bg-emerald-500/10 focus-visible:outline-emerald-400"

  defp button_variant("ghost", _neutral),
    do: "font-medium text-zinc-300 hover:bg-zinc-900 focus-visible:outline-zinc-600"

  defp button_size("lg"), do: "px-4 py-2.5 text-sm"
  defp button_size("md"), do: "px-3 py-1.5 text-sm"
  defp button_size("sm"), do: "px-2.5 py-1 text-xs"

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
  attr :tone, :string, default: "neutral", values: ~w(neutral danger)
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

  defp icon_button_tone("neutral"), do: "hover:text-zinc-200 focus-visible:outline-zinc-600"
  defp icon_button_tone("danger"), do: "hover:text-rose-300 focus-visible:outline-rose-400"

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
          class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40 focus:ring-offset-0"
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
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          @errors == [] && "ring-zinc-800 focus:ring-indigo-500",
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500"
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
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "min-h-[6rem] ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          @errors == [] && "ring-zinc-800 focus:ring-indigo-500",
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500",
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
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          @errors == [] && "ring-zinc-800 focus:ring-indigo-500",
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
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
          @errors == [] && "ring-zinc-800 focus:ring-indigo-500",
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
  A standalone checkbox — the standard indigo accent + `focus:ring-2` ring +
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
        class="h-4 w-4 rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-2 focus:ring-indigo-500/40 focus:ring-offset-0 disabled:opacity-50"
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
  A multi-`<select>` (Cmd/Ctrl-click to add) — wraps `<.select multiple>` so the
  markup stays in one place, and owns the two things every call site otherwise
  duplicates: the `size` heuristic (clamp the visible rows to the option count,
  3–6, so the box is neither a one-line scroll nor a wall) and the one standard
  "pick multiple" hint, so the copy can't drift (it had: "⌘/Ctrl-click or
  Shift+↑/↓" one place, "Cmd/Ctrl-click to select multiple." another).

  Same per-option contract as `<.select>`: option maps `%{value:, label:,
  disabled:, selected:}`, rendered escaped through HEEx (IL-16). Pass `hint?:
  false` to suppress the hint where space is tight; `size` to override the
  clamp.

      <.multi_select name="groups[]" options={@group_options} />
  """
  attr :id, :any, default: nil
  attr :name, :any, required: true
  attr :label, :string, default: nil
  attr :label_variant, :atom, default: :default, values: [:default, :eyebrow]
  attr :hint?, :boolean, default: true
  attr :size, :integer, default: nil, doc: "overrides the row-count clamp"
  attr :errors, :list, default: []

  attr :options, :list,
    required: true,
    doc: "option maps: %{value:, label:, disabled:, selected:}"

  attr :rest, :global, include: ~w(disabled form)

  def multi_select(assigns) do
    # `assign_new` won't override the `nil` the attr default already set, so
    # fall back explicitly when no `size` was passed.
    assigns = assign(assigns, :size, assigns.size || multi_select_size(assigns.options))

    ~H"""
    <.select
      id={@id}
      name={@name}
      label={@label}
      label_variant={@label_variant}
      multiple
      size={@size}
      options={@options}
      errors={@errors}
      {@rest}
    />
    <p :if={@hint?} class="mt-1 text-[10px] text-zinc-500">⌘/Ctrl-click to select multiple.</p>
    """
  end

  # Show enough rows to scan without scrolling, but cap it so a long fleet
  # doesn't grow the box into a wall; floor at 3 so a one-option list still
  # reads as a multi-select.
  defp multi_select_size(options), do: options |> length() |> max(3) |> min(6)

  @doc """
  Renders a form label. `:default` is the standard `text-sm` form label;
  `:eyebrow` is the compact small-caps label the dense editors use above their
  fields. One component so the two field-label treatments don't drift into more.
  """
  attr :for, :string, default: nil
  attr :variant, :atom, default: :default, values: [:default, :eyebrow]
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class={label_variant(@variant)}>
      {render_slot(@inner_block)}
    </label>
    """
  end

  defp label_variant(:default), do: "block text-sm font-medium text-zinc-200"

  defp label_variant(:eyebrow),
    do: "block text-[10px] font-semibold uppercase tracking-wider text-zinc-500"

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
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
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
  and the in-app shell. The icon SVG already encodes the dark-theme
  white + emerald palette, so it renders correctly on any zinc-950
  background without tinting.
  """
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :wordmark, :boolean, default: true
  attr :class, :string, default: nil

  def brand(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-3", @class]}>
      <img src={~p"/images/emisar-icon.svg"} alt="emisar" class={brand_icon_class(@size)} />
      <span :if={@wordmark} class={brand_wordmark_class(@size)}>emisar</span>
    </span>
    """
  end

  defp brand_icon_class(:sm), do: "h-7 w-7"
  defp brand_icon_class(:md), do: "h-9 w-9"
  defp brand_icon_class(:lg), do: "h-11 w-11"

  defp brand_wordmark_class(:sm), do: "text-base font-bold tracking-tight"
  defp brand_wordmark_class(:md), do: "text-xl font-bold tracking-tight"
  defp brand_wordmark_class(:lg), do: "text-2xl font-bold tracking-tight"

  @doc """
  Two-column auth-flow layout: marketing copy on the left, form on the
  right. Used by sign in / sign up / magic link / password reset.
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def auth_layout(assigns) do
    ~H"""
    <div class="grid min-h-screen grid-cols-1 lg:grid-cols-2">
      <div class="hidden bg-gradient-to-br from-indigo-950 via-zinc-950 to-zinc-950 p-12 lg:flex lg:flex-col lg:justify-between">
        <a href="/" class="text-zinc-100">
          <.brand size={:md} />
        </a>

        <div class="max-w-md">
          <p class="text-2xl font-semibold leading-snug tracking-tight text-zinc-100">
            Give AI tools approved infrastructure actions, not SSH.
          </p>
          <ul class="mt-6 space-y-3 text-sm text-zinc-400">
            <li class="flex items-start gap-2.5">
              <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-emerald-400" />
              <span>Pre-approved playbooks instead of arbitrary shell</span>
            </li>
            <li class="flex items-start gap-2.5">
              <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-emerald-400" />
              <span>Fine-grained policy with human approvals for risky ops</span>
            </li>
            <li class="flex items-start gap-2.5">
              <.icon name="hero-check" class="mt-0.5 h-4 w-4 flex-none text-emerald-400" />
              <span>Hash-chained audit trail of every action and decision</span>
            </li>
          </ul>
        </div>

        <p class="text-xs text-zinc-500">© {Date.utc_today().year} emisar</p>
      </div>

      <div class="flex items-center justify-center p-6 lg:p-12">
        <div class="w-full max-w-md">
          <.link href={~p"/"} class="mb-12 inline-block lg:hidden">
            <.brand size={:md} />
          </.link>

          <h1 class="text-3xl font-bold tracking-tight text-zinc-50">{@title}</h1>
          <div class="mt-8">
            {render_slot(@inner_block)}
          </div>
        </div>
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
  attr :pending_approvals_count, :integer, default: 0
  attr :pending_packs_count, :integer, default: 0
  attr :fleet_all_offline?, :boolean, default: false
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
      <aside class="hidden w-64 flex-shrink-0 flex-col border-r border-zinc-900 bg-zinc-950/80 lg:sticky lg:top-0 lg:flex lg:h-screen">
        <.shell_brand
          current_account={@current_account}
          switchable_accounts={@switchable_accounts || [@current_account]}
        />
        <.shell_nav
          current_subject={@current_subject}
          section={@section}
          pending_approvals_count={@pending_approvals_count}
          pending_packs_count={@pending_packs_count}
          fleet_all_offline?={@fleet_all_offline?}
        />
        <.shell_user current_user={@current_user} />
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
        <aside class="relative flex h-full w-72 max-w-[80vw] flex-col border-r border-zinc-900 bg-zinc-950 shadow-2xl">
          <div class="flex items-center justify-between border-b border-zinc-900 px-4 py-3">
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
            current_subject={@current_subject}
            section={@section}
            pending_approvals_count={@pending_approvals_count}
            pending_packs_count={@pending_packs_count}
            fleet_all_offline?={@fleet_all_offline?}
          />
          <.shell_user current_user={@current_user} />
        </aside>
      </div>

      <div class="flex min-w-0 flex-1 flex-col">
        <%!-- Portal-wide nudge: a signed-in user whose email isn't
             confirmed yet. Shown on every page until they verify; the
             "Resend" button is handled by the global `:email_confirmation`
             on_mount hook so it works regardless of which LV is mounted. --%>
        <div
          :if={@current_user && is_nil(@current_user.confirmed_at)}
          class="flex flex-wrap items-center justify-between gap-3 border-b border-amber-500/30 bg-amber-500/10 px-4 py-2.5 sm:px-6"
        >
          <p class="flex items-center gap-2 text-sm text-amber-200">
            <.icon name="hero-envelope" class="h-4 w-4 shrink-0" />
            <span>
              Verify your email — we sent a confirmation link to <span class="font-medium text-amber-100">{@current_user.email}</span>.
            </span>
          </p>
          <button
            type="button"
            phx-click="resend_confirmation"
            class="shrink-0 rounded-md bg-amber-500/20 px-3 py-1.5 text-xs font-semibold text-amber-100 ring-1 ring-amber-500/40 hover:bg-amber-500/30"
          >
            Resend email
          </button>
        </div>

        <header class="flex h-16 items-center gap-3 border-b border-zinc-900 bg-zinc-950 px-4 sm:px-6">
          <%!-- Mobile hamburger (hidden on lg) --%>
          <button
            type="button"
            aria-label="Open menu"
            class="-ml-1.5 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 lg:hidden"
            phx-click={
              JS.show(to: "#mobile-nav", display: "block")
              |> JS.add_class("overflow-hidden", to: "body")
            }
          >
            <.icon name="hero-bars-3" class="h-5 w-5" />
          </button>
          <h1 class="min-w-0 flex-1 truncate text-base font-semibold tracking-tight sm:text-lg">
            {render_slot(@title)}
          </h1>
          <div class="flex items-center gap-2 sm:gap-3">{render_slot(@actions)}</div>
        </header>

        <main class="flex-1 overflow-x-hidden p-4 sm:p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  # -- shell sub-components (shared between desktop + mobile) ----------

  attr :current_account, :map, required: true
  attr :switchable_accounts, :list, required: true

  defp shell_brand(assigns) do
    others =
      Enum.reject(assigns.switchable_accounts, &(&1.id == assigns.current_account.id))

    assigns = assign(assigns, :other_accounts, others)

    ~H"""
    <details class="group relative border-b border-zinc-900">
      <summary class="flex h-16 cursor-pointer list-none items-center gap-3 px-2 transition hover:bg-zinc-900/40 lg:px-6">
        <img src={~p"/images/emisar-icon.svg"} alt="" class="h-8 w-8 shrink-0" />
        <div class="min-w-0 flex-1">
          <div class="truncate font-bold tracking-tight">emisar</div>
          <div class="truncate text-xs text-zinc-500">{@current_account.name}</div>
        </div>
        <.icon
          name="hero-chevron-up-down"
          class="h-4 w-4 shrink-0 text-zinc-500 transition group-open:text-zinc-300"
        />
      </summary>

      <div class="absolute left-2 right-2 top-full z-30 mt-1 overflow-hidden rounded-lg border border-zinc-800 bg-zinc-950 shadow-2xl lg:left-4 lg:right-4">
        <div class="border-b border-zinc-900 px-3 py-2">
          <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-zinc-500">
            Switch workspace
          </p>
        </div>

        <ul class="max-h-[60vh] overflow-y-auto py-1">
          <li>
            <div class="flex items-center gap-2 px-3 py-2 text-sm">
              <.icon name="hero-check" class="h-4 w-4 shrink-0 text-emerald-400" />
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
                  <span class="grid h-4 w-4 shrink-0 place-items-center rounded-sm bg-zinc-800 text-[10px] font-semibold uppercase text-zinc-400">
                    {String.first(account.name)}
                  </span>
                  <span class="truncate">{account.name}</span>
                </button>
              </form>
            </li>
          <% end %>
        </ul>

        <div class="border-t border-zinc-900 p-1">
          <.link
            navigate={~p"/onboarding"}
            class="flex items-center gap-2 rounded-md px-3 py-2 text-sm text-zinc-300 transition hover:bg-zinc-900 hover:text-zinc-100"
          >
            <.icon name="hero-plus" class="h-4 w-4 shrink-0" />
            <span>Create new workspace</span>
          </.link>
        </div>
      </div>
    </details>
    """
  end

  attr :section, :atom, required: true
  attr :current_subject, :map, required: true
  attr :pending_approvals_count, :integer, default: 0
  attr :pending_packs_count, :integer, default: 0
  attr :fleet_all_offline?, :boolean, default: false

  defp shell_nav(assigns) do
    ~H"""
    <nav class="flex-1 space-y-0.5 overflow-y-auto px-3 py-3 text-sm">
      <.nav_link to={~p"/app"} active={@section == :dashboard} icon="hero-home">Dashboard</.nav_link>

      <.nav_group label="Runners" />
      <.nav_link
        to={~p"/app/runners"}
        active={@section == :runners}
        icon="hero-cpu-chip"
        alert={@fleet_all_offline?}
        alert_label="All runners offline"
      >
        Runners
      </.nav_link>
      <.nav_link
        :if={Emisar.Runners.subject_can_manage_auth_keys?(@current_subject)}
        to={~p"/app/settings/runners/auth-keys"}
        active={@section == :auth_keys}
        icon="hero-key"
      >
        Auth keys
      </.nav_link>

      <.nav_group label="Connections" />
      <.nav_link
        to={~p"/app/agents"}
        active={@section == :agents}
        icon="hero-sparkles"
      >
        LLM agents
      </.nav_link>

      <.nav_group label="Operations" />
      <.nav_link to={~p"/app/runs"} active={@section == :runs} icon="hero-bolt">Runs</.nav_link>
      <.nav_link
        to={~p"/app/approvals"}
        active={@section == :approvals}
        icon="hero-shield-check"
        badge={@pending_approvals_count}
      >
        Approvals
      </.nav_link>
      <.nav_link to={~p"/app/runbooks"} active={@section == :runbooks} icon="hero-book-open">
        Runbooks
      </.nav_link>
      <.nav_link to={~p"/app/policies"} active={@section == :policies} icon="hero-document-text">
        Policy
      </.nav_link>
      <.nav_link
        to={~p"/app/packs"}
        active={@section == :packs}
        icon="hero-cube"
        badge={@pending_packs_count}
      >
        Packs
      </.nav_link>
      <.nav_link to={~p"/app/audit"} active={@section == :audit} icon="hero-list-bullet">
        Audit
      </.nav_link>

      <.nav_group label="Account" />
      <.nav_link to={~p"/app/settings/profile"} active={@section == :profile} icon="hero-user-circle">
        Profile
      </.nav_link>
      <.nav_link to={~p"/app/settings/team"} active={@section == :team} icon="hero-user-group">
        Team
      </.nav_link>
      <.nav_link to={~p"/app/settings/billing"} active={@section == :billing} icon="hero-credit-card">
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
      class="flex items-center gap-3 rounded-lg px-3 py-1.5 text-zinc-400 transition hover:bg-zinc-900 hover:text-zinc-100"
    >
      <.icon name={@icon} class="h-4 w-4" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <.icon name="hero-arrow-top-right-on-square" class="h-3.5 w-3.5 text-zinc-600" />
    </.link>
    """
  end

  attr :label, :string, required: true

  defp nav_group(assigns) do
    ~H"""
    <div class="pt-3 pb-1 first:pt-0">
      <p class="px-3 text-[10px] font-semibold uppercase tracking-[0.12em] text-zinc-500">
        {@label}
      </p>
    </div>
    """
  end

  attr :current_user, :map, required: true

  defp shell_user(assigns) do
    ~H"""
    <div class="border-t border-zinc-900 p-4 text-sm">
      <div class="flex items-center gap-3">
        <.link
          navigate={~p"/app/settings/profile"}
          phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
          class="flex min-w-0 flex-1 items-center gap-3 rounded-lg p-1 -m-1 transition hover:bg-zinc-900"
          aria-label="Open profile settings"
        >
          <span class="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-zinc-800 text-xs font-semibold uppercase">
            {String.first(@current_user.full_name || @current_user.email)}
          </span>
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
    <.link
      navigate={@to}
      phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-1.5 transition",
        @active && "bg-indigo-500/10 text-indigo-200",
        !@active && "text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
      ]}
    >
      <.icon name={@icon} class="h-4 w-4" />
      <span class="flex-1">{render_slot(@inner_block)}</span>
      <span
        :if={badge_visible?(@badge)}
        class="rounded-full bg-amber-500/20 px-2 py-0.5 text-[10px] font-semibold leading-none text-amber-200 ring-1 ring-inset ring-amber-500/30"
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
  """
  attr :run, :map, required: true
  attr :show_runner, :boolean, default: false

  def run_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/app/runs/#{@run.id}"}
      class="flex items-center justify-between gap-3 px-5 py-3 transition hover:bg-zinc-900/40"
    >
      <div class="min-w-0">
        <div class="truncate font-mono text-sm text-zinc-200">{@run.action_id}</div>
        <div class="truncate text-xs text-zinc-500">
          <span :if={@show_runner && @run.runner}>{"on #{@run.runner.name} · "}</span>
          <TimeHelpers.local_time value={@run.inserted_at} mode={:relative} />
        </div>
      </div>
      <.status_badge status={@run.status} class="shrink-0" />
    </.link>
    """
  end

  @doc """
  One stat in a header summary band — a coloured `value` + `label` (+ optional
  `hint`). Compose several in a flex row for an at-a-glance count strip (the
  Runners fleet health + the LLM-agents page).
  """
  attr :tone, :atom, required: true, values: [:emerald, :amber, :rose, :zinc]
  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  def summary_stat(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class={["h-1.5 w-1.5 shrink-0 rounded-full", summary_dot_class(@tone)]} aria-hidden="true">
      </span>
      <span class="tabular-nums text-zinc-100">{@value}</span>
      <span class="text-zinc-400">{@label}</span>
      <span :if={@hint} class="text-xs text-zinc-600">({@hint})</span>
    </div>
    """
  end

  # The status colour lives on the dot, not the number — the count itself reads
  # neutral so the strip stays a quiet at-a-glance band.
  defp summary_dot_class(:emerald), do: "bg-emerald-400"
  defp summary_dot_class(:amber), do: "bg-amber-400"
  defp summary_dot_class(:rose), do: "bg-rose-400"
  defp summary_dot_class(:zinc), do: "bg-zinc-600"

  @doc "Coloured pill for run/runner status — takes a string or an Ecto.Enum atom."
  attr :status, :any, required: true
  attr :class, :string, default: ""

  def status_badge(assigns) do
    assigns = assign(assigns, :status, to_string(assigns.status))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
      status_classes(@status),
      @class
    ]}>
      <span class={["h-1.5 w-1.5 rounded-full", status_dot(@status)]} />
      {format_status(@status)}
    </span>
    """
  end

  defp status_classes("success"), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp status_classes("connected"), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp status_classes("approved"), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp status_classes("published"), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp status_classes("running"), do: "bg-indigo-500/10 text-indigo-300 ring-indigo-500/30"
  defp status_classes("sent"), do: "bg-indigo-500/10 text-indigo-300 ring-indigo-500/30"
  defp status_classes("draft"), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"
  defp status_classes("pending"), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"
  defp status_classes("disconnected"), do: "bg-zinc-500/10 text-zinc-400 ring-zinc-500/30"
  defp status_classes("awaiting_approval"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp status_classes("pending_approval"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp status_classes("cancelled"), do: "bg-zinc-500/10 text-zinc-400 ring-zinc-500/30"
  defp status_classes("denied"), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"
  defp status_classes("expired"), do: "bg-zinc-500/10 text-zinc-500 ring-zinc-500/30"
  # Planned: a runbook work-list slot that hasn't dispatched its run yet —
  # dimmer than `pending` so the not-yet-started rows recede.
  defp status_classes("planned"), do: "bg-zinc-500/10 text-zinc-400 ring-zinc-500/20"

  defp status_classes(s)
       when s in [
              "failed",
              "error",
              "validation_failed",
              "unknown_action",
              "timed_out",
              "dispatch_failed"
            ],
       do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"

  defp status_classes(_), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"

  defp status_dot("success"), do: "bg-emerald-400"
  defp status_dot("connected"), do: "bg-emerald-400"
  defp status_dot("approved"), do: "bg-emerald-400"
  defp status_dot("published"), do: "bg-emerald-400"
  defp status_dot("running"), do: "bg-indigo-400 animate-pulse"
  defp status_dot("sent"), do: "bg-indigo-400"
  defp status_dot("draft"), do: "bg-zinc-500"
  defp status_dot("pending"), do: "bg-zinc-500"
  defp status_dot("disconnected"), do: "bg-zinc-600"
  defp status_dot("awaiting_approval"), do: "bg-amber-400 animate-pulse"
  defp status_dot("pending_approval"), do: "bg-amber-400 animate-pulse"
  defp status_dot("denied"), do: "bg-rose-400"
  defp status_dot("expired"), do: "bg-zinc-600"
  defp status_dot("planned"), do: "bg-zinc-600"

  defp status_dot(s)
       when s in [
              "failed",
              "error",
              "validation_failed",
              "unknown_action",
              "timed_out",
              "dispatch_failed"
            ],
       do: "bg-rose-400"

  defp status_dot(_), do: "bg-zinc-500"

  defp format_status("awaiting_approval"), do: "awaiting approval"
  defp format_status("pending_approval"), do: "awaiting approval"
  defp format_status("validation_failed"), do: "validation failed"
  defp format_status("unknown_action"), do: "unknown action"
  defp format_status("timed_out"), do: "timed out"
  defp format_status("dispatch_failed"), do: "dispatch failed"
  defp format_status(other), do: other

  @doc """
  A runner's `Runners.connection_state/1` atom → the display status string that
  `<.status_badge>` / `<.connection_dot>` understand (`:online` → "connected",
  `:offline` → "disconnected"). One place so the runners list + detail pages
  can't drift on the connection vocabulary.
  """
  def connection_status(:online), do: "connected"
  def connection_status(:offline), do: "disconnected"
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
    <div
      class={[
        "rounded-xl border border-zinc-900 bg-zinc-950/40",
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
  every "panel with a heading" reads the same (one heading size, one subtitle
  style, actions right-aligned). Pass `title` (and optional `:subtitle` /
  `:actions`); the body is the default slot.

      <.panel title="Default policy">
        <:subtitle>Applies to every runner unless a ruleset overrides it.</:subtitle>
        <.policy_fields ... />
      </.panel>

      <.panel title="Security">
        <:subtitle>When enforced, members without 2FA are funneled…</:subtitle>
        <:actions><.button>Enforce</.button></:actions>
        ...
      </.panel>
  """
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  attr :padding, :string, default: "p-5"
  attr :rest, :global
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <.card padding={@padding} class={@class} {@rest}>
      <header
        :if={@title || @subtitle != [] || @actions != []}
        class="mb-4 flex items-start justify-between gap-4"
      >
        <div class="min-w-0">
          <h2 :if={@title} class="text-sm font-semibold text-zinc-100">{@title}</h2>
          <p :if={@subtitle != []} class="mt-1 text-xs leading-relaxed text-zinc-500">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="shrink-0">{render_slot(@actions)}</div>
      </header>
      {render_slot(@inner_block)}
    </.card>
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
  The bare heading-row above an UNbordered list/table section (distinct from
  `<.panel>`, which owns a bordered header). A `text-sm` section title, an
  optional inline `<.count_badge>`, and an optional `:actions` slot.

      <.section_header title="Pending" count={@pending_metadata.count} count_tone={:amber} />
      <.section_header title="Connected agents" />
  """
  attr :title, :string, required: true
  attr :count, :integer, default: nil
  attr :count_tone, :atom, default: :amber, values: [:amber, :zinc, :indigo]
  attr :class, :string, default: nil
  slot :actions

  def section_header(assigns) do
    ~H"""
    <header class={["mb-3 flex items-center gap-2", @class]}>
      <h2 class="text-sm font-semibold text-zinc-100">{@title}</h2>
      <.count_badge count={@count} tone={@count_tone} />
      {render_slot(@actions)}
    </header>
    """
  end

  @doc """
  Small count pill beside a section title. Renders nothing for a nil/zero count.
  """
  attr :count, :integer, default: nil
  attr :tone, :atom, default: :amber, values: [:amber, :zinc, :indigo]

  def count_badge(assigns) do
    ~H"""
    <span
      :if={@count && @count > 0}
      class={["rounded px-1.5 py-0.5 text-xs font-medium", count_badge_tone(@tone)]}
    >
      {@count}
    </span>
    """
  end

  defp count_badge_tone(:amber), do: "bg-amber-500/20 text-amber-200"
  defp count_badge_tone(:zinc), do: "bg-zinc-800 text-zinc-300"
  defp count_badge_tone(:indigo), do: "bg-indigo-500/20 text-indigo-200"

  @doc """
  Key-value row for detail panes:

      <.kv label="Hostname">{@runner.hostname || "—"}</.kv>
  """
  attr :label, :string, required: true
  slot :inner_block, required: true

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
  slot :inner_block, required: true

  def meta_field(assigns) do
    ~H"""
    <div class="min-w-0">
      <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">{@label}</div>
      <div class="mt-0.5 truncate">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Horizontal meta strip wrapper — the bordered rounded box that holds
  `<.meta_field>` cells under page titles on detail pages. Pass `cols`
  for an explicit column count at `lg+`; defaults to auto-fitting via
  `sm:grid-cols-3`.

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
      "grid grid-cols-2 gap-3 rounded-xl border border-zinc-900 bg-zinc-950/40 p-4 text-sm sm:grid-cols-3",
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
  attr :icon_tone, :atom, default: :zinc, values: [:zinc, :emerald, :amber, :rose, :indigo]
  attr :class, :string, default: nil
  slot :leading, doc: "a custom leading element (avatar, connection dot) — replaces the icon disc"
  slot :title, required: true
  slot :chips
  slot :meta
  slot :actions

  def list_row(assigns) do
    ~H"""
    <li class={["flex items-start gap-4 px-5 py-4", @class]}>
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
        <div :if={@meta != []} class="mt-1 truncate text-xs text-zinc-500">
          {render_slot(@meta)}
        </div>
      </div>

      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </li>
    """
  end

  defp row_icon_class(:emerald), do: "bg-emerald-500/15 text-emerald-300"
  defp row_icon_class(:amber), do: "bg-amber-500/15 text-amber-300"
  defp row_icon_class(:rose), do: "bg-rose-500/15 text-rose-300"
  defp row_icon_class(:indigo), do: "bg-indigo-500/15 text-indigo-300"
  defp row_icon_class(_zinc), do: "bg-zinc-900 text-zinc-400"

  @doc """
  Small inline chip — the rounded label that sits next to a row title
  or inside a chips slot. Variants: `:default` (zinc), `:indigo`,
  `:amber`, `:rose`, `:emerald`. With `mono`, renders monospace text.

      <.chip>group: default</.chip>
      <.chip tone={:rose}>Suspended</.chip>
  """
  attr :tone, :atom,
    default: :default,
    values: [:default, :indigo, :amber, :rose, :emerald]

  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class={[
      "rounded px-1.5 py-0.5 text-[10px] font-medium",
      chip_class(@tone),
      @mono && "font-mono"
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_class(:indigo), do: "bg-indigo-500/15 text-indigo-200 ring-1 ring-indigo-500/30"
  defp chip_class(:amber), do: "bg-amber-500/15 text-amber-200 ring-1 ring-amber-500/30"
  defp chip_class(:rose), do: "bg-rose-500/15 text-rose-200 ring-1 ring-rose-500/30"
  defp chip_class(:emerald), do: "bg-emerald-500/15 text-emerald-200 ring-1 ring-emerald-500/30"
  defp chip_class(_default), do: "bg-zinc-800/80 text-zinc-300"

  @doc """
  Page-level content container — `mx-auto max-w-Nxl space-y-6`. Use
  on every authenticated page so widths and vertical rhythm stay
  consistent.

      <.page_container>
        ... sections ...
      </.page_container>
  """
  attr :max, :string,
    default: "5xl",
    values: ~w(2xl 3xl 4xl 5xl 6xl 7xl)

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def page_container(assigns) do
    # Use a static map so Tailwind's purge picks up every class.
    width =
      %{
        "2xl" => "max-w-2xl",
        "3xl" => "max-w-3xl",
        "4xl" => "max-w-4xl",
        "5xl" => "max-w-5xl",
        "6xl" => "max-w-6xl",
        "7xl" => "max-w-7xl"
      }[assigns.max]

    assigns = assign(assigns, :width, width)

    ~H"""
    <div class={["mx-auto space-y-6", @width, @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Inline "back" breadcrumb for detail pages. Renders as a small label
  above the page title slot, so the operator always sees where they
  came from without a separate breadcrumb trail.

      <:title>
        <.back_link navigate={~p"/app/runs"}>Runs</.back_link>
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
  runbook editor) — a `<.back_link>` breadcrumb to the parent list followed by
  the entity heading. Goes in the `<.dashboard_shell>` `:title` slot, so every
  detail page opens with the same "where am I / what is this" shape and one
  place owns the breadcrumb + heading spacing. The heading markup is the default
  slot, so each page keeps its own (mono id, status dot, version suffix, …).

  The horizontal `<.meta_strip>` stays a sibling in the page body — it lives in
  a different region (the scrolling `<main>`, not the sticky title bar), so it
  can't share this DOM node.

      <:title>
        <.detail_header back="Runners" navigate={~p"/app/runners"}>
          {@runner.name}
        </.detail_header>
      </:title>
  """
  attr :navigate, :string, required: true
  attr :back, :string, required: true, doc: "the parent list's breadcrumb label"
  slot :inner_block, required: true

  def detail_header(assigns) do
    ~H"""
    <.back_link navigate={@navigate}>{@back}</.back_link>{render_slot(@inner_block)}
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
  variant: `:danger` (rose — disable/delete, the default) or `:success` (emerald
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
        <.button variant={confirm_zone_variant(@tone)} size="md" data-confirm={@confirm} {@rest}>
          {render_slot(@inner_block)}
        </.button>
      </div>
    </section>
    """
  end

  # `:danger` keeps the original rose danger-zone styling; `:success` is the
  # emerald twin for restorative actions, so both read alike structurally.
  defp confirm_zone_section(:danger), do: "border-rose-900/40 bg-rose-950/20"
  defp confirm_zone_section(:success), do: "border-emerald-500/30 bg-emerald-500/[0.04]"
  defp confirm_zone_title(:danger), do: "text-rose-200"
  defp confirm_zone_title(:success), do: "text-emerald-100"
  defp confirm_zone_body(:danger), do: "text-rose-300/70"
  defp confirm_zone_body(:success), do: "text-emerald-300/70"
  defp confirm_zone_variant(:danger), do: "danger"
  defp confirm_zone_variant(:success), do: "success"

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
            <.button variant="secondary" size="md" type="button" phx-click={hide_confirm_dialog(@id)}>
              Cancel
            </.button>
            <%!-- Enabled only when the typed value matches a NON-empty token —
                 a blank token can never be confirmed, so a page-level dialog
                 with no target selected yet stays inert. --%>
            <.button
              variant="danger"
              size="md"
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
  Statistic tile used on the dashboard.

      <.stat label="Runners online" value={@runners_connected} hint={"of #{@total} total"} />
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :class, :string, default: nil

  def stat(assigns) do
    ~H"""
    <.card padding="p-6" class={@class}>
      <div class="text-xs uppercase tracking-wider text-zinc-500">{@label}</div>
      <div class={["mt-2 text-3xl font-semibold", stat_value_class(@value)]}>
        {stat_value(@value)}
      </div>
      <%= if @hint do %>
        <div class="mt-1 text-xs text-zinc-500">{@hint}</div>
      <% end %>
    </.card>
    """
  end

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
  attr :on_failure_path, :string, default: "/app/settings/runners/auth-keys"

  def install_wizard(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl">
      <div class="rounded-2xl border border-zinc-900 bg-gradient-to-b from-indigo-950/40 to-zinc-950/60 p-8 sm:p-10">
        <header class="flex items-center gap-3">
          <span class="grid h-10 w-10 place-items-center rounded-xl bg-indigo-500/20 text-indigo-300 ring-1 ring-indigo-500/40">
            <.icon name="hero-rocket-launch" class="h-5 w-5" />
          </span>
          <div>
            <h2 class="text-xl font-semibold text-zinc-50">Connect a runner</h2>
            <p class="text-sm text-zinc-400">
              Two minutes. Pick a Linux or macOS host, paste the one-liner.
            </p>
          </div>
        </header>

        <%= cond do %>
          <% is_binary(@install_command) -> %>
            <div class="mt-8 space-y-6">
              <div>
                <div class="text-xs uppercase tracking-wider text-zinc-500">
                  Run on any Linux or macOS host
                </div>
                <div class="mt-2 flex items-center gap-2 rounded-lg border border-zinc-800 bg-black/60 p-4 font-mono text-xs">
                  <pre class="flex-1 whitespace-pre-wrap break-all text-zinc-300">{@install_command}</pre>
                  <%!-- Copy the literal string, not the rendered element's
                       innerText: the leading space (HISTCONTROL=ignorespace)
                       is significant and the selector path would strip it. --%>
                  <.copy_button
                    text={@install_command}
                    class="self-start bg-indigo-500/20 px-2 text-indigo-200 hover:bg-indigo-500/30 font-semibold"
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
                    and carries a single-use key that enrolls this host to run infrastructure
                    actions on your fleet. Treat it like a password — paste it straight onto the
                    host, never into a chat or ticket.
                  </p>
                </div>
                <p class="mt-2 text-xs leading-5 text-zinc-500">
                  The leading space keeps the key out of your shell history. It's a plain shell
                  script — <.link
                    href="/install.sh"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-semibold text-indigo-400 hover:text-indigo-300"
                  >read it first →</.link>: it verifies the download's SHA-256, runs the runner as a
                  dedicated <code class="font-mono text-zinc-400">emisar</code>
                  user (not root) under a systemd unit, and only dials out — nothing listens on the host.
                </p>
              </div>

              <div class="rounded-lg border border-zinc-800 bg-zinc-950/60 p-4">
                <div class="flex items-center gap-3">
                  <span class="relative flex h-3 w-3">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-indigo-500/50">
                    </span>
                    <span class="relative inline-flex h-3 w-3 rounded-full bg-indigo-400"></span>
                  </span>
                  <div class="text-sm text-zinc-300">
                    Waiting for a runner to connect. This page will refresh automatically.
                  </div>
                </div>

                <%!-- After the grace period with no join (the install page's
                     watchdog flips show_troubleshooting) the likely funnel
                     failure is a wrong/truncated key, :443 firewalled, or a
                     non-systemd host — none of which the pulse alone reveals.
                     Surface the same checks the quickstart doc carries. --%>
                <div
                  :if={@show_troubleshooting}
                  class="mt-3 border-t border-zinc-800 pt-3 text-xs leading-5 text-zinc-400"
                >
                  <div class="font-semibold text-zinc-300">Not seeing it yet? Check the host:</div>
                  <ul class="mt-1.5 space-y-1.5">
                    <li>
                      · it can reach <code class="font-mono text-zinc-300">{@base_url}</code>
                      over outbound HTTPS (nothing needs to listen on it);
                    </li>
                    <li>
                      · you ran the whole line with <code class="font-mono text-zinc-300">sudo</code>
                      and the key wasn't truncated on paste;
                    </li>
                    <li>
                      · it runs systemd — watch the runner's own logs with <code class="font-mono text-zinc-300">journalctl -u emisar -f</code>.
                    </li>
                  </ul>
                </div>
              </div>

              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.link
                  href="/docs/quickstart"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="rounded-xl border border-zinc-800 bg-zinc-950/60 p-4 transition hover:bg-zinc-900/60"
                >
                  <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
                    <.icon name="hero-book-open" class="h-4 w-4 text-indigo-400" /> Installation guide
                    <.icon
                      name="hero-arrow-top-right-on-square"
                      class="ml-auto h-3.5 w-3.5 text-zinc-600"
                    />
                  </div>
                  <p class="mt-1 text-xs text-zinc-500">
                    Image-bake, cloud-init, manual install.
                  </p>
                </.link>
                <.link
                  navigate="/packs"
                  class="rounded-xl border border-zinc-800 bg-zinc-950/60 p-4 transition hover:bg-zinc-900/60"
                >
                  <div class="flex items-center gap-2 text-sm font-semibold text-zinc-200">
                    <.icon name="hero-cube-transparent" class="h-4 w-4 text-indigo-400" />
                    Pack registry
                    <.icon name="hero-arrow-right" class="ml-auto h-3.5 w-3.5 text-zinc-600" />
                  </div>
                  <p class="mt-1 text-xs text-zinc-500">
                    Browse linux-core, cassandra, showcase. Install snippets included.
                  </p>
                </.link>
              </div>
            </div>
          <% @install_command == :mint_failed -> %>
            <div class="mt-8 rounded-lg border border-amber-500/30 bg-amber-500/10 p-4 text-sm text-amber-200/90">
              We couldn't mint a bootstrap auth key just now. Open
              <.link navigate={@on_failure_path} class="font-semibold underline">
                settings → auth keys
              </.link>
              and create one manually, or refresh this page to try again.
            </div>
          <% true -> %>
            <div class="mt-8 flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-950/60 p-4 text-sm text-zinc-400">
              <span class="hero-arrow-path h-4 w-4 animate-spin"></span>
              Generating your install command…
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Empty-state panel: a centered icon + headline + body + optional CTA.

      <.empty_state icon="hero-cpu-chip" title="No runners yet">
        Issue an auth key and run the installer on a host.
        <:cta navigate={~p"/app/settings/runners/auth-keys"}>Issue auth key</:cta>
      </.empty_state>
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :variant, :atom, default: :boxed, values: [:boxed, :bare]
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
      <.icon name={@icon} class={empty_state_icon(@variant, @tone)} />
      <h2 class={empty_state_title(@variant, @tone)}>{@title}</h2>
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

  defp empty_state_icon(:boxed, tone), do: "mx-auto h-10 w-10 " <> empty_state_icon_color(tone)
  defp empty_state_icon(:bare, tone), do: "mx-auto h-8 w-8 " <> empty_state_icon_color(tone)

  defp empty_state_icon_color(:zinc), do: "text-zinc-700"
  defp empty_state_icon_color(:danger), do: "text-rose-400/70"

  defp empty_state_title(:boxed, tone),
    do: "mt-4 text-base font-semibold " <> empty_state_title_color(:boxed, tone)

  defp empty_state_title(:bare, tone),
    do: "mt-3 text-sm font-medium " <> empty_state_title_color(:bare, tone)

  defp empty_state_title_color(:boxed, :zinc), do: "text-zinc-200"
  defp empty_state_title_color(:bare, :zinc), do: "text-zinc-300"
  defp empty_state_title_color(_variant, :danger), do: "text-rose-200"

  defp empty_state_body(:boxed), do: "mt-2 text-sm text-zinc-500"
  defp empty_state_body(:bare), do: "mt-1 text-xs leading-relaxed text-zinc-500"

  defp empty_state_cta(:boxed),
    do:
      "mt-6 inline-flex items-center gap-2 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"

  defp empty_state_cta(:bare),
    do:
      "mt-4 inline-flex items-center gap-2 text-sm font-medium text-indigo-400 hover:text-indigo-300"

  @doc """
  "A runner is offline" notice — a `hero-signal-slash` block whose colour
  encodes SEVERITY, the one place that convention lives so it can't drift:

    * `:info` (zinc) — informational, nothing's wrong (e.g. "you can still
      dispatch; the run queues until it reconnects").
    * `:caution` (amber) — this run/action may be affected.
    * `:critical` (rose) — the whole fleet is down; nothing can dispatch.

      <.offline_notice severity={:caution} title="Queued — runner offline">
        Waiting for {name} to reconnect before this run can dispatch.
        <:action><.link navigate={~p"/app/runners"}>View runners</.link></:action>
      </.offline_notice>
  """
  attr :severity, :atom, default: :caution, values: [:info, :caution, :critical]
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :action

  def offline_notice(assigns) do
    ~H"""
    <div class={["flex items-start gap-3 rounded-xl border p-4", offline_box(@severity), @class]}>
      <.icon name="hero-signal-slash" class={offline_icon(@severity)} />
      <div class="flex-1">
        <p class={["text-sm font-semibold", offline_title(@severity)]}>{@title}</p>
        <p class={["mt-1 text-xs", offline_body(@severity)]}>{render_slot(@inner_block)}</p>
      </div>
      <div :if={@action != []} class="shrink-0 self-start">{render_slot(@action)}</div>
    </div>
    """
  end

  defp offline_box(:info), do: "border-zinc-700 bg-zinc-900/40"
  defp offline_box(:caution), do: "border-amber-500/30 bg-amber-500/[0.06]"
  defp offline_box(:critical), do: "border-rose-500/40 bg-rose-500/10"

  defp offline_icon(:info), do: "mt-0.5 h-5 w-5 flex-none text-zinc-400"
  defp offline_icon(:caution), do: "mt-0.5 h-5 w-5 flex-none text-amber-300"
  defp offline_icon(:critical), do: "mt-0.5 h-5 w-5 flex-none text-rose-300"

  defp offline_title(:info), do: "text-zinc-200"
  defp offline_title(:caution), do: "text-amber-100"
  defp offline_title(:critical), do: "text-rose-100"

  defp offline_body(:info), do: "text-zinc-400"
  defp offline_body(:caution), do: "text-amber-200/80"
  defp offline_body(:critical), do: "text-rose-200/90"

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
    <span class={[
      "rounded px-2 py-0.5 text-xs font-semibold uppercase tracking-wider ring-1 ring-inset",
      risk_classes(@risk),
      @class
    ]}>
      {@risk}
    </span>
    """
  end

  defp risk_classes("low"), do: "bg-emerald-500/10 text-emerald-300 ring-emerald-500/30"
  defp risk_classes("medium"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp risk_classes("high"), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"
  defp risk_classes("critical"), do: "bg-rose-600/15 text-rose-200 ring-rose-500/40"
  defp risk_classes(_), do: "bg-zinc-500/10 text-zinc-300 ring-zinc-500/30"

  @doc """
  Square uppercase status/label tag — `<.chip>`'s ringed sibling, for short
  labels like a pack's trust state or a plan's "Current"/"Most popular". One
  padding + one tone-opacity per color. (`<.risk_pill>` is the larger text-xs
  variant reserved for the risk tier.)

      <.tag tone={:emerald}>Trusted</.tag>
      <.tag tone={:amber} class="ml-2">Pending</.tag>
  """
  attr :tone, :atom, default: :zinc, values: [:zinc, :emerald, :amber, :rose, :indigo]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def tag(assigns) do
    ~H"""
    <span class={[
      "rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider ring-1 ring-inset",
      tag_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tag_tone(:emerald), do: "bg-emerald-500/15 text-emerald-200 ring-emerald-500/30"
  defp tag_tone(:amber), do: "bg-amber-500/15 text-amber-200 ring-amber-500/30"
  defp tag_tone(:rose), do: "bg-rose-500/15 text-rose-200 ring-rose-500/30"
  defp tag_tone(:indigo), do: "bg-indigo-500/15 text-indigo-200 ring-indigo-500/30"
  defp tag_tone(_), do: "bg-zinc-500/15 text-zinc-300 ring-zinc-500/30"

  @doc """
  "expires in 3h" badge for a held approval request — amber when under two
  hours remain so an approver can triage by urgency (the requester's run
  auto-cancels at expiry). Renders nothing without an expiry.

      <.approval_expiry expires_at={@request.expires_at} />
  """
  attr :expires_at, :any, default: nil
  attr :class, :string, default: nil

  def approval_expiry(assigns) do
    ~H"""
    <span
      :if={@expires_at}
      class={["inline-flex items-center gap-1 text-xs", expiry_class(@expires_at), @class]}
    >
      <%!-- {" "} is a literal space HEEx won't trim — without it the
           formatter drops the component to its own line and "expires"
           abuts the time ("expires3h ago"). --%>
      <.icon name="hero-clock" class="h-3 w-3" />
      expires{" "}<TimeHelpers.local_time value={@expires_at} mode={:relative} />
    </span>
    """
  end

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
  "Reveal once" banner for newly-created secrets — auth keys, API
  keys. Shown until dismissed; warns the operator the value won't be
  shown again.

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
  """
  attr :title, :string, required: true
  attr :secret, :string, required: true
  attr :on_dismiss, :string, required: true
  slot :inner_block, required: true

  slot :install_command do
    attr :label, :string
  end

  def secret_reveal(assigns) do
    ~H"""
    <div class="mb-6 rounded-xl bg-amber-500/10 p-6 ring-1 ring-amber-500/30">
      <div class="flex items-start justify-between gap-4">
        <div class="flex-1">
          <h2 class="text-sm font-semibold text-amber-100">{@title}</h2>
          <p class="mt-1 text-xs text-amber-200/80">{render_slot(@inner_block)}</p>

          <%!-- Same copy pattern as the dashboard install reveal:
               grab text from the visible `<code>` instead of
               interpolating into a JS string literal (safer + escape-
               proof), and flip the label to "Copied" for 1.5s as
               visible click feedback. --%>
          <div class="mt-4 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-3 ring-1 ring-zinc-800">
            <pre
              id="reveal-secret"
              class="flex-1 whitespace-pre-wrap break-all font-mono text-xs text-zinc-100"
            >{@secret}</pre>
            <.copy_button
              target="#reveal-secret"
              class="bg-amber-500/20 px-2 text-amber-100 hover:bg-amber-500/30 font-semibold"
            >
              Copy
            </.copy_button>
          </div>

          <%= for {cmd, idx} <- Enum.with_index(@install_command) do %>
            <div class="mt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-amber-200/80">
                {cmd[:label] || "Install on a host"}
              </h3>
              <div class="mt-2 flex items-start gap-2 rounded-lg bg-zinc-950/80 p-3 ring-1 ring-zinc-800">
                <pre
                  id={"reveal-install-#{idx}"}
                  class="flex-1 whitespace-pre-wrap break-all font-mono text-xs text-zinc-300"
                >{render_slot(cmd)}</pre>
                <.copy_button
                  target={"#reveal-install-#{idx}"}
                  class="shrink-0 self-start bg-amber-500/20 px-2 text-amber-100 hover:bg-amber-500/30 font-semibold"
                >
                  Copy
                </.copy_button>
              </div>
            </div>
          <% end %>
        </div>

        <button
          phx-click={@on_dismiss}
          class="rounded-lg p-1 text-amber-200/80 hover:bg-amber-500/10 hover:text-amber-100"
          aria-label="Dismiss"
        >
          <.icon name="hero-x-mark" class="h-5 w-5" />
        </button>
      </div>
    </div>
    """
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

        <%!-- Desktop nav: visible md+ --%>
        <nav class="hidden items-center gap-8 md:flex">
          <.marketing_nav_link href={~p"/packs"} active={@current == :packs}>
            Packs
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/pricing"} active={@current == :pricing}>
            Pricing
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/security"} active={@current == :security}>
            Security
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/docs"} active={@current == :docs}>Docs</.marketing_nav_link>
          <.marketing_nav_link href={~p"/changelog"} active={@current == :changelog}>
            Changelog
          </.marketing_nav_link>
          <.marketing_nav_link href={~p"/about"} active={@current == :about}>
            About
          </.marketing_nav_link>
        </nav>

        <%!-- Desktop CTAs: visible md+. A signed-in visitor gets a
             Dashboard link; everyone else gets Sign in / Start free. --%>
        <div class="hidden items-center gap-4 md:flex">
          <%= if @current_user do %>
            <.link
              href={~p"/app"}
              class="inline-flex items-center gap-2 whitespace-nowrap rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
            >
              Dashboard <.icon name="hero-arrow-right" class="h-4 w-4" />
            </.link>
          <% else %>
            <.link
              href={~p"/sign_in"}
              class="whitespace-nowrap text-sm font-semibold text-zinc-100 hover:text-indigo-300"
            >
              Sign in
            </.link>
            <.link
              href={~p"/sign_up"}
              class="whitespace-nowrap rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
            >
              Start free
            </.link>
          <% end %>
        </div>

        <%!-- Mobile hamburger: visible < md. Toggles the drawer
             below; uses the same JS dance as the in-app shell so
             the body lock works the same. --%>
        <button
          type="button"
          aria-label="Open menu"
          class="-mr-1.5 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 md:hidden"
          phx-click={
            JS.show(to: "#marketing-mobile-nav", display: "block")
            |> JS.add_class("overflow-hidden", to: "body")
          }
        >
          <.icon name="hero-bars-3" class="h-5 w-5" />
        </button>
      </div>

      <%!-- Mobile drawer — full screen overlay with primary nav
           + auth CTAs. Closes on link tap or Escape. --%>
      <div
        id="marketing-mobile-nav"
        class="fixed inset-0 z-50 hidden md:hidden"
        role="dialog"
        aria-modal="true"
        phx-window-keydown={
          JS.hide(to: "#marketing-mobile-nav")
          |> JS.remove_class("overflow-hidden", to: "body")
        }
        phx-key="escape"
      >
        <div
          class="absolute inset-0 bg-black/60"
          phx-click={
            JS.hide(to: "#marketing-mobile-nav")
            |> JS.remove_class("overflow-hidden", to: "body")
          }
        >
        </div>
        <aside class="relative ml-auto flex h-full w-80 max-w-[85vw] flex-col bg-zinc-950 shadow-2xl">
          <div class="flex items-center justify-between border-b border-zinc-900 px-5 py-4">
            <.brand size={:sm} />
            <button
              type="button"
              aria-label="Close menu"
              class="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
              phx-click={
                JS.hide(to: "#marketing-mobile-nav")
                |> JS.remove_class("overflow-hidden", to: "body")
              }
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>

          <nav class="flex-1 space-y-1 px-3 py-4 text-sm">
            <.marketing_mobile_link href={~p"/packs"} active={@current == :packs}>
              Packs
            </.marketing_mobile_link>
            <.marketing_mobile_link href={~p"/pricing"} active={@current == :pricing}>
              Pricing
            </.marketing_mobile_link>
            <.marketing_mobile_link href={~p"/security"} active={@current == :security}>
              Security
            </.marketing_mobile_link>
            <.marketing_mobile_link href={~p"/docs"} active={@current == :docs}>
              Docs
            </.marketing_mobile_link>
            <.marketing_mobile_link href={~p"/changelog"} active={@current == :changelog}>
              Changelog
            </.marketing_mobile_link>
            <.marketing_mobile_link href={~p"/about"} active={@current == :about}>
              About
            </.marketing_mobile_link>
          </nav>

          <div class="space-y-3 border-t border-zinc-900 p-5">
            <%= if @current_user do %>
              <.link
                href={~p"/app"}
                class="block w-full whitespace-nowrap rounded-lg bg-indigo-500 px-4 py-2.5 text-center text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
              >
                Dashboard
              </.link>
            <% else %>
              <.link
                href={~p"/sign_up"}
                class="block w-full whitespace-nowrap rounded-lg bg-indigo-500 px-4 py-2.5 text-center text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
              >
                Start free
              </.link>
              <.link
                href={~p"/sign_in"}
                class="block w-full whitespace-nowrap rounded-lg border border-zinc-800 px-4 py-2.5 text-center text-sm font-semibold text-zinc-100 hover:bg-zinc-900"
              >
                Sign in
              </.link>
            <% end %>
          </div>
        </aside>
      </div>
    </header>
    """
  end

  @doc """
  Anchor for outbound links — opens in a new tab with the standard
  `noopener noreferrer` rel pair so the new window can't navigate the
  opener (window.opener tabnabbing). Renders the inner block followed
  by a small arrow-top-right icon so the user sees they're leaving
  the site before clicking. Optional `class` to override the default.

      <.external_link href="https://github.com/...">GitHub repo</.external_link>
      <.external_link href={url} class="text-indigo-300 hover:text-indigo-200">
        SECURITY.md
      </.external_link>
  """
  attr :href, :string, required: true
  attr :class, :string, default: "text-indigo-300 hover:text-indigo-200"
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
  slot :inner_block, required: true

  defp marketing_mobile_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "block rounded-lg px-3 py-2.5 transition",
        @active && "bg-indigo-500/10 text-indigo-200",
        !@active && "text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100"
      ]}
    >
      {render_slot(@inner_block)}
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
      <%!-- Subtle indigo underline on the active page so the
           current section is identifiable without reading the URL. --%>
      <span
        :if={@active}
        class="absolute -bottom-1 left-0 right-0 h-0.5 rounded-full bg-indigo-400"
        aria-hidden="true"
      />
    </.link>
    """
  end

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
        <div class="rounded-xl border border-indigo-500/30 bg-zinc-950 p-8 text-center sm:p-10">
          <h2 class="text-2xl font-bold tracking-tight text-white sm:text-3xl">{@headline}</h2>
          <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-zinc-400">{@subcopy}</p>
          <div class="mt-7 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <.link
              href={~p"/sign_up"}
              class="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-indigo-500 px-5 py-2.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400 sm:w-auto"
            >
              Start free <.icon name="hero-arrow-right" class="h-4 w-4" />
            </.link>
            <.link
              href={@secondary_path}
              class="inline-flex w-full items-center justify-center gap-2 rounded-lg px-5 py-2.5 text-sm font-semibold text-zinc-100 ring-1 ring-zinc-800 hover:ring-zinc-700 sm:w-auto"
            >
              {@secondary_label}
            </.link>
          </div>
          <p class="mt-4 text-xs text-zinc-500">{@note}</p>
        </div>
      </div>
    </section>
    """
  end

  # Version of the emisar_web app, read at compile time from mix.exs so
  # the footer never drifts from the actual release. `vsn` comes back as
  # a charlist; convert once at compile time.
  @app_version Application.spec(:emisar_web, :vsn) |> to_string()

  @doc """
  Footer for marketing pages. Same on every page.
  """
  def marketing_footer(assigns) do
    assigns = assign(assigns, :app_version, @app_version)

    ~H"""
    <footer class="border-t border-zinc-900 bg-zinc-950">
      <div class="mx-auto max-w-7xl px-6 py-16 lg:px-8">
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
                  <.link href={~p"/use-cases/cassandra-ops"} class="text-zinc-400 hover:text-zinc-100">
                    Cassandra ops
                  </.link>
                </li>
                <li>
                  <.link href={~p"/use-cases/postgres-ops"} class="text-zinc-400 hover:text-zinc-100">
                    Postgres ops
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/use-cases/csi-data-loss"}
                    class="text-zinc-400 hover:text-zinc-100"
                  >
                    Case study: the 33-hour wipe
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
                  <.link href={~p"/privacy"} class="text-zinc-400 hover:text-zinc-100">Privacy</.link>
                </li>
                <li>
                  <.link href={~p"/terms"} class="text-zinc-400 hover:text-zinc-100">Terms</.link>
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

        <div class="mt-12 flex items-center justify-between border-t border-zinc-900 pt-8 text-xs text-zinc-500">
          <span>© {Date.utc_today().year} Andrii Dryga. All rights reserved.</span>
          <span>v{@app_version} — built in Elixir</span>
        </div>
      </div>
    </footer>
    """
  end
end
