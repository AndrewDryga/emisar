defmodule EmisarWeb.AccountSignInLive do
  @moduledoc """
  The per-account ("branded") sign-in page at `/app/:account_id_or_slug/sign_in`.
  Resolves the team from the slug (pre-auth — knowing a slug grants nothing) and
  offers that account's sign-in methods: its enabled SSO providers plus the
  passwordless magic link when the account does not require SSO. A require_sso
  account leads with its identity provider so a magic-link session cannot bounce
  straight back here. The slug in the URL is the tenant key, so an out-of-domain
  member, guest, or contractor signs in the same way as anyone else.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, SSO}

  def mount(%{"account_id_or_slug" => ref}, _session, socket) do
    case Accounts.fetch_account_by_id_or_slug(ref) do
      {:ok, account} ->
        providers = SSO.list_enabled_providers_for_account(account.id)

        {:ok,
         socket
         |> assign(:page_title, "Sign in to #{account.name}")
         |> assign(:account, account)
         |> assign(:providers, providers)
         |> assign(:form, to_form(%{"email" => ""}, as: "user"))}

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
      </div>
      <p :if={@account.settings.require_sso and @providers != []} class="mt-4 text-sm text-zinc-400">
        This team requires single sign-on. Use your identity provider above.
      </p>
      <.or_separator
        :if={@providers != [] and not @account.settings.require_sso}
        label="or with email"
      />

      <p
        :if={@providers == [] or not @account.settings.require_sso}
        class="mb-4 text-sm text-zinc-400"
      >
        Enter your email for a one-time sign-in link and a 6-character code.
      </p>

      <.simple_form
        :if={@providers == [] or not @account.settings.require_sso}
        for={@form}
        action={~p"/sign_in/magic/start"}
        method="post"
      >
        <%!-- Land back on THIS team after sign-in (server validates it's a local /app/<slug>). --%>
        <input type="hidden" name="return_to" value={~p"/app/#{@account}"} />
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <:actions>
          <.button class="w-full">
            Email me a sign-in link <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>

      <.auth_footer_link navigate={~p"/sign_in/sso"}>
        Sign in to a different team
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
