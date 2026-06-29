defmodule EmisarWeb.MagicLinkLive do
  use EmisarWeb, :live_view
  alias EmisarWeb.ReturnTo

  # Render-only: the email form POSTs to `UserSessionController.magic_link_start`
  # (a controller, because issuing the split token sets a signed nonce COOKIE a
  # LiveView can't), and the "?sent=1" code form POSTs to `:magic_link_verify_code`.
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in via email")
     |> assign(:sent?, params["sent"] == "1")
     # Branded pages pass ?return_to=/app/<slug>; threaded into the POST as a
     # hidden field so the emailed link + the code path both land on that team.
     |> assign(:return_to, ReturnTo.app_path(params["return_to"]))
     |> assign(:email_form, to_form(%{"email" => ""}, as: "user"))
     |> assign(:code_form, to_form(%{"code" => ""}))}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Sign in via email">
      <%= if @sent? do %>
        <div class="rounded-lg border border-brand-700/40 bg-brand-950/40 p-5 text-brand-200">
          <h3 class="font-semibold">Check your inbox.</h3>
          <p class="mt-2 text-sm">
            We emailed a sign-in link and a 6-digit code. Enter the code here, or open the
            link from <em>this same browser</em>. Both expire in 15 minutes.
          </p>
        </div>

        <.simple_form for={@code_form} action={~p"/sign_in/magic/code"} method="post" class="mt-5">
          <.input
            field={@code_form[:code]}
            type="text"
            label="6-digit code"
            inputmode="numeric"
            autocomplete="one-time-code"
            pattern="[0-9]*"
            maxlength="6"
            required
          />
          <:actions>
            <.button class="w-full">Sign in <span aria-hidden="true">→</span></.button>
          </:actions>
        </.simple_form>

        <p class="mt-6 text-center text-sm text-zinc-400">
          <.link
            navigate={~p"/sign_in/magic"}
            class="font-medium text-brand-400 hover:text-brand-300"
          >
            Use a different email
          </.link>
        </p>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          We'll email you a one-time link and a 6-digit code. They expire in 15 minutes.
        </p>

        <.simple_form for={@email_form} action={~p"/sign_in/magic/start"} method="post">
          <input type="hidden" name="return_to" value={@return_to} />
          <.input
            field={@email_form[:email]}
            type="email"
            label="Work email"
            autocomplete="email"
            required
          />
          <:actions>
            <.button class="w-full">
              Email me a code <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>

        <p class="mt-6 text-center text-sm text-zinc-400">
          Prefer a password?
          <.link href={~p"/sign_in"} class="font-medium text-brand-400 hover:text-brand-300">
            Sign in with password
          </.link>
        </p>
      <% end %>
    </.auth_layout>
    """
  end
end
