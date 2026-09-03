defmodule EmisarWeb.StaffComponents do
  @moduledoc """
  Chrome for the Emisar staff console at `/admin` — a read-only, cross-tenant
  support surface that must never be mistaken for the customer console.

  The distinction is structural, not chromatic. The operator console is a left
  rail on the same black plane as its canvas, carrying an account switcher and
  the whole workflow nav; staff mode is a horizontal band of separate chrome
  above that canvas, two doors wide, with no tenant to switch to. Same tokens,
  same calm console register — a hue invented for "you are staff now" would
  break the semantic palette (design-system §3.1).
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.CoreComponents

  @doc """
  The staff console page frame: the staff top bar, the page title, and a
  `:detail`-width content column.

  Flash renders once from `EmisarWeb.Layouts` `app.html.heex`, so this shell
  deliberately does not repeat `<.flash_group>`.
  """
  attr :current_user, :map, required: true
  slot :title, required: true
  slot :inner_block, required: true

  def staff_shell(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-black text-zinc-100">
      <%!-- A separate zinc-950 band over the black canvas: the customer shell
           deliberately puts its nav on the SAME plane as the work surface, so a
           banded top bar reads as another product at a glance — which is the
           whole job here. --%>
      <header class="border-b border-zinc-800/70 bg-zinc-950">
        <div class="mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-6 gap-y-3 px-4 py-3 sm:px-8">
          <div class="flex items-center gap-2.5">
            <img src={~p"/images/brand/emisar-icon.svg"} alt="" class="h-6 w-6 shrink-0" />
            <span class="font-display text-sm font-bold tracking-tight text-zinc-100">
              Emisar Admin
            </span>
            <.chip>Read-only</.chip>
          </div>

          <%!-- Two doors, and this shell only ever wraps the Accounts one —
               LiveDashboard brings its own chrome — so the current item is a
               constant, not a `section` attr nothing could vary. Active is the
               house white wash (never a brand fill: green means "passed the
               gate", not "selected"). --%>
          <nav class="flex items-center gap-1 text-sm">
            <.link
              navigate={~p"/admin"}
              class="rounded-lg bg-white/[0.06] px-3 py-1.5 font-medium text-zinc-50"
            >
              Accounts
            </.link>
            <%!-- href, not navigate: /ops/live is a different live_session, so
                 a live navigation would only fall back to a full page load. --%>
            <.link
              href={~p"/ops/live"}
              class="rounded-lg px-3 py-1.5 text-zinc-400 transition hover:bg-white/[0.04] hover:text-zinc-100"
            >
              LiveDashboard
            </.link>
          </nav>

          <div class="ml-auto flex items-center gap-4 text-sm">
            <span class="hidden truncate text-zinc-400 sm:inline">{@current_user.email}</span>
            <.link href={~p"/app"} class="text-zinc-300 transition-colors hover:text-brand-300">
              Exit staff console
            </.link>
          </div>
        </div>
      </header>

      <header class="px-4 pb-2 pt-7 sm:px-8 sm:pt-9">
        <h1 class="mx-auto w-full max-w-6xl break-words font-display text-[28px] font-bold leading-tight tracking-[-0.03em] text-zinc-50">
          {render_slot(@title)}
        </h1>
      </header>

      <%!-- `overflow-x-clip`, never the `-hidden` spelling — a single-axis
           `-hidden` makes the other axis a scroll container that swallows any
           overlay hanging out of it. Same canvas rule as the operator shell. --%>
      <main class="flex-1 overflow-x-clip px-4 pb-10 pt-2 sm:px-8">
        <div class="mx-auto w-full max-w-6xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end
end
