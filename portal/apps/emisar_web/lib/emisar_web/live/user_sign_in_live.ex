defmodule EmisarWeb.UserSignInLive do
  use EmisarWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:form, to_form(%{"email" => ""}, as: "user"))}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Welcome back">
      <p class="mb-6 text-sm text-zinc-400">
        Enter your email and we'll send a one-time sign-in link and a 6-digit code.
      </p>

      <.simple_form for={@form} action={~p"/sign_in/magic/start"} method="post">
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <:actions>
          <.button class="w-full">
            Email me a sign-in link <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <.or_separator />

      <.button variant="secondary" href={~p"/sign_in/sso"} class="w-full">
        Sign in with SSO
      </.button>

      <p class="mt-8 text-center text-sm text-zinc-400">
        New to emisar?
        <.link href={~p"/sign_up"} class="font-medium text-brand-400 hover:text-brand-300">
          Create an account
        </.link>
      </p>
    </.auth_layout>
    """
  end
end
