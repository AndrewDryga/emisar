defmodule EmisarWeb.SSORequiredHTML do
  use EmisarWeb, :html

  def show(assigns) do
    ~H"""
    <.auth_layout title={"Continue to #{@account.name}"}>
      <p class="text-sm leading-relaxed text-zinc-400">
        This workspace requires single sign-on. Verifying with your identity provider
        keeps your other workspace access available in this browser.
      </p>

      <div :if={@providers != []} class="mt-6 space-y-3">
        <.form
          :for={provider <- @providers}
          for={%{}}
          action={~p"/app/#{@account}/sso_required"}
          method="post"
        >
          <input type="hidden" name="provider_id" value={provider.id} />
          <.button class="w-full">Continue with {provider.name} <span aria-hidden="true">→</span></.button>
        </.form>
      </div>

      <p :if={@providers == []} class="mt-4 text-sm leading-relaxed text-zinc-400">
        Your current sign-in is not linked to an enabled identity provider for this workspace.
        Ask a workspace admin to link your identity, or sign out and use the workspace sign-in page.
      </p>

      <.form for={%{}} action={~p"/session/recover"} method="post" class="mt-6">
        <input type="hidden" name="account_id_or_slug" value={@account.id} />
        <.button variant={:secondary} class="w-full">Sign out and sign in again</.button>
      </.form>
      <p class="mt-3 text-sm leading-relaxed text-zinc-500">
        Signing out ends this browser's session across your workspaces. Other browsers stay signed in.
      </p>
      <.auth_footer_link href={~p"/session/recover"}>See your recovery options</.auth_footer_link>
    </.auth_layout>
    """
  end
end
