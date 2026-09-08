defmodule EmisarWeb.ErrorHTML do
  @moduledoc """
  Branded error page for HTML responses. Rendered for any uncaught
  exception (500) and for routes that hit no controller (404). Uses
  the same dark theme as the rest of the product so a stray bad
  link doesn't drop the visitor into an obvious browser-default
  "Not Found" page.

  Rendered outside the normal layout pipeline — we cannot rely on
  components that expect `conn.assigns` to be populated, so we emit
  a self-contained HTML document.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: EmisarWeb.Endpoint,
    router: EmisarWeb.Router,
    statics: EmisarWeb.static_paths()

  import EmisarWeb.MarketingComponents, only: [brand: 1]
  import EmisarWeb.CoreComponents, only: [button: 1]

  def render("404.html", _assigns) do
    error_page(%{
      status: 404,
      title: "Page not found",
      message:
        "This page may have moved or been removed. Check the address, or return to your dashboard.",
      action: "Open dashboard",
      href: "/app"
    })
  end

  # The common path here is a stale-session CSRF failure — a form that sat
  # open until the session expired, then POSTed. Spoken recovery copy, not
  # the raw "Forbidden".
  def render("403.html", %{reason: %Plug.CSRFProtection.InvalidCSRFTokenError{}}) do
    error_page(%{
      status: 403,
      title: "We couldn't verify that request",
      message:
        "Your session may have expired. Go back, refresh the page, and try again. If that doesn't help, sign in again.",
      action: "Sign in again",
      href: "/sign_in"
    })
  end

  def render("403.html", _assigns) do
    error_page(%{
      status: 403,
      title: "Access denied",
      message:
        "You don't have permission to open this page or make this change. Check that you're signed in with the right email, or ask your workspace administrator for access.",
      action: "Open dashboard",
      href: "/app"
    })
  end

  def render("500.html", _assigns) do
    error_page(%{
      status: 500,
      title: "We couldn't load this page",
      # No promise of a page: on-call is alerted on a sustained 5xx rate, so a
      # single error reaches our logs and nobody's phone.
      message:
        "An unexpected server error stopped this request. Try again in a moment. If it keeps happening, contact support@emisar.dev with the page address and when it happened.",
      action: "Return to dashboard",
      href: "/app"
    })
  end

  # Catch-all for any other status code Phoenix raises (403, 400…).
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)

    error_page(%{
      status: template_to_status(template),
      title: status,
      message: "We couldn't complete this request. Return to your dashboard and try again.",
      action: "Open dashboard",
      href: "/app"
    })
  end

  defp template_to_status(t) do
    case Integer.parse(t) do
      {n, _} -> n
      :error -> 500
    end
  end

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-zinc-950 text-zinc-100 [scrollbar-gutter:stable]">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>{@title} · emisar</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
      </head>
      <body class="flex min-h-screen items-center justify-center bg-zinc-950 antialiased">
        <main class="mx-auto w-full max-w-md px-6 py-12 text-center">
          <a href="/" class="inline-block">
            <.brand />
          </a>

          <p class="mt-10 text-xs font-semibold uppercase tracking-wider text-zinc-400">
            Error {@status}
          </p>
          <h1 class="mt-2 text-balance text-2xl font-semibold tracking-tight text-zinc-50">
            {@title}
          </h1>
          <p class="mt-3 text-sm leading-relaxed text-zinc-400">
            {@message}
          </p>

          <div class="mt-8 flex flex-wrap items-center justify-center gap-3">
            <.button href={@href}>{@action}</.button>
            <.button href="/" variant={:secondary}>Back to home</.button>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
