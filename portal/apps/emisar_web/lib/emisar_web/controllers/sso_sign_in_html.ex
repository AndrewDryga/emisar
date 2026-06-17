defmodule EmisarWeb.SSOSignInHTML do
  use EmisarWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout title="Single sign-on">
      <div :if={@recent != []} class="mb-6 space-y-3">
        <p class="text-sm text-zinc-400">Continue to a team you've used before:</p>
        <.button
          :for={team <- @recent}
          href={~p"/app/#{team["slug"]}/sign_in"}
          variant="secondary"
          class="w-full justify-between"
        >
          {team["name"]} <span aria-hidden="true">→</span>
        </.button>
        <p class="py-1 text-center text-xs uppercase tracking-wider text-zinc-600">
          or enter a team address
        </p>
      </div>

      <.simple_form for={@form} action={~p"/sign_in/sso"}>
        <p class="text-sm leading-relaxed text-zinc-400">
          Enter your team's address and we'll take you to its sign-in page.
        </p>
        <.input
          field={@form[:slug]}
          label="Team address"
          placeholder="acme"
          autocomplete="off"
          required
        />
        <:actions>
          <.button class="w-full">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <div class="mt-8 text-center text-sm">
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">
          Back to sign in
        </.link>
      </div>
    </.auth_layout>
    """
  end
end
