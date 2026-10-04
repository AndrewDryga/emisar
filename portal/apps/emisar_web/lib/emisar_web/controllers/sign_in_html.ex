defmodule EmisarWeb.SignInHTML do
  use EmisarWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout title="Sign in">
      <div :if={@recent != []} class="space-y-3">
        <p class="text-sm text-zinc-400">Choose a workspace you've used before:</p>
        <.button
          :for={workspace <- @recent}
          href={~p"/app/#{workspace["slug"]}/sign_in"}
          variant={:secondary}
          class="w-full"
        >
          <%!-- A full-width inner row: the button centers its content and a
               `justify-between` on it loses to that in CSS order. --%>
          <span class="flex w-full min-w-0 items-center justify-between gap-3">
            <span class="flex min-w-0 flex-col text-left">
              <span class="truncate">{workspace["name"]}</span>
              <span class="font-mono text-xs text-zinc-400">app/{workspace["slug"]}</span>
            </span>
            <span aria-hidden="true">→</span>
          </span>
        </.button>
      </div>
      <.or_separator :if={@recent != []} label="or enter a workspace address" />

      <.simple_form for={@form} action={~p"/sign_in"}>
        <p class="text-sm leading-relaxed text-zinc-400">
          Enter your workspace address to open its sign-in page.
        </p>
        <.input
          field={@form[:slug]}
          label="Workspace address"
          placeholder="acme"
          autocomplete="off"
          required
        />
        <.error :if={@error}>{@error}</.error>
        <p class="text-xs leading-relaxed text-zinc-400">
          For <code class="text-zinc-300">emisar.dev/app/acme</code>, enter <code class="text-zinc-300">acme</code>. Check a workspace link your team shared,
          or ask your administrator if you don't know the address.
        </p>
        <:actions>
          <.button class="w-full">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <.auth_footer_link href={~p"/sign_up"}>
        <:lead>New to emisar?</:lead>
        Create a workspace
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
