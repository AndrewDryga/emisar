defmodule EmisarWeb.AccountRedirectHTML do
  use EmisarWeb, :html

  # The same shape as the sign-in picker's recent-workspace list: one button
  # per signed-in workspace, each link carrying the suffix the slugless URL
  # asked for.
  def pick(assigns) do
    ~H"""
    <.auth_layout title="Choose a workspace">
      <div class="space-y-3">
        <p class="text-sm text-zinc-400">
          You're signed in to several workspaces. Choose one to continue:
        </p>
        <.button
          :for={choice <- @choices}
          href={choice.path}
          variant={:secondary}
          class="w-full"
        >
          <%!-- The button centers its content and a `justify-between` on it loses
               to that in CSS order, so a full-width inner row places the name left
               and the arrow right. --%>
          <span class="flex w-full min-w-0 items-center justify-between gap-3">
            <span class="flex min-w-0 flex-col text-left">
              <span class="truncate">{choice.account.name}</span>
              <span class="truncate font-mono text-xs text-zinc-400">
                {choice.account.slug}<span :if={choice.email}> · {choice.email}</span>
              </span>
            </span>
            <span aria-hidden="true">→</span>
          </span>
        </.button>
      </div>

      <.auth_footer_link href={~p"/sign_in"}>
        <:lead>Need a different workspace?</:lead>
        Sign in to another workspace
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
