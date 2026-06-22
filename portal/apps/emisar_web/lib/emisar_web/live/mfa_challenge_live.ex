defmodule EmisarWeb.MfaChallengeLive do
  @moduledoc """
  Second-factor challenge. The password step on `/sign_in` already
  verified the operator's credentials and stashed a short-lived
  `pending_mfa_user_id` in the session — this LV reads that to decide
  whether to render the OTP form OR bounce the visitor back to
  `/sign_in` because their pending state expired (or never existed).

  The form posts JUST the OTP (or recovery code) back to `POST /sign_in`,
  which picks up the pending marker from the session, finishes the
  sign-in, and clears it. The password is never asked for twice.
  """
  use EmisarWeb, :live_view

  alias EmisarWeb.UserSessionController

  def mount(_params, session, socket) do
    case UserSessionController.get_pending_mfa(session) do
      nil ->
        # No live pending-MFA marker — the operator either landed here
        # directly, refreshed an old tab, or the marker expired. Send
        # them back to start.
        {:ok,
         socket
         |> put_flash(:error, "Your sign-in attempt expired. Enter your password again.")
         |> push_navigate(to: ~p"/sign_in")}

      user_id ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor")
         |> assign(:user_id, user_id)
         |> assign(:recovery?, false)
         |> assign(
           :form,
           to_form(%{"otp" => "", "recovery_code" => ""}, as: "user")
         )}
    end
  end

  def handle_event("toggle_recovery", _params, socket) do
    {:noreply, assign(socket, :recovery?, not socket.assigns.recovery?)}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Two-factor authentication">
      <p class="mb-6 text-sm text-zinc-400">
        <%= if @recovery? do %>
          Enter one of your one-time recovery codes to finish signing in.
        <% else %>
          Enter the 6-digit code from your authenticator app to finish signing in.
        <% end %>
      </p>

      <.simple_form for={@form} id="mfa_form" action={~p"/sign_in"} method="post">
        <%= if @recovery? do %>
          <.input
            field={@form[:recovery_code]}
            type="text"
            label="Recovery code"
            autocomplete="off"
            placeholder="abcdefgh"
            required
          />
        <% else %>
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
        <% end %>

        <:actions>
          <%!-- Disable on submit: a double-click would post the OTP twice
               and burn the one-time code on the second (replay) attempt. --%>
          <.button class="w-full" phx-disable-with="Signing in…">Sign in</.button>
        </:actions>
      </.simple_form>

      <p class="mt-6 text-center text-sm text-zinc-400">
        <button
          type="button"
          phx-click="toggle_recovery"
          class="font-medium text-brand-400 hover:text-brand-300"
        >
          {if @recovery?, do: "Use authenticator app", else: "Lost your device? Use a recovery code"}
        </button>
      </p>

      <%!-- Terminal escape once they're on the recovery path: with both the
           authenticator AND the codes gone, the toggle + sign-in link just
           loop, locking out an enforced-MFA member. The fastest fix is an
           account owner/admin clearing their 2FA from the Team page
           (Accounts.reset_member_mfa/2), which lets them enroll a fresh
           factor on next sign-in; support@ stays as the fallback for a
           member with no reachable admin. --%>
      <p :if={@recovery?} class="mt-2 text-center text-xs text-zinc-500">
        Lost your recovery codes too? Ask an account owner or admin to reset your 2FA from the
        Team page, or contact
        <.link
          href="mailto:support@emisar.dev"
          class="font-medium text-brand-400 hover:text-brand-300"
        >
          support@emisar.dev
        </.link>
        to recover access.
      </p>

      <p class="mt-2 text-center text-sm text-zinc-400">
        <.link href={~p"/sign_in"} class="font-medium text-brand-400 hover:text-brand-300">
          ← Back to sign in
        </.link>
      </p>
    </.auth_layout>
    """
  end
end
