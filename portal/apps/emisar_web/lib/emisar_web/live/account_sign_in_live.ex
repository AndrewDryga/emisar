defmodule EmisarWeb.AccountSignInLive do
  @moduledoc """
  The per-account ("branded") sign-in page at `/app/:account_id_or_slug/sign_in`.
  Resolves the team from the slug (pre-auth — knowing a slug grants nothing) and
  offers all of that account's sign-in methods: its enabled SSO providers, plus
  email+password and the magic link (identity is cross-account, so those go
  through the shared `/sign_in` endpoint). This replaces the old email-domain
  guesswork — the slug in the URL is the tenant key, so an out-of-domain member,
  guest, or contractor signs in the same way as anyone else.
  """
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, SSO}

  def mount(%{"account_id_or_slug" => ref}, _session, socket) do
    case Accounts.fetch_account_by_id_or_slug(ref) do
      {:ok, account} ->
        form = to_form(%{"email" => Phoenix.Flash.get(socket.assigns.flash, :email)}, as: "user")

        {:ok,
         socket
         |> assign(:page_title, "Sign in to #{account.name}")
         |> assign(:account, account)
         |> assign(:providers, SSO.list_enabled_providers_for_account(account.id))
         |> assign(:form, form), temporary_assigns: [form: form]}

      {:error, :not_found} ->
        raise EmisarWeb.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title={"Sign in to #{@account.name}"}>
      <div :if={@providers != []} class="space-y-3">
        <%!-- Full redirect (begin is a controller that bounces to the IdP), not live nav. --%>
        <.button :for={provider <- @providers} href={~p"/sign_in/sso/#{provider.id}"} class="w-full">
          Continue with {provider.name} <span aria-hidden="true">→</span>
        </.button>
        <p class="py-2 text-center text-xs uppercase tracking-wider text-zinc-600">
          or sign in with your email
        </p>
      </div>

      <.simple_form for={@form} id="login_form" action={~p"/sign_in"} phx-update="ignore">
        <%!-- Land back on THIS team after sign-in (server validates it's a local /app/<slug>). --%>
        <input type="hidden" name="user[return_to]" value={~p"/app/#{@account}"} />
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />

        <:actions>
          <.input field={@form[:remember_me]} type="checkbox" label="Keep me signed in for 60 days" />
          <.link
            href={~p"/reset_password"}
            class="text-sm font-medium text-indigo-400 hover:text-indigo-300"
          >
            Forgot password?
          </.link>
        </:actions>

        <:actions>
          <.button phx-disable-with="Signing in..." class="w-full">
            Sign in <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <div class="mt-8 flex flex-col gap-3 text-sm">
        <.link
          href={~p"/sign_in/magic"}
          class="text-center font-medium text-indigo-400 hover:text-indigo-300"
        >
          Email me a magic link instead
        </.link>
        <.link
          navigate={~p"/sign_in/sso"}
          class="text-center font-medium text-indigo-400 hover:text-indigo-300"
        >
          Sign in to a different team
        </.link>
      </div>
    </.auth_layout>
    """
  end
end
