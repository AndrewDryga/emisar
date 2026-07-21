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
  alias EmisarWeb.RecentAccounts
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
    with %{provider_id: provider_id} = stash <- get_session(conn, @stash_key),
         {:ok, provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, %{user: user, identity: identity, created?: created?}} <-
           SSO.complete_auth(provider, params, stash),
         {:ok, account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(provider.account_id) do
      # Keep a protected destination that sent the user to sign-in (including an
      # OAuth authorization request). Otherwise land on the account whose IdP
      # this is, not the user's stale default. `user_return_to` is server-owned;
      # no callback parameter can choose the post-login destination.
      conn =
        conn
        |> delete_session(@stash_key)
        |> put_default_return_to(~p"/app/#{account}")
        |> RecentAccounts.put(%{slug: account.slug, name: account.name})

      case UserAuth.log_in_user_for_account(
             conn,
             user,
             account.id,
             :sso,
             SSO.provider_satisfies_mfa?(provider),
             user_identity_id: identity.id,
             registered?: created?
           ) do
        {:ok, conn} -> conn
        {:error, :account_disabled} -> redirect_to_disabled_account(conn, account)
      end
    else
      nil -> sso_error(conn, "Your sign-in session expired. Start again.")
      {:pending, request} -> redirect_to_pending(conn, request)
      {:error, reason} -> sso_error(conn, callback_error_message(reason))
    end
  end

  defp put_default_return_to(conn, path) do
    case get_session(conn, :user_return_to) do
      return_to when is_binary(return_to) and return_to != "" -> conn
      _ -> put_session(conn, :user_return_to, path)
    end
  end

  # A :manual-provisioner first login is parked as a link request — send them to
  # the live pending-approval page instead of bouncing to /sign_in with an error.
  # The request id rides a signed session cookie, so only this browser (the person
  # who just authenticated) sees this request.
  defp redirect_to_pending(conn, request) do
    conn
    |> delete_session(@stash_key)
    |> put_session(:sso_pending_request, request.id)
    |> redirect(to: ~p"/sign_in/sso/pending")
  end

  defp callback_error_message(:email_taken) do
    "An account already exists for this email. Ask an admin to link your single sign-on identity."
  end

  defp callback_error_message(:identity_pending_approval) do
    "Your access request was sent to your team admin. You'll be able to sign in once it's approved."
  end

  defp callback_error_message(:email_domain_not_allowed) do
    "Your email domain isn't permitted for this single sign-on connection. Contact your team admin."
  end

  defp callback_error_message(_other),
    do: "Single sign-on failed. Try again, or contact your team admin."

  defp sso_error(conn, message) do
    conn
    |> delete_session(@stash_key)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign_in")
  end

  defp redirect_to_disabled_account(conn, account) do
    conn
    |> delete_session(:user_return_to)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end
end
