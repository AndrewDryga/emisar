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

  alias Phoenix.LiveView.JS

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="bg-zinc-50/90 fixed inset-0 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="shadow-zinc-700/10 ring-zinc-700/10 relative hidden rounded-2xl bg-white p-14 shadow-lg ring-1 transition"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-20 hover:opacity-40"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
      <button type="button" class="absolute top-2 right-2 p-2 opacity-50 hover:opacity-100" aria-label={gettext("close")}>
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
      <.flash kind={:info} title={gettext("Success!")} flash={@flash} />
      <.flash kind={:error} title={gettext("Error!")} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
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

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 inline-flex items-center justify-center gap-2",
        "rounded-lg bg-indigo-500 px-4 py-2.5 text-sm font-semibold text-zinc-950",
        "shadow-sm transition hover:bg-indigo-400 active:bg-indigo-600",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-400",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

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
      <.label for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "ring-1 ring-inset ring-zinc-800 placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset focus:ring-indigo-500"
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
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2.5 text-sm text-zinc-100",
          "min-h-[6rem] ring-1 ring-inset placeholder:text-zinc-600",
          "focus:ring-2 focus:ring-inset",
          @errors == [] && "ring-zinc-800 focus:ring-indigo-500",
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500"
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
      <.label for={@id}>{@label}</.label>
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
          @errors != [] && "ring-rose-500/50 focus:ring-rose-500"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="block text-sm font-medium text-zinc-200">
      {render_slot(@inner_block)}
    </label>
    """
  end

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
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-zinc-800">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-zinc-600">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-11 sm:w-full">
        <thead class="text-sm text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @col} class="p-0 pb-4 pr-6 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-zinc-100 border-t border-zinc-200 text-sm leading-6 text-zinc-700"
        >
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group hover:bg-zinc-50">
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 sm:rounded-l-xl" />
                <span class={["relative", i == 0 && "font-semibold text-zinc-900"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td :if={@action != []} class="relative w-14 p-0">
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-zinc-50 sm:rounded-r-xl" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="mt-14">
      <dl class="-my-4 divide-y divide-zinc-100">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-zinc-500">{item.title}</dt>
          <dd class="text-zinc-700">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back navigate={~p"/posts"}>Back to posts</.back>
  """
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
      >
        <.icon name="hero-arrow-left-solid" class="h-3 w-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
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

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
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
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # -- emisar-specific layout helpers -----------------------------------

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
        <a href="/" class="flex items-center gap-3 text-zinc-100">
          <span class="grid h-9 w-9 place-items-center rounded-lg bg-indigo-500 text-zinc-950 font-black">e</span>
          <span class="text-xl font-bold tracking-tight">emisar</span>
        </a>

        <div class="max-w-md">
          <blockquote class="text-2xl font-medium leading-snug text-zinc-100">
            “We swapped our brittle Slack-runbook setup for emisar in a weekend.
            LLMs hit a versioned, audited, policy-gated catalog — and oncall finally
            sleeps.”
          </blockquote>
          <p class="mt-4 text-sm text-zinc-400">
            — Marek S., Staff SRE
          </p>
        </div>

        <p class="text-xs text-zinc-500">© {Date.utc_today().year} emisar</p>
      </div>

      <div class="flex items-center justify-center p-6 lg:p-12">
        <div class="w-full max-w-md">
          <.link href={~p"/"} class="mb-12 inline-flex items-center gap-3 lg:hidden">
            <span class="grid h-9 w-9 place-items-center rounded-lg bg-indigo-500 text-zinc-950 font-black">e</span>
            <span class="text-xl font-bold tracking-tight">emisar</span>
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
  """
  attr :current_user, :map, required: true
  attr :current_account, :map, required: true
  attr :section, :atom, default: :dashboard
  attr :flash, :map, default: %{}

  slot :inner_block, required: true
  slot :title, required: true
  slot :actions

  def dashboard_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Desktop sidebar (lg and up) --%>
      <aside class="hidden w-64 flex-shrink-0 border-r border-zinc-900 bg-zinc-950/80 lg:flex lg:flex-col">
        <.shell_brand current_account={@current_account} />
        <.shell_nav section={@section} />
        <.shell_user current_user={@current_user} />
      </aside>

      <%!-- Mobile drawer (hidden by default; JS toggles `open`) --%>
      <div
        id="mobile-nav"
        class="fixed inset-0 z-40 hidden lg:hidden"
        role="dialog"
        aria-modal="true"
        phx-window-keydown={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
        phx-key="escape"
      >
        <div
          class="absolute inset-0 bg-black/60"
          phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
        ></div>
        <aside class="relative flex h-full w-72 max-w-[80vw] flex-col border-r border-zinc-900 bg-zinc-950 shadow-2xl">
          <div class="flex items-center justify-between border-b border-zinc-900 px-4 py-3">
            <.shell_brand current_account={@current_account} />
            <button
              type="button"
              aria-label="Close menu"
              class="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
              phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <.shell_nav section={@section} />
          <.shell_user current_user={@current_user} />
        </aside>
      </div>

      <div class="flex flex-1 flex-col">
        <header class="flex h-16 items-center gap-3 border-b border-zinc-900 bg-zinc-950 px-4 sm:px-6">
          <%!-- Mobile hamburger (hidden on lg) --%>
          <button
            type="button"
            aria-label="Open menu"
            class="-ml-1.5 rounded-md p-2 text-zinc-300 hover:bg-zinc-900 hover:text-zinc-100 lg:hidden"
            phx-click={JS.show(to: "#mobile-nav", display: "block") |> JS.add_class("overflow-hidden", to: "body")}
          >
            <.icon name="hero-bars-3" class="h-5 w-5" />
          </button>
          <h1 class="min-w-0 flex-1 truncate text-base font-semibold tracking-tight sm:text-lg">
            {render_slot(@title)}
          </h1>
          <div class="flex items-center gap-2 sm:gap-3">{render_slot(@actions)}</div>
        </header>

        <main class="flex-1 overflow-x-hidden p-4 sm:p-6">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  # -- shell sub-components (shared between desktop + mobile) ----------

  attr :current_account, :map, required: true

  defp shell_brand(assigns) do
    ~H"""
    <div class="flex h-16 items-center gap-3 px-2 lg:border-b lg:border-zinc-900 lg:px-6">
      <span class="grid h-8 w-8 place-items-center rounded-lg bg-indigo-500 text-zinc-950 font-black">e</span>
      <div class="min-w-0">
        <div class="truncate font-bold tracking-tight">emisar</div>
        <div class="truncate text-xs text-zinc-500">{@current_account.name}</div>
      </div>
    </div>
    """
  end

  attr :section, :atom, required: true

  defp shell_nav(assigns) do
    ~H"""
    <nav class="flex-1 space-y-1 overflow-y-auto px-3 py-6 text-sm">
      <.nav_link to={~p"/app"} active={@section == :dashboard} icon="hero-home">Dashboard</.nav_link>
      <.nav_link to={~p"/app/runners"} active={@section == :runners} icon="hero-cpu-chip">Runners</.nav_link>
      <.nav_link to={~p"/app/runs"} active={@section == :runs} icon="hero-bolt">Runs</.nav_link>
      <.nav_link to={~p"/app/approvals"} active={@section == :approvals} icon="hero-shield-check">Approvals</.nav_link>
      <.nav_link to={~p"/app/runbooks"} active={@section == :runbooks} icon="hero-book-open">Runbooks</.nav_link>
      <.nav_link to={~p"/app/policies"} active={@section == :policies} icon="hero-document-text">Policies</.nav_link>
      <.nav_link to={~p"/app/audit"} active={@section == :audit} icon="hero-list-bullet">Audit</.nav_link>
      <div class="my-3 border-t border-zinc-900" />
      <.nav_link to={~p"/app/settings/runners/auth-keys"} active={@section == :auth_keys} icon="hero-key">Auth keys</.nav_link>
      <.nav_link to={~p"/app/settings/api-keys"} active={@section == :api_keys} icon="hero-finger-print">API keys</.nav_link>
      <.nav_link to={~p"/app/settings/team"} active={@section == :team} icon="hero-user-group">Team</.nav_link>
      <.nav_link to={~p"/app/settings/billing"} active={@section == :billing} icon="hero-credit-card">Billing</.nav_link>
    </nav>
    """
  end

  attr :current_user, :map, required: true

  defp shell_user(assigns) do
    ~H"""
    <div class="border-t border-zinc-900 p-4 text-sm">
      <div class="flex items-center gap-3">
        <span class="grid h-8 w-8 place-items-center rounded-full bg-zinc-800 text-xs font-semibold uppercase">
          {String.first(@current_user.full_name || @current_user.email)}
        </span>
        <div class="min-w-0 flex-1">
          <div class="truncate font-medium">{@current_user.full_name || @current_user.email}</div>
          <div class="truncate text-xs text-zinc-500">{@current_user.email}</div>
        </div>
        <.link href={~p"/sign_out"} method="delete" class="text-zinc-500 hover:text-zinc-200" title="Sign out">
          <.icon name="hero-arrow-right-on-rectangle" class="h-5 w-5" />
        </.link>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      phx-click={JS.hide(to: "#mobile-nav") |> JS.remove_class("overflow-hidden", to: "body")}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-2 transition",
        @active && "bg-indigo-500/10 text-indigo-200",
        !@active && "text-zinc-400 hover:bg-zinc-900 hover:text-zinc-100"
      ]}
    >
      <.icon name={@icon} class="h-4 w-4" />
      <span>{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc "Coloured pill for run/runner status."
  attr :status, :string, required: true
  attr :class, :string, default: ""

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
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
  defp status_classes("archived"), do: "bg-zinc-500/10 text-zinc-500 ring-zinc-500/30"
  defp status_classes("awaiting_approval"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp status_classes("pending_approval"), do: "bg-amber-500/10 text-amber-300 ring-amber-500/30"
  defp status_classes("cancelled"), do: "bg-zinc-500/10 text-zinc-400 ring-zinc-500/30"
  defp status_classes("denied"), do: "bg-rose-500/10 text-rose-300 ring-rose-500/30"
  defp status_classes("expired"), do: "bg-zinc-500/10 text-zinc-500 ring-zinc-500/30"
  defp status_classes(s) when s in ["failed", "error", "validation_failed", "unknown_action", "timed_out"],
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
  defp status_dot("archived"), do: "bg-zinc-600"
  defp status_dot("awaiting_approval"), do: "bg-amber-400 animate-pulse"
  defp status_dot("pending_approval"), do: "bg-amber-400 animate-pulse"
  defp status_dot("denied"), do: "bg-rose-400"
  defp status_dot("expired"), do: "bg-zinc-600"
  defp status_dot(s) when s in ["failed", "error", "validation_failed", "unknown_action", "timed_out"], do: "bg-rose-400"
  defp status_dot(_), do: "bg-zinc-500"

  defp format_status("awaiting_approval"), do: "awaiting approval"
  defp format_status("pending_approval"), do: "awaiting approval"
  defp format_status("validation_failed"), do: "validation failed"
  defp format_status("unknown_action"), do: "unknown action"
  defp format_status("timed_out"), do: "timed out"
  defp format_status(other), do: other

  # -- Generic page primitives ---------------------------------------

  @doc """
  Canonical "card" surface. One place to evolve the dark border /
  background combo so every page picks it up.

      <.card>
        ...
      </.card>
      <.card padding="p-8" class="lg:col-span-2">...</.card>
  """
  attr :class, :string, default: nil
  attr :padding, :string, default: "p-6"
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border border-zinc-900 bg-zinc-950/60",
      @padding,
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Section header for a card: title on the left, optional link on the right.

      <.section_header title="Recent runs" href={~p"/app/runs"} cta="See all" />
      <.section_header title="Members" />
  """
  attr :title, :string, required: true
  attr :href, :string, default: nil
  attr :cta, :string, default: "View all"
  attr :class, :string, default: nil
  slot :inner_block

  def section_header(assigns) do
    ~H"""
    <div class={["flex items-center justify-between", @class]}>
      <h2 class="text-sm font-semibold text-zinc-100">{@title}</h2>
      <%= if @href do %>
        <.link navigate={@href} class="text-sm font-medium text-indigo-400 hover:text-indigo-300">
          {@cta} →
        </.link>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

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

  @doc ~S"""
  Statistic tile used on the dashboard.

      <.stat label="Runners online" value={@agents_connected} hint={"of #{@total} total"} />
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  def stat(assigns) do
    ~H"""
    <.card>
      <div class="text-xs uppercase tracking-wider text-zinc-500">{@label}</div>
      <div class="mt-2 text-3xl font-semibold text-zinc-50">{@value}</div>
      <%= if @hint do %>
        <div class="mt-1 text-xs text-zinc-500">{@hint}</div>
      <% end %>
    </.card>
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
  attr :class, :string, default: nil
  slot :inner_block, required: true

  slot :cta do
    attr :navigate, :string
    attr :href, :string
  end

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border border-dashed border-zinc-800 bg-zinc-950/40 p-12 text-center",
      @class
    ]}>
      <.icon name={@icon} class="mx-auto h-10 w-10 text-zinc-700" />
      <h2 class="mt-4 text-base font-semibold text-zinc-200">{@title}</h2>
      <p class="mt-2 text-sm text-zinc-500">{render_slot(@inner_block)}</p>

      <%= for cta <- @cta do %>
        <.link
          navigate={cta[:navigate]}
          href={cta[:href]}
          class="mt-6 inline-flex items-center gap-2 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
        >
          {render_slot(cta)} <span aria-hidden="true">→</span>
        </.link>
      <% end %>
    </div>
    """
  end

  @doc """
  Risk pill — used on action descriptors. Colours mirror the runner's
  declared risk level (`low|medium|high|critical`).
  """
  attr :risk, :string, required: true
  attr :class, :string, default: nil

  def risk_pill(assigns) do
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
          curl -sSL https://emisar.com/install.sh | sudo EMISAR_AUTH_KEY={@new_secret} bash
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

          <div class="mt-4 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-3 ring-1 ring-zinc-800">
            <code class="flex-1 break-all font-mono text-xs text-zinc-100">{@secret}</code>
            <button
              type="button"
              class="rounded bg-amber-500/20 px-2 py-1 text-xs font-semibold text-amber-100 hover:bg-amber-500/30"
              onclick={"navigator.clipboard.writeText('#{@secret}')"}
            >
              Copy
            </button>
          </div>

          <%= for cmd <- @install_command do %>
            <div class="mt-4">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-amber-200/80">
                {cmd[:label] || "Install on a host"}
              </h3>
              <div class="mt-2 flex items-center gap-2 rounded-lg bg-zinc-950/80 p-3 ring-1 ring-zinc-800">
                <code class="flex-1 break-all font-mono text-xs text-zinc-300">{render_slot(cmd)}</code>
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

  @doc """
  Table-of-things shell. Receives `:col` slots and `rows` list. Tables
  in the product all share the same header chrome + zebra dividers, so
  this consolidates that.

      <.list_table id="members" rows={@memberships}>
        <:col :let={m} label="Member">{m.user.email}</:col>
        <:col :let={m} label="Role">{m.role}</:col>
        <:action :let={m}>
          <button phx-click="remove" phx-value-id={m.id}>Remove</button>
        </:action>
      </.list_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_click, :any, default: nil
  attr :empty_message, :string, default: "Nothing to show yet."

  slot :col, required: true do
    attr :label, :string, required: true
    attr :align, :string
  end

  slot :action

  def list_table(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/60">
      <table class="w-full text-sm">
        <thead class="border-b border-zinc-900 text-xs uppercase tracking-wider text-zinc-500">
          <tr>
            <th :for={col <- @col} class={["px-4 py-3 font-medium", th_align(col[:align])]}>
              {col[:label]}
            </th>
            <th :if={@action != []} class="px-4 py-3 text-right font-medium">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-900" id={@id}>
          <tr
            :for={row <- @rows}
            class={["transition", @row_click && "cursor-pointer hover:bg-zinc-900/40"]}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class={["px-4 py-3", td_align(col[:align])]}>
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-4 py-3 text-right">
              {render_slot(@action, row)}
            </td>
          </tr>
        </tbody>
      </table>
      <%= if @rows == [] do %>
        <div class="p-12 text-center text-sm text-zinc-500">{@empty_message}</div>
      <% end %>
    </div>
    """
  end

  defp th_align("right"), do: "text-right"
  defp th_align(_), do: "text-left"

  defp td_align("right"), do: "text-right"
  defp td_align(_), do: "text-left"

  # -- Marketing chrome ------------------------------------------------

  @doc """
  Top nav for marketing pages. Pass `current` to highlight the active
  link.

      <.marketing_nav current={:pricing} />
  """
  attr :current, :atom, default: nil
  attr :sticky, :boolean, default: false

  def marketing_nav(assigns) do
    ~H"""
    <header class={[
      "border-b border-zinc-900/80 bg-zinc-950/80 backdrop-blur",
      @sticky && "sticky top-0 z-50"
    ]}>
      <div class="mx-auto flex max-w-7xl items-center justify-between px-6 py-5 lg:px-8">
        <.link href={~p"/"} class="flex items-center gap-3">
          <span class="grid h-9 w-9 place-items-center rounded-lg bg-indigo-500 text-zinc-950 font-black">e</span>
          <span class="text-xl font-bold tracking-tight">emisar</span>
        </.link>
        <nav class="hidden items-center gap-8 md:flex">
          <.marketing_nav_link href={~p"/pricing"} active={@current == :pricing}>Pricing</.marketing_nav_link>
          <.marketing_nav_link href={~p"/security"} active={@current == :security}>Security</.marketing_nav_link>
          <.marketing_nav_link href={~p"/docs"} active={@current == :docs}>Docs</.marketing_nav_link>
          <.marketing_nav_link href={~p"/changelog"} active={@current == :changelog}>Changelog</.marketing_nav_link>
          <.marketing_nav_link href={~p"/about"} active={@current == :about}>About</.marketing_nav_link>
        </nav>
        <div class="flex items-center gap-4">
          <.link href={~p"/sign_in"} class="text-sm font-semibold text-zinc-100 hover:text-indigo-300">
            Sign in
          </.link>
          <.link
            href={~p"/sign_up"}
            class="rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
          >
            Start free
          </.link>
        </div>
      </div>
    </header>
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
        "text-sm font-medium",
        @active && "text-zinc-100",
        !@active && "text-zinc-400 hover:text-zinc-100"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Footer for marketing pages. Same on every page.
  """
  def marketing_footer(assigns) do
    ~H"""
    <footer class="border-t border-zinc-900 bg-zinc-950">
      <div class="mx-auto max-w-7xl px-6 py-16 lg:px-8">
        <div class="grid grid-cols-2 gap-12 md:grid-cols-5">
          <div class="col-span-2">
            <.link href={~p"/"} class="flex items-center gap-3">
              <span class="grid h-9 w-9 place-items-center rounded-lg bg-indigo-500 text-zinc-950 font-black">e</span>
              <span class="text-xl font-bold tracking-tight">emisar</span>
            </.link>
            <p class="mt-4 max-w-xs text-sm text-zinc-500">
              Give AI tools approved infrastructure actions, not SSH.
            </p>
          </div>

          <div>
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Product</h4>
            <ul class="mt-4 space-y-3 text-sm">
              <li><.link href={~p"/pricing"} class="text-zinc-400 hover:text-zinc-100">Pricing</.link></li>
              <li><.link href={~p"/security"} class="text-zinc-400 hover:text-zinc-100">Security</.link></li>
              <li><.link href={~p"/docs"} class="text-zinc-400 hover:text-zinc-100">Docs</.link></li>
              <li><.link href={~p"/changelog"} class="text-zinc-400 hover:text-zinc-100">Changelog</.link></li>
            </ul>
          </div>

          <div>
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Company</h4>
            <ul class="mt-4 space-y-3 text-sm">
              <li><.link href={~p"/about"} class="text-zinc-400 hover:text-zinc-100">About</.link></li>
              <li>
                <a href="https://github.com/andrewdryga/emisar" class="text-zinc-400 hover:text-zinc-100">
                  GitHub
                </a>
              </li>
              <li>
                <a href="mailto:hello@emisar.com" class="text-zinc-400 hover:text-zinc-100">Contact</a>
              </li>
            </ul>
          </div>

          <div>
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-400">Legal</h4>
            <ul class="mt-4 space-y-3 text-sm">
              <li><.link href={~p"/privacy"} class="text-zinc-400 hover:text-zinc-100">Privacy</.link></li>
              <li><.link href={~p"/terms"} class="text-zinc-400 hover:text-zinc-100">Terms</.link></li>
              <li>
                <a
                  href="https://github.com/andrewdryga/emisar/blob/main/.github/SECURITY.md"
                  class="text-zinc-400 hover:text-zinc-100"
                >
                  Security policy
                </a>
              </li>
              <li>
                <a
                  href="https://github.com/andrewdryga/emisar/blob/main/LICENSE.md"
                  class="text-zinc-400 hover:text-zinc-100"
                >
                  License
                </a>
              </li>
            </ul>
          </div>
        </div>

        <div class="mt-12 flex items-center justify-between border-t border-zinc-900 pt-8 text-xs text-zinc-500">
          <span>© {Date.utc_today().year} emisar. All rights reserved.</span>
          <span>v0.2.0 — built in Elixir</span>
        </div>
      </div>
    </footer>
    """
  end
end
