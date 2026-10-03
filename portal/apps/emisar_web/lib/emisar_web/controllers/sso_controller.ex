defmodule EmisarWeb.SSOController do
  @moduledoc """
  The OIDC relying-party endpoints. Every ceremony keeps its OIDC state, nonce
  and PKCE verifier in the encrypted browser session, under its own key, for
  the round trip; the callback response clears it, and the IP/provider budgets
  bound replay of a copied pre-response cookie.

    * `begin/2` — ordinary sign-in at a workspace's identity provider
    * `begin_invitation/2` — an invitee in a workspace that signs in only through
      SSO continues its acceptance there; the proof its emailed code earned
      rides the session, never a URL
    * `begin_mfa_enrollment/2` — a Member without a verified email proves its
      own credential before adding an authenticator
    * `begin_identity_link/2` — an administrator verifies a connection by
      signing in through it
    * `begin_member_mfa_reset/2` — an administrator's fresh reauthentication
      before resetting another Member's factor

  `callback/2` serves them all at the one registered callback URL and
  dispatches on the stash present, in a fixed order: the invitation step, MFA
  enrollment, connection verification, member MFA reset, then ordinary sign-in.
  A present stash owns the callback even when it is invalid, so an
  authenticated ceremony never falls through to sign-in or JIT provisioning.
  The authenticated ceremonies act through this browser's session for the
  stashed workspace (`UserAuth.subject_for_account/2`) and that session's
  digest; a sign-in's workspace comes from the stashed provider, never a
  request parameter.

  The `redirect_uri` is the fixed registered callback (never attacker-supplied),
  and every post-callback redirect is a server-built path — so there is no
  open-redirect surface here.
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, SSO}
  alias EmisarWeb.{OIDCIdentityHandoff, RequestContext, UserAuth}
  require Logger

  plug :put_layout, [html: {EmisarWeb.Layouts, :app}] when action in [:begin_identity_link]

  # The IP boundary runs before lookup on every route that can start OIDC work.
  # Provider work is capped separately, on the canonical loaded provider id, in
  # the shared OIDC adapter so sign-in, callback replay and the ceremonies
  # cannot bypass one another's allowance.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "sso_oidc_ip", limit: 20, window_ms: 60_000, by: :ip]
       when action in [
              :begin,
              :begin_invitation,
              :callback,
              :begin_mfa_enrollment,
              :begin_member_mfa_reset,
              :begin_identity_link
            ]

  @sign_in_stash_key :sso_login
  @invitation_stash_key :invitation_sso
  @mfa_enrollment_stash_key :mfa_enrollment_sso
  @identity_link_stash_key :sso_identity_link
  @member_mfa_reset_stash_key :member_mfa_reset_sso

  # The callback's dispatch order. The first stash present owns the callback.
  @ceremonies [
    invitation: @invitation_stash_key,
    mfa_enrollment: @mfa_enrollment_stash_key,
    identity_link: @identity_link_stash_key,
    member_mfa_reset: @member_mfa_reset_stash_key
  ]

  # Every begin clears every stash, so one round trip is in flight at a time.
  defp clear_ceremonies(conn) do
    Enum.reduce(
      [@sign_in_stash_key | Keyword.values(@ceremonies)],
      conn,
      &delete_session(&2, &1)
    )
  end

  # What the callback needs back: the OIDC secrets and the bindings the domain
  # returned, plus the fixed callback URL. Never the authorization URL itself.
  defp stash(begun, redirect_uri),
    do: begun |> Map.delete(:authorize_url) |> Map.put(:redirect_uri, redirect_uri)

  def begin(conn, %{"provider_id" => provider_id}) do
    # The browser id is minted when a sign-in starts, so two tabs completing at
    # once present the same id and a later sign-out reaches both sessions.
    {conn, _browser_id} = conn |> clear_ceremonies() |> UserAuth.fetch_browser_id()
    redirect_uri = url(~p"/sign_in/sso/callback")

    with {:ok, provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, begun} <- SSO.begin_auth(provider, redirect_uri: redirect_uri) do
      conn
      |> put_session(@sign_in_stash_key, %{
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

  @doc """
  An invitee's SSO step. Its emailed code proved the invited address in a
  workspace that refuses email sign-in; the proof — bound to this browser —
  waits in the session, and the chosen provider accepts the invitation, binds
  the returned identity to the invited Member and signs it in, in one
  transaction at the callback.
  """
  def begin_invitation(conn, %{"provider_id" => provider_id}) when is_binary(provider_id) do
    conn = clear_ceremonies(conn)
    redirect_uri = url(~p"/sign_in/sso/callback")

    with proof when is_binary(proof) <- get_session(conn, :invitation_sso_proof),
         browser_id when is_binary(browser_id) <- UserAuth.browser_id(conn),
         {:ok, begun} <-
           SSO.begin_invitation_sso_sign_in(proof, provider_id, redirect_uri, browser_id),
         :ok <- validate_authorize_url(begun.authorize_url) do
      conn
      |> put_session(@invitation_stash_key, stash(begun, redirect_uri))
      |> put_resp_header("cache-control", "no-store")
      |> redirect(external: begun.authorize_url)
    else
      reason ->
        log_failure("invitation_sso_begin_failed", reason)

        conn
        |> put_flash(:error, "Couldn't continue with single sign-on. Try again.")
        |> redirect(to: invitation_retry_path(conn))
    end
  end

  def begin_invitation(conn, _params), do: redirect(conn, to: invitation_retry_path(conn))

  @doc """
  An SSO-only Member's fresh reauthentication before it adds an authenticator.
  Only the session making this request, and the identity it signed in with,
  can start it; the callback hands the MFA setup page a short-lived proof.
  """
  def begin_mfa_enrollment(conn, _params) do
    conn = clear_ceremonies(conn)
    redirect_uri = url(~p"/sign_in/sso/callback")
    %{current_auth: %Auth.UserToken{token: digest}, current_subject: subject} = conn.assigns

    with {:ok, begun} <- SSO.begin_mfa_enrollment_reauthentication(redirect_uri, digest, subject),
         :ok <- validate_authorize_url(begun.authorize_url) do
      conn
      |> put_session(@mfa_enrollment_stash_key, stash(begun, redirect_uri))
      |> put_resp_header("cache-control", "no-store")
      |> redirect(external: begun.authorize_url)
    else
      reason ->
        log_failure("mfa_enrollment_sso_begin_failed", reason)

        conn
        |> put_flash(:error, "Couldn't start single sign-on. Try again.")
        |> redirect(to: ~p"/app/#{subject.account}/mfa_setup")
    end
  end

  def begin_member_mfa_reset(conn, %{"membership_id" => membership_id}) do
    conn = clear_ceremonies(conn)
    redirect_uri = url(~p"/sign_in/sso/callback")
    %{current_auth: %Auth.UserToken{token: digest}, current_subject: subject} = conn.assigns

    # The acting administrator may have no verified email: its fresh IdP
    # reauthentication is then the only reset proof it can give.
    with true <- Accounts.subject_can_manage_team?(subject),
         {:ok, %{reset_mfa?: true, membership: target}} <-
           Accounts.fetch_team_member_facts(membership_id, subject),
         {:ok, begun} <-
           SSO.begin_member_mfa_reset_reauthentication(redirect_uri, digest, subject),
         :ok <- validate_authorize_url(begun.authorize_url) do
      stash =
        begun
        |> stash(redirect_uri)
        |> Map.merge(%{
          target_membership_id: target.id,
          target_mfa_enabled_at: target.mfa_enabled_at,
          target_updated_at: target.updated_at
        })

      conn
      |> put_session(@member_mfa_reset_stash_key, stash)
      |> redirect(external: begun.authorize_url)
    else
      other ->
        log_failure("member_mfa_reset_sso_begin_failed", other)

        conn
        |> put_flash(:error, "SSO reauthentication is not available for this reset.")
        |> redirect(to: ~p"/app/#{subject.account}/settings/team")
    end
  end

  def begin_identity_link(conn, %{"handoff" => handoff}) do
    conn = clear_ceremonies(conn)
    %{current_auth: %Auth.UserToken{token: digest}, current_subject: subject} = conn.assigns

    with {:ok, payload} <- OIDCIdentityHandoff.verify(handoff),
         {:ok, provider_id, proof} <- identity_handoff_payload(payload, subject, digest) do
      begin_bound_identity_link(conn, provider_id, proof, digest, subject)
    else
      reason ->
        identity_link_begin_error(conn, reason, ~p"/app/#{subject.account}/settings/sso")
    end
  end

  # Only a signed handoff bound to this Member, workspace and session may choose
  # the provider, including its return page when provider startup fails.
  defp begin_bound_identity_link(conn, provider_id, proof, digest, subject) do
    redirect_uri = url(~p"/sign_in/sso/callback")
    return_path = ~p"/app/#{subject.account}/settings/sso/#{provider_id}"

    with {:ok, begun} <-
           SSO.begin_identity_link(provider_id, redirect_uri, proof, digest, subject),
         :ok <- validate_authorize_url(begun.authorize_url) do
      conn
      |> put_session(@identity_link_stash_key, stash(begun, redirect_uri))
      |> put_resp_header("cache-control", "no-store")
      |> assign(:page_title, "Opening provider sign-in")
      |> assign(:authorize_url, begun.authorize_url)
      |> render(:identity_redirect)
    else
      reason ->
        identity_link_begin_error(conn, reason, return_path)
    end
  end

  defp identity_handoff_payload(
         %{
           actor_membership_id: membership_id,
           actor_session_token_digest: digest,
           account_id: account_id,
           provider_id: provider_id,
           proof: proof
         },
         %{membership_id: membership_id, account: %{id: account_id}},
         digest
       )
       when is_binary(provider_id) and is_binary(proof),
       do: {:ok, provider_id, proof}

  defp identity_handoff_payload(_payload, _subject, _digest), do: {:error, :invalid}

  defp identity_link_begin_error(conn, reason, return_path) do
    log_failure("sso_identity_link_begin_failed", reason)

    conn
    |> delete_session(@identity_link_stash_key)
    |> put_flash(:error, "Couldn't start provider sign-in. Confirm your code and try again.")
    |> redirect(to: return_path)
  end

  def callback(conn, params) do
    case pending_ceremony(conn) do
      {:invitation, stash} -> complete_invitation(conn, params, stash)
      {:mfa_enrollment, stash} -> complete_mfa_enrollment(conn, params, stash)
      {:identity_link, stash} -> complete_identity_link(conn, params, stash)
      {:member_mfa_reset, stash} -> complete_member_mfa_reset(conn, params, stash)
      :sign_in -> complete_sign_in(conn, params)
    end
  end

  # Any present ceremony stash owns this callback, even when it is invalid: it
  # must never fall through into anonymous sign-in or JIT provisioning.
  defp pending_ceremony(conn) do
    Enum.find_value(@ceremonies, :sign_in, fn {ceremony, key} ->
      case get_session(conn, key) do
        nil -> nil
        stash -> {ceremony, stash}
      end
    end)
  end

  defp complete_invitation(conn, params, stash) do
    conn = delete_session(conn, @invitation_stash_key)
    context = RequestContext.from_conn(conn)

    with browser_id when is_binary(browser_id) <- UserAuth.browser_id(conn),
         {:ok, token, membership} <-
           SSO.complete_invitation_sso_sign_in(params, stash, browser_id, context) do
      UserAuth.log_in_invitation_sso_member(conn, membership, token)
    else
      reason ->
        log_failure("invitation_sso_callback_failed", reason)
        invitation_failed(conn, reason)
    end
  end

  # The invitation itself is gone (accepted, revoked, resent) or its proved code
  # lapsed: nothing to retry, so the proof leaves the session too.
  defp invitation_failed(conn, {:error, reason})
       when reason in [:invitation_invalid, :invalid_or_expired] do
    conn
    |> delete_session(:invitation_sso_proof)
    |> put_flash(
      :error,
      "This invitation can no longer be accepted. Sign in if you already joined, or ask for a fresh invitation."
    )
    |> redirect(to: ~p"/sign_in")
  end

  # Anything else may succeed on a retry while the proof lasts; the workspace's
  # sign-in page offers the step again.
  defp invitation_failed(conn, reason) do
    conn
    |> put_flash(:error, invitation_error_message(reason))
    |> redirect(to: invitation_retry_path(conn))
  end

  defp invitation_error_message({:error, :identity_already_linked}) do
    "That identity already belongs to another member of this workspace. Ask your administrator."
  end

  defp invitation_error_message({:error, reason}),
    do: callback_error_message(reason)

  defp invitation_error_message(_reason), do: callback_error_message(nil)

  # The workspace's sign-in page offers the step again while the proof lasts.
  defp invitation_retry_path(conn) do
    case UserAuth.invitation_sso_account_id(conn) do
      account_id when is_binary(account_id) -> ~p"/app/#{account_id}/sign_in"
      nil -> ~p"/sign_in"
    end
  end

  defp complete_mfa_enrollment(conn, params, stash) do
    conn = delete_session(conn, @mfa_enrollment_stash_key)
    account_id = stashed_account_id(stash)

    with {:ok, subject, digest} <- ceremony_session(conn, account_id),
         {:ok, reauthentication} <-
           SSO.complete_mfa_enrollment_reauthentication(params, stash, digest, subject),
         {:ok, proof} <-
           Auth.issue_mfa_enrollment_proof_for_sso(reauthentication, digest, subject) do
      # The MFA setup page reads the proof from the encrypted session; the
      # enrollment re-checks it, and the route it names, on the locked rows.
      conn
      |> put_session(:mfa_enrollment_proof, proof)
      |> redirect(to: ~p"/app/#{subject.account}/mfa_setup")
    else
      reason ->
        log_failure("mfa_enrollment_sso_callback_failed", reason)

        conn
        |> put_flash(:error, "Single sign-on couldn't confirm it was you. Start again.")
        |> redirect(to: workspace_path(account_id, "mfa_setup"))
    end
  end

  defp complete_identity_link(conn, params, stash) do
    conn = delete_session(conn, @identity_link_stash_key)
    return_path = identity_link_return_path(stash)

    with {:ok, subject, digest} <- ceremony_session(conn, stashed_account_id(stash)),
         {:ok, %{provider: provider}} <-
           SSO.complete_identity_link(params, stash, digest, subject) do
      conn
      |> put_flash(:info, "#{provider.name} sign-in verified and linked to your profile.")
      |> redirect(to: return_path)
    else
      reason ->
        log_failure("sso_identity_link_callback_failed", reason)

        conn
        |> put_flash(:error, identity_link_error_message(reason))
        |> redirect(to: return_path)
    end
  end

  defp complete_member_mfa_reset(conn, params, stash) do
    conn = delete_session(conn, @member_mfa_reset_stash_key)
    account_id = stashed_account_id(stash)

    with {:ok, subject, digest} <- ceremony_session(conn, account_id),
         membership_id when is_binary(membership_id) <- stashed_target_id(stash),
         {:ok, %{reset_mfa?: true, membership: membership}} <-
           Accounts.fetch_team_member_facts(membership_id, subject),
         {:ok, reauthentication} <-
           SSO.complete_member_mfa_reset_reauthentication(params, stash, digest, subject),
         {:ok, proof} <-
           Accounts.issue_member_mfa_reset_sso_proof(
             membership,
             reauthentication,
             digest,
             subject
           ),
         {:ok, _membership} <- Accounts.reset_member_mfa(membership, proof, digest, subject) do
      conn
      |> put_flash(:info, "MFA reset. They can set up a new authenticator after signing in.")
      |> redirect(to: ~p"/app/#{subject.account}/settings/team")
    else
      reason ->
        log_failure("member_mfa_reset_sso_callback_failed", reason)

        conn
        |> put_flash(:error, "SSO reauthentication failed. Start the reset again.")
        |> redirect(to: workspace_path(account_id, "settings/team"))
    end
  end

  # An authenticated ceremony acts through this browser's own live session for
  # the stashed workspace, bound to that session's digest; the domain re-checks
  # the stash against both.
  defp ceremony_session(conn, account_id) when is_binary(account_id) do
    with {:ok, subject} <- UserAuth.subject_for_account(conn, account_id),
         {:ok, %Auth.UserToken{token: digest}} <- Auth.fetch_current_session(subject) do
      {:ok, subject, digest}
    end
  end

  defp ceremony_session(_conn, _account_id), do: {:error, :not_found}

  defp stashed_account_id(%{account_id: account_id}) when is_binary(account_id), do: account_id
  defp stashed_account_id(_stash), do: nil

  defp stashed_target_id(%{target_membership_id: id}) when is_binary(id), do: id
  defp stashed_target_id(_stash), do: nil

  defp workspace_path(account_id, "mfa_setup") when is_binary(account_id),
    do: ~p"/app/#{account_id}/mfa_setup"

  defp workspace_path(account_id, "settings/team") when is_binary(account_id),
    do: ~p"/app/#{account_id}/settings/team"

  defp workspace_path(_account_id, _page), do: ~p"/sign_in"

  defp identity_link_return_path(%{account_id: account_id, provider_id: provider_id})
       when is_binary(account_id) and is_binary(provider_id),
       do: ~p"/app/#{account_id}/settings/sso/#{provider_id}"

  defp identity_link_return_path(_stash), do: ~p"/sign_in"

  defp complete_sign_in(conn, params) do
    with %{provider_id: provider_id} = stash <- get_session(conn, @sign_in_stash_key),
         {:ok, started_provider} <- SSO.fetch_provider_for_sign_in(provider_id),
         {:ok, %{provider: provider} = auth} <-
           SSO.complete_auth(started_provider, params, stash),
         {:ok, account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(provider.account_id) do
      conn = delete_session(conn, @sign_in_stash_key)

      case UserAuth.log_in_sso_member(conn, auth, account) do
        {:ok, conn} -> conn
        {:error, :account_disabled} -> redirect_to_disabled_account(conn, account)
        {:error, reason} -> sso_error(conn, callback_error_message(reason))
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

      other ->
        log_failure("sso_callback_failed", other)
        sso_error(conn, "Your sign-in session expired. Start again.")
    end
  end

  @failure_events ~w[sso_begin_failed sso_callback_failed
                     invitation_sso_begin_failed
                     invitation_sso_callback_failed
                     mfa_enrollment_sso_begin_failed
                     mfa_enrollment_sso_callback_failed
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
              :blocked_discovery_endpoint,
              :no_supported_id_token_signing_alg
            ],
       do: "provider_config_invalid"

  defp failure_reason(:pkce_verifier_required), do: "authorization_state_invalid"

  defp failure_reason(:state_mismatch), do: "state_mismatch"
  defp failure_reason(:issuer_mismatch), do: "issuer_mismatch"
  defp failure_reason({:issuer_mismatch, _issuer}), do: "issuer_mismatch"
  defp failure_reason(:missing_code), do: "authorization_code_missing"
  defp failure_reason(:missing_identifier_claim), do: "token_claims_invalid"
  defp failure_reason({:missing_claim, _claim, _claims}), do: "token_claims_invalid"
  defp failure_reason(:missing_id_token), do: "token_response_invalid"
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
       when reason in [:provider_disabled, :directory_sync_disabled, :sso_not_available],
       do: "provider_unavailable"

  defp failure_reason({:account_disabled, _account}), do: "account_disabled"
  defp failure_reason(:account_disabled), do: "account_disabled"
  defp failure_reason(:email_domain_not_allowed), do: "email_domain_not_allowed"
  defp failure_reason(:member_email_taken), do: "member_email_taken"
  defp failure_reason(:identity_pending_approval), do: "identity_pending_approval"
  defp failure_reason(:identity_namespace_changed), do: "provider_config_changed"
  defp failure_reason(:identity_already_linked), do: "identity_conflict"
  defp failure_reason(:different_identity_already_linked), do: "identity_conflict"
  defp failure_reason(:identity_step_up_stale), do: "local_proof_stale"
  defp failure_reason(:identity_link_invalid), do: "identity_link_invalid"
  defp failure_reason(:invitation_sso_invalid), do: "invitation_sso_invalid"
  defp failure_reason(:invitation_invalid), do: "invitation_unavailable"
  defp failure_reason(:invalid_or_expired), do: "code_invalid_or_expired"
  defp failure_reason(:mfa_already_enabled), do: "mfa_already_enabled"

  defp failure_reason(reason) when reason in [:invitation_pending, :mfa_not_enabled],
    do: "reset_target_unavailable"

  defp failure_reason(reason)
       when reason in [
              :mfa_reset_reauthentication_invalid,
              :mfa_reset_reauthentication_unavailable,
              :mfa_reset_proof_stale,
              :mfa_enrollment_reauthentication_invalid,
              :mfa_enrollment_reauthentication_unavailable,
              :mfa_enrollment_proof_stale
            ],
       do: "reauthentication_invalid"

  defp failure_reason(%Ecto.Changeset{}), do: "domain_validation_failed"
  defp failure_reason(reason) when reason in [nil, false, :unauthorized], do: "unauthorized"
  defp failure_reason(_reason), do: "redacted_failure"

  # This is a browser navigation target, not a server fetch, but it still comes
  # from the swappable OIDC adapter. Keep non-HTTP schemes, credentials and
  # fragments out even if a faulty adapter bypasses discovery validation.
  defp validate_authorize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, :provider_config_invalid}
    end
  end

  defp validate_authorize_url(_url), do: {:error, :provider_config_invalid}

  defp identity_link_error_message({:error, reason}), do: identity_link_error_message(reason)

  defp identity_link_error_message(:identity_already_linked),
    do: "That provider identity is already linked to another profile. Nothing changed."

  defp identity_link_error_message(:different_identity_already_linked),
    do: "Your profile already has a different identity for this provider. Remove it first."

  defp identity_link_error_message(:identity_namespace_changed),
    do: "The provider settings changed during verification. Start again."

  defp identity_link_error_message(_reason),
    do: "Provider sign-in could not be verified. Start again."

  # A :manual-provisioner first login is parked as a link request — send them to
  # the live pending-approval page instead of bouncing to /sign_in with an error.
  # The request id rides the signed session cookie, so only this browser (the
  # person who just authenticated) sees this request.
  defp redirect_to_pending(conn, request) do
    conn
    |> delete_session(@sign_in_stash_key)
    |> put_session(:sso_pending_request, request.id)
    |> redirect(to: ~p"/sign_in/sso/pending")
  end

  defp callback_error_message(:member_email_taken) do
    "Another member of this workspace already uses your email address, so single sign-on could not add you. Try again, or ask your team admin."
  end

  defp callback_error_message(:identity_pending_approval) do
    "Your access request was sent to your team admin. You'll be able to sign in once it's approved."
  end

  defp callback_error_message(:email_domain_not_allowed) do
    "Your email domain isn't permitted for this single sign-on connection. Contact your team admin."
  end

  defp callback_error_message(:membership_unavailable) do
    "This single sign-on identity no longer has workspace access. If you were invited back, accept the emailed invitation first. Otherwise, ask your team admin."
  end

  defp callback_error_message(_other),
    do: "Single sign-on failed. Try again, or contact your team admin."

  defp sso_error(conn, message) do
    conn
    |> delete_session(@sign_in_stash_key)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign_in")
  end

  defp redirect_to_disabled_account(conn, account) do
    conn
    |> delete_session(:user_return_to)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end
end
