defmodule EmisarWeb.SSOController do
  @moduledoc """
  The OIDC relying-party login endpoints. `begin/2` redirects to the IdP
  (stashing the one-time-use, UA-bound state/nonce/PKCE-verifier in the
  session); `callback/2` validates the response, resolves/JIT-provisions the
  identity via `Emisar.SSO`, and logs the user in with `:sso` provenance.

  The `redirect_uri` is the fixed registered callback (never attacker-supplied),
  and the post-login redirect is `UserAuth`'s internal `user_return_to`/
  `signed_in_path` — so there is no open-redirect surface here (H2).
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts
  alias Emisar.SSO
  alias Emisar.Users
  alias EmisarWeb.RecentAccounts
  alias EmisarWeb.RequestContext
  alias EmisarWeb.UserAuth

  # The login transaction secrets the callback needs, kept server-side in the
  # session (signed, bound to this browser) for the duration of the round-trip.
  @stash_key :sso_login

  def begin(conn, %{"provider_id" => provider_id}) do
    redirect_uri = url(~p"/sign_in/sso/callback")

    with {:ok, provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, begun} <- SSO.begin_auth(provider, redirect_uri: redirect_uri) do
      conn
      |> put_session(@stash_key, %{
        provider_id: provider.id,
        state: begun.state,
        nonce: begun.nonce,
        pkce_verifier: begun.pkce_verifier,
        redirect_uri: redirect_uri
      })
      |> redirect(external: begun.authorize_url)
    else
      _ -> sso_error(conn, "That single sign-on link is no longer available.")
    end
  end

  def callback(conn, params) do
    context = RequestContext.from_conn(conn)

    with %{provider_id: provider_id} = stash <- get_session(conn, @stash_key),
         {:ok, provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, %{user: user, identity: identity, created?: created?}} <-
           SSO.complete_auth(provider, params, stash),
         {:ok, account} <- Accounts.fetch_account_by_id(provider.account_id) do
      Users.record_sign_in(user, "sso", context)

      # Land on the account whose IdP this is (not the user's stale default), and
      # remember it for the SSO landing page's one-click return. `mfa: true` — the
      # IdP performed the second factor when the provider enforces it (provenance,
      # not the gate). `user_return_to` is read by log_in_user *before* it renews
      # the session; the recent-accounts cookie is separate, so renew keeps it.
      conn
      |> delete_session(@stash_key)
      |> put_session(:user_return_to, ~p"/app/#{account}")
      |> RecentAccounts.put(%{slug: account.slug, name: account.name})
      |> UserAuth.log_in_user(user, :sso, SSO.provider_satisfies_mfa?(provider), %{},
        user_identity_id: identity.id,
        registered?: created?
      )
    else
      nil -> sso_error(conn, "Your sign-in session expired. Start again.")
      {:error, reason} -> sso_error(conn, callback_error_message(reason))
    end
  end

  defp callback_error_message(:email_taken),
    do:
      "An account already exists for this email. Ask an admin to link your single sign-on identity."

  defp callback_error_message(:identity_pending_approval),
    do:
      "Your access request was sent to your team admin. You'll be able to sign in once it's approved."

  defp callback_error_message(:email_domain_not_allowed),
    do:
      "Your email domain isn't permitted for this single sign-on connection. Contact your team admin."

  defp callback_error_message(_other),
    do: "Single sign-on failed. Try again, or contact your team admin."

  defp sso_error(conn, message) do
    conn
    |> delete_session(@stash_key)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign_in")
  end
end
