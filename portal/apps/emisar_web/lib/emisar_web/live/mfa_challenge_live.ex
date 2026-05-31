defmodule EmisarWeb.MfaChallengeLive do
  @moduledoc """
  Second-factor challenge. Operator has presented a valid password;
  this asks for the TOTP. The controller form posts back to
  `POST /sign_in` with `user[otp]` filled in.
  """
  use EmisarWeb, :live_view

  def mount(%{"email" => email}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Two-factor")
     |> assign(:email, email)
     |> assign(:form, to_form(%{"email" => email, "password" => "", "otp" => ""}, as: "user"))}
  end

  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/sign_in")}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Two-factor authentication">
      <p class="mb-6 text-sm text-zinc-400">
        Re-enter your password and the 6-digit code from your authenticator app for
        <span class="font-mono">{@email}</span>.
      </p>

      <.simple_form for={@form} id="mfa_form" action={~p"/sign_in"} method="post">
        <input type="hidden" name="user[email]" value={@email} />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />
        <.input
          field={@form[:otp]}
          type="text"
          label="6-digit code"
          autocomplete="one-time-code"
          inputmode="numeric"
          pattern="[0-9]*"
          minlength="6"
          maxlength="6"
          required
        />

        <:actions>
          <.button class="w-full">Sign in</.button>
        </:actions>
      </.simple_form>

      <p class="mt-6 text-center text-sm text-zinc-400">
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">
          ← Back to sign in
        </.link>
      </p>
    </.auth_layout>
    """
  end
end
