defmodule EmisarWeb.SSORequiredHTML do
  use EmisarWeb, :html

  def show(assigns) do
    ~H"""
    <.auth_layout title="Sign in with SSO">
      <p class="text-sm leading-relaxed text-zinc-400">
        This team requires single sign-on. Sign out of this session, then continue with your
        identity provider.
      </p>

      <%!-- No back link: every signed-in destination bounces straight back here
           (the compliance gate), so the sign-out POST is the only real exit. --%>
      <.simple_form for={@form} action={~p"/app/#{@account}/sso_required"} method="post">
        <:actions>
          <.button class="w-full">
            Sign out and continue <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>
    </.auth_layout>
    """
  end
end
