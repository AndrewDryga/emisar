defmodule EmisarWeb.SSOController do
  @moduledoc """
  The OIDC relying-party login endpoints. `begin/2` redirects to the IdP
  (stashing the one-time-use, session-bound state/nonce/PKCE-verifier in the
  session — there is no user-agent binding; do not add one to this docstring
  without adding it to `begin/2` and `callback/2`). `callback/2` validates the
  response, then either completes an anonymous sign-in through `Emisar.SSO` or
  completes an authenticated, purpose-bound member MFA-reset reauthentication.
  The reset branch preserves the actor's existing session and never provisions
  or signs in an identity.

  The `redirect_uri` is the fixed registered callback (never attacker-supplied),
  and the post-login redirect is `UserAuth`'s internal `user_return_to`/
  `signed_in_path` — so there is no open-redirect surface here (H2).
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, SSO, Users}
  alias EmisarWeb.RecentAccounts
  alias EmisarWeb.UserAuth
  require Logger

  # The login transaction secrets the callback needs, kept server-side in the
  # session (signed, bound to this browser) for the duration of the round-trip.
  @stash_key :sso_login
  @member_mfa_reset_stash_key :member_mfa_reset_sso

  def begin(conn, %{"provider_id" => provider_id}) do
    redirect_uri = url(~p"/sign_in/sso/callback")

    with {:ok, provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, begun} <- SSO.begin_auth(provider, redirect_uri: redirect_uri) do
      conn
      |> delete_session(@member_mfa_reset_stash_key)
      |> put_session(@stash_key, %{
        provider_id: provider.id,
        state: begun.state,
        nonce: begun.nonce,
        pkce_verifier: begun.pkce_verifier,
        redirect_uri: redirect_uri
      })
      |> redirect(external: begun.authorize_url)
    else
      other ->
        # The operator gets one sentence; the reason belongs in the log. Discarding
        # it left a misconfigured issuer, a blocked address and an IdP that is
        # simply down all looking identical from the outside — a bounce back to the
        # sign-in page with nothing written down anywhere.
        Logger.warning("SSO begin failed for provider #{provider_id}: #{describe_failure(other)}")
        sso_error(conn, "That single sign-on link is no longer available.")
    end
  end

  def begin_member_mfa_reset(
        conn,
        %{
          "account_id_or_slug" => account_ref,
          "membership_id" => membership_id
        }
      ) do
    redirect_uri = url(~p"/sign_in/sso/callback")

    with %Users.User{} <- conn.assigns[:current_user],
         %Auth.UserToken{token: actor_session_token_digest} <- conn.assigns[:current_auth],
         {:ok, subject} <- UserAuth.subject_for_account(conn, account_ref),
         true <- Accounts.subject_can_manage_team?(subject),
         {:ok, %{reset_mfa?: true, membership: target_membership}} <-
           Accounts.fetch_team_member_facts(membership_id, subject),
         {:ok, begun} <-
           SSO.begin_member_mfa_reset_reauthentication(
             redirect_uri,
             actor_session_token_digest,
             subject
           ) do
      target_user = target_membership.user

      stash =
        begun
        |> Map.take([
          :actor_id,
          :actor_membership_id,
          :actor_session_token_digest,
          :account_id,
          :identity_id,
          :provider_identifier,
          :provider_id,
          :namespace,
          :started_at,
          :state,
          :nonce,
          :pkce_verifier
        ])
        |> Map.put(:redirect_uri, redirect_uri)
        |> Map.put(:target_membership_id, membership_id)
        |> Map.put(:target_user_id, target_user.id)
        |> Map.put(:target_mfa_enabled_at, target_user.mfa_enabled_at)
        |> Map.put(:target_updated_at, target_user.updated_at)

      conn
      |> delete_session(@stash_key)
      |> put_session(@member_mfa_reset_stash_key, stash)
      |> redirect(external: begun.authorize_url)
    else
      other ->
        Logger.warning("member MFA reset SSO begin failed: #{describe_failure(other)}")

        conn
        |> delete_session(@member_mfa_reset_stash_key)
        |> put_flash(:error, "SSO reauthentication is not available for this reset.")
        |> redirect(to: ~p"/app/#{account_ref}/settings/team")
    end
  end

  # httpc reports a connect failure as `{protocol, options, reason}`, and for TLS
  # those options carry the whole CA store — so a plain inspect truncates on the
  # certificates and drops the reason, which is the only part worth logging.
  defp describe_failure({:error, {:failed_connect, details}}) do
    address =
      case List.keyfind(details, :to_address, 0) do
        {:to_address, {host, port}} -> "#{host}:#{port}"
        _ -> "unknown address"
      end

    reason =
      Enum.find_value(details, "no reason reported", fn
        {protocol, _options, reason} -> "#{protocol}: #{inspect(reason)}"
        _ -> nil
      end)

    "could not connect to #{address} — #{reason}"
  end

  defp describe_failure(other), do: inspect(other)

  def callback(conn, params) do
    case {get_session(conn, @member_mfa_reset_stash_key), conn.assigns[:current_user]} do
      {%{} = stash, _current_user} ->
        complete_member_mfa_reset(conn, params, stash)

      {nil, %Users.User{}} ->
        conn
        |> delete_session(@stash_key)
        |> redirect(to: ~p"/app")

      {nil, nil} ->
        complete_sign_in(conn, params)
    end
  end

  defp complete_sign_in(conn, params) do
    with %{provider_id: provider_id} = stash <- get_session(conn, @stash_key),
         {:ok, started_provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, %{user: user, identity: identity, provider: provider, created?: created?}} <-
           SSO.complete_auth(started_provider, params, stash),
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

      case UserAuth.log_in_sso_user_for_account(
             conn,
             user,
             account.id,
             user_identity_id: identity.id,
             provider_identifier: identity.provider_identifier,
             registered?: created?
           ) do
        {:ok, conn} ->
          conn

        {:error, :account_disabled} ->
          redirect_to_disabled_account(conn, account)

        {:error, :provider_disabled} ->
          sso_error(conn, callback_error_message(:provider_disabled))
      end
    else
      nil ->
        # No stash: this browser never started the sign-in it is finishing. Worth
        # saying, because it is also what a cookie dropped between the two
        # requests looks like.
        Logger.warning("SSO callback arrived with no sign-in stash in the session")
        sso_error(conn, "Your sign-in session expired. Start again.")

      {:pending, request} ->
        redirect_to_pending(conn, request)

      {:error, reason} ->
        # The operator gets one sentence; the reason belongs in the log. A callback
        # can fail on state, nonce, PKCE, the token exchange, an email domain or a
        # disabled provider, and every one of them looked identical from outside —
        # a bounce to the sign-in page with nothing written down.
        Logger.warning("SSO callback failed: #{describe_failure({:error, reason})}")
        sso_error(conn, callback_error_message(reason))
    end
  end

  defp complete_member_mfa_reset(conn, params, stash) do
    account_ref = Map.get(stash, :account_id)
    target_membership_id = Map.get(stash, :target_membership_id)

    with %Users.User{} <- conn.assigns[:current_user],
         %Auth.UserToken{token: actor_session_token_digest} <- conn.assigns[:current_auth],
         account_id when is_binary(account_id) <- account_ref,
         membership_id when is_binary(membership_id) <- target_membership_id,
         {:ok, subject} <- UserAuth.subject_for_account(conn, account_id),
         {:ok, %{reset_mfa?: true, membership: membership}} <-
           Accounts.fetch_team_member_facts(membership_id, subject),
         {:ok, reauthentication} <-
           SSO.complete_member_mfa_reset_reauthentication(
             params,
             stash,
             actor_session_token_digest,
             subject
           ),
         {:ok, proof} <-
           Accounts.issue_member_mfa_reset_sso_proof(
             membership,
             reauthentication,
             actor_session_token_digest,
             subject
           ),
         {:ok, _user} <-
           Accounts.reset_member_mfa(
             membership,
             proof,
             actor_session_token_digest,
             subject
           ) do
      conn
      |> delete_session(@member_mfa_reset_stash_key)
      |> put_flash(:info, "2FA reset. They can set up a new authenticator after signing in.")
      |> redirect(to: ~p"/app/#{subject.account}/settings/team")
    else
      reason ->
        Logger.warning("member MFA reset SSO callback failed: #{describe_failure(reason)}")

        conn
        |> delete_session(@member_mfa_reset_stash_key)
        |> put_flash(:error, "SSO reauthentication failed. Start the reset again.")
        |> redirect(to: member_mfa_reset_failure_path(account_ref))
    end
  end

  defp member_mfa_reset_failure_path(account_id) when is_binary(account_id),
    do: ~p"/app/#{account_id}/settings/team"

  defp member_mfa_reset_failure_path(_account_id), do: ~p"/app"

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
