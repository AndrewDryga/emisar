defmodule EmisarWeb.SSOController do
  @moduledoc """
  The OIDC relying-party login endpoints. `begin/2` redirects to the IdP
  (stashing session-bound state/nonce/PKCE-verifier in the encrypted browser
  session). The callback response clears that stash; the IP/provider budgets
  bound replay of a copied pre-response cookie. `callback/2` validates the response,
  then either completes an anonymous sign-in through `Emisar.SSO` or completes an
  authenticated, purpose-bound member MFA-reset reauthentication.
  The reset branch preserves the actor's existing session and never provisions
  or signs in an identity.

  The `redirect_uri` is the fixed registered callback (never attacker-supplied),
  and the post-login redirect is `UserAuth`'s internal `user_return_to`/
  `signed_in_path` — so there is no open-redirect surface here (H2).
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, SSO, Users}
  alias EmisarWeb.OIDCIdentityHandoff
  alias EmisarWeb.RecentAccounts
  alias EmisarWeb.UserAuth
  require Logger

  # The IP boundary runs before lookup on every route that can start OIDC work.
  # Provider work is capped separately, on the canonical loaded provider id, in
  # the shared OIDC adapter so login, callback replay, and MFA-reset reauth cannot
  # bypass one another's allowance.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "sso_oidc_ip", limit: 20, window_ms: 60_000, by: :ip]
       when action in [:begin, :callback, :begin_member_mfa_reset, :begin_identity_link]

  # The login transaction secrets the callback needs, kept server-side in the
  # session (signed, bound to this browser) for the duration of the round-trip.
  @stash_key :sso_login
  @member_mfa_reset_stash_key :member_mfa_reset_sso
  @identity_link_stash_key :sso_identity_link

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
      {:error, :not_found} ->
        sso_error(conn, "That single sign-on link is no longer available.")

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{
          error: "rate_limited",
          message: "Too many requests. Retry in 60s."
        })

      other ->
        # The operator gets one sentence; the reason belongs in the log. Discarding
        # it left a misconfigured issuer, a blocked address and an IdP that is
        # simply down all looking identical from the outside — a bounce back to the
        # sign-in page with nothing written down anywhere.
        log_failure("sso_begin_failed", other)
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
        log_failure("member_mfa_reset_sso_begin_failed", other)

        conn
        |> delete_session(@member_mfa_reset_stash_key)
        |> put_flash(:error, "SSO reauthentication is not available for this reset.")
        |> redirect(to: ~p"/app/#{account_ref}/settings/team")
    end
  end

  def begin_identity_link(
        conn,
        %{"account_id_or_slug" => account_ref, "handoff" => handoff}
      ) do
    redirect_uri = url(~p"/sign_in/sso/callback")

    with %Users.User{} = user <- conn.assigns[:current_user],
         %Auth.UserToken{token: actor_session_token_digest} <- conn.assigns[:current_auth],
         {:ok, subject} <- UserAuth.subject_for_account(conn, account_ref),
         {:ok, payload} <- OIDCIdentityHandoff.verify(handoff),
         {:ok, provider_id, purpose, proof} <-
           identity_handoff_payload(payload, user, subject, actor_session_token_digest),
         {:ok, begun} <-
           SSO.begin_identity_link(
             provider_id,
             purpose,
             redirect_uri,
             proof,
             actor_session_token_digest,
             subject
           ) do
      stash =
        begun
        |> Map.take([
          :actor_id,
          :actor_membership_id,
          :actor_session_token_digest,
          :account_id,
          :provider_id,
          :namespace,
          :purpose,
          :local_proof,
          :started_at,
          :state,
          :nonce,
          :pkce_verifier
        ])
        |> Map.put(:redirect_uri, redirect_uri)
        |> Map.put(:return_path, identity_link_return_path(subject.account, provider_id, purpose))

      conn
      |> delete_session(@stash_key)
      |> delete_session(@member_mfa_reset_stash_key)
      |> put_session(@identity_link_stash_key, stash)
      |> redirect(external: begun.authorize_url)
    else
      reason ->
        log_failure("sso_identity_link_begin_failed", reason)

        conn
        |> delete_session(@identity_link_stash_key)
        |> put_flash(:error, "Couldn't start provider sign-in. Confirm your code and try again.")
        |> redirect(to: identity_link_failure_path(account_ref))
    end
  end

  @failure_events ~w[sso_begin_failed sso_callback_failed
                     member_mfa_reset_sso_begin_failed
                     member_mfa_reset_sso_callback_failed
                     sso_identity_link_begin_failed
                     sso_identity_link_callback_failed]

  # oidcc/httpc errors may carry token records, full claims, raw response bodies,
  # unknown key ids, and the TLS option list (including the CA store). Only the
  # outer shape is diagnostic; no nested dependency value is log-safe.
  defp log_failure(event, failure) when event in @failure_events do
    Logger.warning("#{event} reason=#{failure_reason(failure)}")
  end

  defp failure_reason({:error, reason}), do: failure_reason(reason)
  defp failure_reason({:failed_connect, _details}), do: "idp_unreachable"
  defp failure_reason({:timeout, _details}), do: "idp_unreachable"

  defp failure_reason(reason) when reason in [:timeout, :econnrefused, :closed],
    do: "idp_unreachable"

  defp failure_reason(reason)
       when reason in [:token_endpoint_unreachable, :discovery_failed, :unreachable],
       do: "idp_unreachable"

  defp failure_reason({:http_error, status, _body}) when status in 400..499,
    do: "idp_request_rejected"

  defp failure_reason({:http_error, status, _body}) when status in 500..599,
    do: "idp_unavailable"

  defp failure_reason({:http_error, _status, _body}), do: "idp_http_error"
  defp failure_reason(:invalid_content_type), do: "idp_response_invalid"
  defp failure_reason({:missing_config_property, _field}), do: "provider_config_invalid"
  defp failure_reason({:invalid_config_property, _field}), do: "provider_config_invalid"
  defp failure_reason({:grant_type_not_supported, _grant}), do: "provider_config_invalid"

  defp failure_reason(reason)
       when reason in [
              :par_required,
              :request_object_required,
              :purpose_required,
              :no_supported_code_challenge,
              :no_supported_auth_method,
              :provider_not_ready,
              :blocked_discovery_endpoint
            ],
       do: "provider_config_invalid"

  defp failure_reason(:pkce_verifier_required), do: "authorization_state_invalid"

  defp failure_reason(:state_mismatch), do: "state_mismatch"
  defp failure_reason(:issuer_mismatch), do: "issuer_mismatch"
  defp failure_reason({:issuer_mismatch, _issuer}), do: "issuer_mismatch"
  defp failure_reason(:missing_code), do: "authorization_code_missing"
  defp failure_reason(:missing_identifier_claim), do: "token_claims_invalid"
  defp failure_reason({:missing_claim, _claim, _claims}), do: "token_claims_invalid"
  defp failure_reason({:invalid_property, _property}), do: "token_response_invalid"
  defp failure_reason({:no_matching_key_with_kid, _kid}), do: "token_validation_failed"
  defp failure_reason({:none_alg_used, _token}), do: "token_validation_failed"
  defp failure_reason({:none_alg_used, _jwt, _jws}), do: "token_validation_failed"

  defp failure_reason(reason)
       when reason in [
              :no_matching_key,
              :invalid_jwt_token,
              :none_alg_used,
              :bad_access_token_hash,
              :sub_invalid,
              :token_expired,
              :token_not_yet_valid,
              :not_encrypted
            ],
       do: "token_validation_failed"

  defp failure_reason(:not_found), do: "request_context_unavailable"

  defp failure_reason(reason)
       when reason in [:provider_disabled, :directory_sync_disabled],
       do: "provider_unavailable"

  defp failure_reason({:account_disabled, _account}), do: "account_disabled"
  defp failure_reason(:account_disabled), do: "account_disabled"
  defp failure_reason(:email_domain_not_allowed), do: "email_domain_not_allowed"
  defp failure_reason(:email_taken), do: "email_already_bound"
  defp failure_reason(:identity_pending_approval), do: "identity_pending_approval"
  defp failure_reason(:identity_namespace_changed), do: "provider_config_changed"
  defp failure_reason(:identity_already_linked), do: "identity_conflict"
  defp failure_reason(:different_identity_already_linked), do: "identity_conflict"
  defp failure_reason(:identity_step_up_stale), do: "local_proof_stale"
  defp failure_reason(:identity_link_invalid), do: "identity_link_invalid"

  defp failure_reason(reason) when reason in [:invitation_pending, :mfa_not_enabled],
    do: "reset_target_unavailable"

  defp failure_reason(reason)
       when reason in [
              :mfa_reset_reauthentication_invalid,
              :mfa_reset_reauthentication_unavailable,
              :mfa_reset_proof_stale
            ],
       do: "reauthentication_invalid"

  defp failure_reason(%Ecto.Changeset{}), do: "domain_validation_failed"
  defp failure_reason(reason) when reason in [nil, false, :unauthorized], do: "unauthorized"
  defp failure_reason(_reason), do: "redacted_failure"

  def callback(conn, params) do
    case get_session(conn, @identity_link_stash_key) do
      %{} = stash ->
        complete_identity_link(conn, params, stash)

      nil ->
        complete_non_link_callback(conn, params)
    end
  end

  defp complete_non_link_callback(conn, params) do
    case {get_session(conn, @member_mfa_reset_stash_key), conn.assigns[:current_user]} do
      {%{} = stash, _current_user} -> complete_member_mfa_reset(conn, params, stash)
      {nil, %Users.User{}} -> conn |> delete_session(@stash_key) |> redirect(to: ~p"/app")
      {nil, nil} -> complete_sign_in(conn, params)
    end
  end

  defp complete_identity_link(conn, params, stash) do
    return_path = identity_link_stashed_return_path(stash)

    with %Users.User{} <- conn.assigns[:current_user],
         %Auth.UserToken{token: actor_session_token_digest} <- conn.assigns[:current_auth],
         account_id when is_binary(account_id) <- Map.get(stash, :account_id),
         {:ok, subject} <- UserAuth.subject_for_account(conn, account_id),
         {:ok, %{provider: provider, purpose: purpose}} <-
           SSO.complete_identity_link(
             params,
             stash,
             actor_session_token_digest,
             subject
           ) do
      message = identity_link_success_message(provider.name, purpose)

      conn
      |> delete_session(@identity_link_stash_key)
      |> put_flash(:info, message)
      |> redirect(to: return_path)
    else
      reason ->
        log_failure("sso_identity_link_callback_failed", reason)

        conn
        |> delete_session(@identity_link_stash_key)
        |> put_flash(:error, identity_link_error_message(reason))
        |> redirect(to: return_path)
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
        Logger.info("sso_callback_missing_stash")
        sso_error(conn, "Your sign-in session expired. Start again.")

      {:pending, request} ->
        redirect_to_pending(conn, request)

      {:error, reason} ->
        # The operator gets one sentence; the reason belongs in the log. A callback
        # can fail on state, nonce, PKCE, the token exchange, an email domain or a
        # disabled provider, and every one of them looked identical from outside —
        # a bounce to the sign-in page with nothing written down.
        log_failure("sso_callback_failed", {:error, reason})
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
        log_failure("member_mfa_reset_sso_callback_failed", reason)

        conn
        |> delete_session(@member_mfa_reset_stash_key)
        |> put_flash(:error, "SSO reauthentication failed. Start the reset again.")
        |> redirect(to: member_mfa_reset_failure_path(account_ref))
    end
  end

  defp identity_handoff_payload(
         %{
           actor_id: actor_id,
           actor_membership_id: membership_id,
           actor_session_token_digest: session_digest,
           account_id: account_id,
           provider_id: provider_id,
           purpose: purpose,
           proof: proof
         },
         %Users.User{id: actor_id},
         %{membership_id: membership_id, account: %{id: account_id}},
         session_digest
       )
       when is_binary(provider_id) and purpose in [:link, :verify_provider] and is_binary(proof),
       do: {:ok, provider_id, purpose, proof}

  defp identity_handoff_payload(_payload, _user, _subject, _session_digest),
    do: {:error, :invalid}

  defp identity_link_return_path(account, _provider_id, :link),
    do: ~p"/app/#{account}/settings/profile"

  defp identity_link_return_path(account, provider_id, :verify_provider),
    do: ~p"/app/#{account}/settings/sso/#{provider_id}"

  defp identity_link_stashed_return_path(%{
         account_id: account_id,
         provider_id: provider_id,
         purpose: purpose
       })
       when is_binary(account_id) and is_binary(provider_id) and
              purpose in [:link, :verify_provider],
       do: identity_link_return_path(account_id, provider_id, purpose)

  defp identity_link_stashed_return_path(_stash), do: ~p"/app"

  defp identity_link_failure_path(account_ref) when is_binary(account_ref),
    do: ~p"/app/#{account_ref}/settings/profile"

  defp identity_link_failure_path(_account_ref), do: ~p"/app"

  defp identity_link_success_message(provider_name, :link),
    do: "#{provider_name} is now linked to your profile."

  defp identity_link_success_message(provider_name, :verify_provider),
    do: "#{provider_name} sign-in verified and linked to your profile."

  defp identity_link_error_message({:error, reason}), do: identity_link_error_message(reason)

  defp identity_link_error_message(:identity_already_linked),
    do: "That provider identity is already linked to another profile. Nothing changed."

  defp identity_link_error_message(:different_identity_already_linked),
    do: "Your profile already has a different identity for this provider. Remove it first."

  defp identity_link_error_message(:identity_namespace_changed),
    do: "The provider settings changed during verification. Start again."

  defp identity_link_error_message(_reason),
    do: "Provider sign-in could not be verified. Start again."

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
