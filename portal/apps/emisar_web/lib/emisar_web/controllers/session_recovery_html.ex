defmodule EmisarWeb.SessionRecoveryHTML do
  use EmisarWeb, :html

  def show(assigns) do
    ~H"""
    <.auth_layout title="Choose how to continue">
      <p :if={@sso_incomplete?} role="status" class="mb-4 text-sm leading-relaxed text-zinc-300">
        Single sign-on was not completed. Choose a workspace to try again, or start a new sign-in.
      </p>
      <p :if={@personal_required?} role="status" class="mb-4 text-sm leading-relaxed text-zinc-300">
        Sign out and sign in by email to create a workspace.
      </p>
      <p :if={@signed_in?} class="text-sm leading-relaxed text-zinc-400">
        This browser may need a new sign-in to access your workspace. Signing in again
        checks your current access. If access was removed, ask a workspace admin to restore it.
      </p>
      <p :if={not @signed_in?} class="text-sm leading-relaxed text-zinc-400">
        Your session has ended. Sign in again to continue.
      </p>

      <div :if={@accounts != []} class="mt-6 space-y-3">
        <.button :for={account <- @accounts} href={~p"/app/#{account}"} class="w-full">
          Continue to {account.name} <span aria-hidden="true">→</span>
        </.button>
      </div>

      <.form :if={@signed_in?} for={%{}} action={~p"/session/recover"} method="post" class="mt-6">
        <.button variant={:secondary} class="w-full">Sign out and sign in again</.button>
      </.form>
      <p :if={@signed_in?} class="mt-3 text-sm leading-relaxed text-zinc-500">
        Signing out ends this browser's session across your workspaces. Other browsers stay signed in.
      </p>
      <.button :if={not @signed_in?} href={~p"/sign_in"} class="mt-6 w-full">Sign in</.button>
    </.auth_layout>
    """
  end
end
