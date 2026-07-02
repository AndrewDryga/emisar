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
        Enter your email and we'll send a one-time <span class="whitespace-nowrap">sign-in link</span>
        and a <span class="whitespace-nowrap">6-character code</span>. They expire in 15 minutes.
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

      <.button variant={:secondary} href={~p"/sign_in/sso"} class="w-full">
        Sign in with SSO
      </.button>

      <.auth_footer_link href={~p"/sign_up"}>
        <:lead>New to emisar?</:lead>
        Create an account
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
