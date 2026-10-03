defmodule EmisarWeb.StaffSessionHTML do
  use EmisarWeb, :html
  import EmisarWeb.StaffComponents

  def new(assigns) do
    ~H"""
    <.staff_shell>
      <:title>Staff sign-in</:title>

      <div class="max-w-sm">
        <.simple_form for={@form} action={~p"/admin/sign_in"}>
          <p class="text-sm leading-relaxed text-zinc-400">
            For Emisar staff. We email a code to your staff address; you enter it with the code from your authenticator app.
          </p>
          <.input
            field={@form[:email]}
            type="email"
            label="Staff email"
            autocomplete="username"
            required
          />
          <:actions>
            <.button class="w-full">Email me a code</.button>
          </:actions>
        </.simple_form>
      </div>
    </.staff_shell>
    """
  end

  def code(assigns) do
    ~H"""
    <.staff_shell>
      <:title>Enter your codes</:title>

      <div class="max-w-sm">
        <.simple_form for={@form} action={~p"/admin/sign_in/code"}>
          <p class="text-sm leading-relaxed text-zinc-400">
            If <span class="font-medium text-zinc-200">{@email}</span>
            is a staff address, we emailed it a code. It works only in this browser and expires in 15 minutes.
          </p>
          <.input
            field={@form[:secret]}
            label="Email code"
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:otp]}
            label="Authenticator code"
            inputmode="numeric"
            autocomplete="one-time-code"
            required
          />
          <.error :if={@error}>{@error}</.error>
          <:actions>
            <.button class="w-full">Sign in</.button>
          </:actions>
        </.simple_form>

        <p class="mt-6 text-sm">
          <.link href={~p"/admin/sign_in"} class="font-medium text-brand-400 hover:text-brand-300">
            Use a different address
          </.link>
        </p>
      </div>
    </.staff_shell>
    """
  end
end
