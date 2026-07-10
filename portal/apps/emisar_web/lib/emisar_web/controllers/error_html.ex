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

  import EmisarWeb.CoreComponents, only: [brand: 1]

  def render("404.html", _assigns) do
    error_page(%{
      status: 404,
      title: "Page not found",
      message:
        "The page you're looking for doesn't exist, or the link you followed is out of date. Check the URL or head back to the dashboard."
    })
  end

  def render("500.html", _assigns) do
    error_page(%{
      status: 500,
      title: "Something broke on our side",
      message:
        "We hit an unexpected error. The on-call engineer has been paged. If this keeps happening, ping support@emisar.dev — include the URL and roughly when it happened."
    })
  end

  # Catch-all for any other status code Phoenix raises (403, 400…).
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)

    error_page(%{
      status: template_to_status(template),
      title: status,
      message: "Something went wrong. Try heading back and trying again."
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
            <.brand size={:md} />
          </a>

          <p class="mt-10 text-xs font-semibold uppercase tracking-[0.18em] text-zinc-500">
            Error {@status}
          </p>
          <h1 class="mt-2 text-2xl font-semibold tracking-tight text-zinc-50">
            {@title}
          </h1>
          <p class="mt-3 text-sm leading-relaxed text-zinc-400">
            {@message}
          </p>

          <div class="mt-8 flex items-center justify-center gap-3">
            <a
              href="/"
              class="rounded-lg bg-brand-500 px-4 py-2 text-sm font-semibold text-zinc-950 hover:bg-brand-400"
            >
              Back to home
            </a>
            <a
              href="/app"
              class="rounded-lg border border-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:bg-zinc-900"
            >
              Open dashboard
            </a>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
