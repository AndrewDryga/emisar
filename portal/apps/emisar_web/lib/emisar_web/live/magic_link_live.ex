defmodule EmisarWeb.MagicLinkLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Auth, Mailers}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Magic link")
     |> assign(:sent_to, nil)
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

  def handle_event("send", %{"user" => %{"email" => email}}, socket) do
    # 3 magic-links per email per 10 min. Higher than sign-in because
    # mistyped emails are common; lower than nothing because
    # uncontrolled magic-link sending is an email-bombing primitive.
    case EmisarWeb.RateLimiter.check("magic_link:" <> String.downcase(email || ""), 3, 600_000) do
      :ok ->
        if user = Accounts.get_user_by_email(email) do
          token = Auth.issue_magic_link_token(user)
          Mailers.UserNotifier.deliver_magic_link(user, token)
        end

        {:noreply, assign(socket, :sent_to, email)}

      {:error, :rate_limited, _ms} ->
        # Same UX as success (don't leak whether email is throttled vs
        # delivered). The user sees the same "check your inbox" screen.
        {:noreply, assign(socket, :sent_to, email)}
    end
  end
end
