defmodule EmisarWeb.SSOSignInHTML do
  use EmisarWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout title="Sign in with SSO">
      <div :if={@recent != []} class="space-y-3">
        <p class="text-sm text-zinc-400">Continue to a team you've used before:</p>
        <.button
          :for={team <- @recent}
          href={~p"/app/#{team["slug"]}/sign_in"}
          variant={:secondary}
          class="w-full justify-between"
        >
          <span class="flex min-w-0 flex-col text-left">
            <span class="truncate">{team["name"]}</span>
            <span class="font-mono text-xs text-zinc-500">app/{team["slug"]}</span>
          </span>
          <span aria-hidden="true">→</span>
        </.button>
      </div>
      <.or_separator :if={@recent != []} label="or enter your team" />

      <.simple_form for={@form} action={~p"/sign_in/sso"}>
        <p class="text-sm leading-relaxed text-zinc-400">
          Which team are you signing in to? We'll take you to its sign-in page.
        </p>
        <.input
          field={@form[:slug]}
          label="Your team's address"
          placeholder="acme"
          autocomplete="off"
          required
        />
        <p class="text-xs leading-relaxed text-zinc-500">
          The short name in your emisar URL — e.g. <code class="text-zinc-400">acme</code>
          for <span class="text-zinc-400">app/acme</span>, not your team's full name. It's in your
          invite email or any emisar link your team shared; ask your admin if you're not sure.
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
