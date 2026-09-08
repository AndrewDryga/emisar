defmodule EmisarWeb.SSOSignInHTML do
  use EmisarWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout title="Sign in with SSO">
      <div :if={@recent != []} class="space-y-3">
        <p class="text-sm text-zinc-400">Choose a workspace you've used before:</p>
        <.button
          :for={team <- @recent}
          href={~p"/app/#{team["slug"]}/sign_in"}
          variant={:secondary}
          class="w-full justify-between"
        >
          <span class="flex min-w-0 flex-col text-left">
            <span class="truncate">{team["name"]}</span>
            <span class="font-mono text-xs text-zinc-400">app/{team["slug"]}</span>
          </span>
          <span aria-hidden="true">→</span>
        </.button>
      </div>
      <.or_separator :if={@recent != []} label="or enter a workspace address" />

      <.simple_form for={@form} action={~p"/sign_in/sso"}>
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
          For <code class="text-zinc-300">app.emisar.dev/app/acme</code>, enter <code class="text-zinc-300">acme</code>. Check a workspace link your team shared,
          or ask your administrator if you don't know the address.
        </p>
        <:actions>
          <.button class="w-full">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <div class="mt-8 text-center text-sm">
        <.link href={~p"/sign_in"} class="font-medium text-brand-400 hover:text-brand-300">
          Back to sign in
        </.link>
      </div>
    </.auth_layout>
    """
  end
end
