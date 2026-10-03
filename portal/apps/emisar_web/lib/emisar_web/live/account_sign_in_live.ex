defmodule EmisarWeb.AccountSignInLive do
  @moduledoc """
  A workspace's own sign-in page at `/app/:account_id_or_slug/sign_in`.
  Resolves the workspace from the slug (pre-auth — knowing a slug grants
  nothing) and offers its sign-in methods: its enabled SSO providers, and the
  emailed code while the workspace accepts it (`Accounts.email_sign_in_allowed?/1`).
  The slug in the URL is the workspace, so an out-of-domain member, guest, or
  contractor signs in the same way as anyone else.

  An invitee whose workspace signs in only through SSO lands here after its code
  proved the invited address: the proof waits in this browser's encrypted
  session, and the providers then continue the acceptance
  (`SSOController.begin_invitation/2`) instead of an ordinary sign-in.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, SSO}
  alias EmisarWeb.UserAuth

  def mount(%{"account_id_or_slug" => ref}, session, socket) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(ref) do
      {:ok, account} ->
        active? = is_nil(account.disabled_at)
        providers = if active?, do: SSO.list_enabled_providers_for_account(account.id), else: []
        invitation? = active? and UserAuth.invitation_sso_account_id(session) == account.id

        {:ok,
         socket
         |> assign(:page_title, "Sign in to #{account.name}")
         |> assign(:account, account)
         |> assign(:providers, providers)
         |> assign(:invitation?, invitation?)
         |> assign(
           :email?,
           active? and not invitation? and Accounts.email_sign_in_allowed?(account)
         )
         |> assign(:form, to_form(%{"email" => ""}, as: "user"))}

      {:error, :not_found} ->
        raise EmisarWeb.NotFoundError
    end
  end

  def render(%{invitation?: true} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@account.name}"}>
      <p class="mb-6 text-sm leading-6 text-zinc-300">
        Your email is confirmed. {@account.name} signs in through single sign-on, so finish
        joining with your identity provider.
      </p>
      <div :if={@providers != []} class="space-y-3">
        <%!-- A POST: the invitation's proof rides this browser's session, never the URL. --%>
        <.form
          :for={provider <- @providers}
          for={%{}}
          action={~p"/sign_in/sso/invitation"}
          method="post"
        >
          <input type="hidden" name="provider_id" value={provider.id} />
          <.button class="w-full">
            Continue with {provider.name} <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
      <p :if={@providers == []} class="text-sm leading-6 text-zinc-400">
        No single sign-on connection is available right now. Ask your administrator, then open
        your invitation email again.
      </p>
    </.auth_layout>
    """
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title={"Sign in to #{@account.name}"}>
      <p :if={@account.disabled_at} class="text-sm leading-6 text-zinc-300">
        This workspace is disabled. Contact
        <a class="font-medium text-white underline" href="mailto:support@emisar.dev">
          support@emisar.dev
        </a>
        to restore access.
      </p>
      <div :if={@providers != []} class="space-y-3">
        <%!-- Full redirect (begin is a controller that bounces to the IdP), not live nav. --%>
        <.button :for={provider <- @providers} href={~p"/sign_in/sso/#{provider.id}"} class="w-full">
          Continue with {provider.name} <span aria-hidden="true">→</span>
        </.button>
      </div>
      <p :if={@providers != [] and not @email?} class="mt-4 text-sm text-zinc-400">
        This workspace requires single sign-on. Continue with your identity provider.
      </p>
      <.or_separator :if={@providers != [] and @email?} label="or with email" />

      <p :if={@email?} class="mb-4 text-sm text-zinc-400">
        Enter your email for a one-time sign-in link and a 6-character code. They expire in 15 minutes.
      </p>

      <.simple_form
        :if={@email?}
        for={@form}
        action={~p"/app/#{@account}/sign_in/email"}
        method="post"
      >
        <.input field={@form[:email]} type="email" label="Work email" autocomplete="email" required />
        <:actions>
          <.button class="w-full">
            Send sign-in link
          </.button>
        </:actions>
      </.simple_form>

      <.auth_footer_link :if={is_nil(@account.disabled_at)} href={~p"/sign_in"}>
        Sign in to a different workspace
      </.auth_footer_link>
    </.auth_layout>
    """
  end
end
