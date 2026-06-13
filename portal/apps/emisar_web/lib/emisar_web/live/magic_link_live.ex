defmodule EmisarWeb.MagicLinkLive do
  use EmisarWeb, :live_view

  alias Emisar.{Auth, Mailers, Users}
  alias EmisarWeb.{RequestContext, Throttle}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Magic link")
     |> assign(:sent_to, nil)
     # Captured at mount — `get_connect_info/2` is mount-only, so the
     # `handle_event` that issues the token reads it from this assign.
     |> assign(:request_context, RequestContext.from_socket(socket))
     |> assign(:form, to_form(%{"email" => ""}, as: "user"))}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Sign in via email">
      <%= if @sent_to do %>
        <div class="rounded-lg border border-emerald-700/40 bg-emerald-950/40 p-6 text-emerald-200">
          <h3 class="font-semibold">Check your inbox.</h3>
          <p class="mt-2 text-sm">
            We sent a one-time login link to <span class="font-mono">{@sent_to}</span>.
            It expires in 15 minutes.
          </p>
          <button
            phx-click="reset_form"
            class="mt-4 text-xs font-medium text-emerald-300 hover:text-emerald-100"
          >
            Use a different email →
          </button>
        </div>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          We'll send you a one-time link. It expires in 15 minutes.
        </p>

        <.simple_form for={@form} id="magic_link_form" phx-submit="send">
          <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />

          <:actions>
            <.button phx-disable-with="Sending..." class="w-full">
              Email me a link <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>
      <% end %>

      <p class="mt-6 text-center text-sm text-zinc-400">
        Prefer a password?
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">
          Sign in with password
        </.link>
      </p>
    </.auth_layout>
    """
  end

  def handle_event("reset_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:sent_to, nil)
     |> assign(:form, to_form(%{"email" => ""}, as: "user"))}
  end

  def handle_event("send", %{"user" => %{"email" => email}}, socket) do
    # Throttle by recipient so this form can't bomb an inbox. The key is the
    # normalised email — an ETS bucket key, NOT a DB lookup (citext owns the
    # DB comparison), so the no-app-downcase rule doesn't apply. No `else`:
    # a throttled OR an unknown email both fall through to the same "sent"
    # panel below, leaking neither account existence nor the throttle.
    key = email |> to_string() |> String.trim() |> String.downcase()

    with :ok <- Throttle.check("magic_link", key, 5, 900_000),
         {:ok, user} <- Users.fetch_user_by_email(email) do
      token = Auth.issue_magic_link_token!(user, socket.assigns.request_context)
      Mailers.UserNotifier.deliver_magic_link(user, token)
    end

    {:noreply, assign(socket, :sent_to, email)}
  end
end
