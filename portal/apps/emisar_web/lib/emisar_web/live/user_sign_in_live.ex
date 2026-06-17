defmodule EmisarWeb.UserSignInLive do
  use EmisarWeb, :live_view

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:form, form), temporary_assigns: [form: form]}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Welcome back">
      <.simple_form for={@form} id="login_form" action={~p"/sign_in"} phx-update="ignore">
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />

        <:actions>
          <.input field={@form[:remember_me]} type="checkbox" label="Keep me signed in for 60 days" />
          <.link
            href={~p"/reset_password"}
            class="text-sm font-medium text-indigo-400 hover:text-indigo-300"
          >
            Forgot password?
          </.link>
        </:actions>

        <:actions>
          <.button phx-disable-with="Signing in..." class="w-full">
            Sign in <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <.or_separator />

      <%!-- Alternatives as distinct secondary buttons, not a stack of identical
           text links — password is the primary path, these are the fallbacks. --%>
      <div class="space-y-3">
        <.button variant="secondary" href={~p"/sign_in/magic"} class="w-full">
          Email me a sign-in link
        </.button>
        <.button variant="secondary" href={~p"/sign_in/sso"} class="w-full">
          Sign in with SSO
        </.button>
      </div>

      <p class="mt-8 text-center text-sm text-zinc-400">
        New to emisar?
        <.link href={~p"/sign_up"} class="font-medium text-indigo-400 hover:text-indigo-300">
          Create an account
        </.link>
      </p>
    </.auth_layout>
    """
  end
end
