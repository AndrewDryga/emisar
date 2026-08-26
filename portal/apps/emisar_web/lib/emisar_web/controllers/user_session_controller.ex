defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller for the passwordless sign-in flows: the split-code
  magic-link request (`magic_link_start`), the email-link verifier
  (`magic_link_confirm`), the typed-code sign-in completion (`magic_link_complete`
  — the code itself is verified in `MagicLinkLive`), and sign-out. A user with a
  second factor enrolled is diverted to the MFA challenge (`MfaChallengeLive`)
  after the magic link verifies and only reaches a full session via `mfa_complete`.
  Account-wide MFA *enrollment* is still enforced post-login by `UserAuth`'s
  `:ensure_account_compliant` gate.
  """

  use EmisarWeb, :controller
  alias Emisar.{Auth, Config, Throttle, Users}
  alias EmisarWeb.{Analytics, BillingIntent, MagicLinkHandoff, MfaChallengeHandoff}
  alias EmisarWeb.{RecentAccounts, RegistrationHandoff, RequestContext, ReturnTo, UserAuth}

  # The split-code magic link keeps its browser-side nonce in this signed,
  # 15-minute, http-only cookie (`token_id:nonce`); the email carries the
  # 6-character secret. Verifying needs BOTH — an intercepted link/code can't sign
  # in without this cookie. SameSite=Lax so the cookie still rides the top-level
  # GET when the operator clicks the email link.
  @magic_cookie "emisar_magic"
  @magic_cookie_opts [sign: true, max_age: 900, http_only: true, same_site: "Lax"]

  # Per-IP cap on the magic-link endpoints, layered over the per-recipient
  # throttle in `magic_link_start` and the per-token 5-attempt cap on verify.
  # By IP (never email — an email key would let an attacker lock a victim out);
  # generous enough for a NAT'd team behind one egress IP.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "sign_in", limit: 30, window_ms: 60_000]
       when action in [
              :magic_link_start,
              :magic_link_complete,
              :magic_link_confirm
            ]

  @doc """
  Magic-link request (POST from the email form). `Auth.request_magic_link/3`
  issues the split-code token and emails the link + 6-character code; the browser
  nonce it hands back is stashed in the signed cookie. Always lands on the "check
  your email" page — a throttled, unknown, or unavailable-team request skips the
  work but shows the same page (no account-existence leak).
  """
  def magic_link_start(conn, %{"user" => %{"email" => email}} = params) when is_binary(email) do
    context = RequestContext.from_conn(conn)
    return_to = ReturnTo.app_path(params["return_to"])
    handoff = params["registration_handoff"]
    prior_token_id = get_session(conn, :magic_link_token_id)
    billing_intent = requested_billing_intent(conn, params, prior_token_id)
    # Throttle by recipient so the form can't bomb an inbox — an ETS-bucket key,
    # not a DB lookup (citext owns DB comparison), so the no-app-downcase rule
    # doesn't apply.
    trimmed = String.trim(email)
    key = String.downcase(trimmed)

    case Throttle.check("magic_link", key, 5, 900_000) do
      :ok ->
        conn = conn |> clear_magic_request() |> replace_billing_intent(billing_intent)

        conn =
          with {:ok, user} <- Users.fetch_user_by_email(email),
               {:ok, %{token_id: token_id, nonce: nonce}} <-
                 Auth.request_magic_link(user, context,
                   account_ref: branded_account_ref(return_to),
                   return_to: return_to,
                   owner_registration: owner_registration(handoff, user),
                   prior_magic_link_token_id: prior_token_id
                 ) do
            put_magic_request(conn, token_id, nonce)
            # The LiveView verifies the typed code (the nonce isn't readable from JS),
            # so it reads token_id + nonce from the encrypted session; the cookie stays
            # for the email-link path and the sign-in-completion browser binding.
          else
            # An unknown email, or a branded request naming a team that isn't
            # available, stays silent — same "sent" page either way, so the response
            # never reveals whether the address is an account or the team exists.
            _ -> put_decoy_magic_request(conn)
          end

        finish_magic_request(conn, trimmed, return_to)

      {:error, :rate_limited} when is_binary(handoff) ->
        # A first signup request has no server-side factor from which a later
        # resend could recover its workspace intent. Keep the operator on signup
        # so they can retry the same neutral submission after the recipient cap.
        conn
        |> clear_magic_request()
        |> replace_billing_intent(verified_billing_intent(params["billing_intent"]))
        |> put_flash(
          :error,
          "You've asked for several sign-in emails for that address. Wait a few minutes, then try signup again."
        )
        |> redirect(to: sign_up_path(verified_billing_intent(params["billing_intent"])))

      {:error, :rate_limited} ->
        # A resend must not replace a still-live real factor (and its server-side
        # registration intent) with a decoy. With no prior browser state, install
        # the same-shaped decoy used for any other silent request.
        conn =
          if magic_request_present?(conn) do
            conn
          else
            conn |> clear_magic_request() |> put_decoy_magic_request()
          end

        conn
        |> put_flash(
          :error,
          "You've asked for several sign-in emails for that address. Wait a few minutes, then resend."
        )
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  def magic_link_start(conn, _params) do
    conn
    |> clear_magic_request()
    |> replace_billing_intent(nil)
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  defp magic_link_expiry do
    DateTime.utc_now()
    |> DateTime.add(Auth.magic_link_validity_in_minutes() * 60, :second)
    |> DateTime.to_iso8601()
  end

  defp finish_magic_request(conn, email, return_to) do
    conn
    # Stash the typed address + the code's expiry so the "sent" page can offer
    # Resend without a retype and count the code down to expiry. Both are uniform
    # for any address (their own input + a fixed window), so neither leaks whether
    # the address is an account.
    |> put_session(:magic_link_email, email)
    |> put_session(:magic_link_expires_at, magic_link_expiry())
    |> put_magic_return_to(return_to)
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  defp magic_request_present?(conn) do
    is_binary(get_session(conn, :magic_link_token_id)) and
      is_binary(get_session(conn, :magic_link_nonce))
  end

  @doc """
  Code path — completes sign-in after `MagicLinkLive` verified the typed code.
  The LiveView redirects here with a short-lived signed `handoff` carrying the
  user; it is bound to the still-present magic cookie (same browser), so a leaked
  handoff URL is useless elsewhere and a replay fails once the cookie is cleared.
  """
  def magic_link_complete(conn, %{"handoff" => handoff}) do
    with {:ok, {user_id, token_id}} <- MagicLinkHandoff.verify(handoff),
         {:ok, cookie_token_id, _nonce} <- read_magic_cookie(conn),
         true <- cookie_token_id == token_id do
      complete_magic_sign_in(
        conn,
        user_id,
        token_id,
        RequestContext.from_conn(conn)
      )
    else
      _ -> conn |> delete_resp_cookie(@magic_cookie) |> restart_magic_sign_in()
    end
  end

  def magic_link_complete(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic")

  @doc """
  Completes an MFA sign-in challenge (the second factor `MfaChallengeLive` just
  verified). Requires BOTH the signed handoff — carrying the opaque proof, which
  `Auth` re-checks against the locked user row — AND a matching
  `:mfa_pending_user_id` session marker (the browser that passed factor one), so
  a handoff alone can't manufacture a session. The proof's user id is only that
  browser binding; `Auth` reads the credential state itself, mints the session,
  and hands back the user it signed in. This installs it, or restarts the
  sign-in fail-closed.
  """
  def mfa_complete(conn, %{"handoff" => handoff}) do
    with {:ok, proof} <- MfaChallengeHandoff.verify(handoff),
         user_id when is_binary(user_id) <- Auth.mfa_proof_user_id(proof),
         ^user_id <- get_session(conn, :mfa_pending_user_id),
         token_id when is_binary(token_id) <- get_session(conn, :mfa_pending_magic_link_token_id),
         true <- mfa_pending_fresh?(conn) do
      context = RequestContext.from_conn(conn)
      account_ref = branded_account_ref(get_session(conn, :user_return_to))

      case Auth.complete_magic_link_mfa_sign_in(proof, token_id, account_ref, context) do
        {:ok, user, token, target, registered?} ->
          install_magic_link_session(
            conn
            |> clear_mfa_pending()
            |> Analytics.track_sign_up_started(registered?),
            target,
            user,
            token,
            registered?,
            &UserAuth.log_in_magic_link_mfa_user/4
          )

        {:error, {:account_disabled, account}} ->
          conn |> clear_mfa_pending() |> redirect_to_disabled_account(account)

        {:error, _reason} ->
          conn |> clear_mfa_pending() |> restart_mfa_sign_in()
      end
    else
      _ -> conn |> clear_mfa_pending() |> restart_mfa_sign_in()
    end
  end

  def mfa_complete(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic")

  @doc "Link path — the email link carries `token_id` + the secret; the nonce is the cookie's."
  def magic_link_confirm(conn, %{"token_id" => token_id, "secret" => secret} = params),
    do: finish_magic_link(conn, secret, &put_return_to(&1, params), token_id)

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  # The email-link path: read the cookie's nonce, verify BOTH
  # halves (the URL's secret + the cookie's nonce) against the URL's token, sign
  # in. `prep` threads the link's `?return_to` into the session before login. (The
  # typed-code path verifies in `MagicLinkLive` and completes via
  # `magic_link_complete` — it never reaches here.)
  defp finish_magic_link(conn, secret, prep, link_token_id) do
    context = RequestContext.from_conn(conn)
    # The emailed link already carries the canonical uppercase secret, so upcasing
    # is a no-op; trim guards a stray copy-paste space. The code alphabet is
    # uppercase letters + digits (Emisar.Crypto).
    secret = secret |> to_string() |> String.trim() |> String.upcase()

    with {:ok, cookie_token_id, nonce} <- read_magic_cookie(conn),
         true <- cookie_token_id == link_token_id,
         {:ok, user} <- Auth.verify_magic_link(link_token_id, secret, nonce, context) do
      conn
      |> prep.()
      |> complete_magic_sign_in(user.id, link_token_id, context)
    else
      _ ->
        conn
        |> delete_resp_cookie(@magic_cookie)
        |> put_flash(
          :error,
          "That sign-in code expired or didn't match this browser. Resend a fresh one below."
        )
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  defp put_magic_cookie(conn, token_id, nonce) do
    put_resp_cookie(
      conn,
      @magic_cookie,
      "#{token_id}:#{nonce}",
      magic_cookie_opts()
    )
  end

  defp magic_cookie_opts do
    Keyword.put(
      @magic_cookie_opts,
      :secure,
      Config.get_env(:emisar_web, :force_secure_cookies, false)
    )
  end

  defp put_magic_request(conn, token_id, nonce) do
    conn
    |> put_magic_cookie(token_id, nonce)
    |> put_session(:magic_link_token_id, token_id)
    |> put_session(:magic_link_nonce, nonce)
  end

  # An unknown/unavailable request carries indistinguishable browser state, but
  # the random id resolves to no database row and therefore grants nothing.
  defp put_decoy_magic_request(conn) do
    %{token_id: token_id, nonce: nonce} = Auth.magic_link_decoy()
    put_magic_request(conn, token_id, nonce)
  end

  defp put_magic_return_to(conn, nil), do: conn
  defp put_magic_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  # A fresh signup submission must present the signed choice again; this keeps
  # an abandoned Team click from leaking into a later ordinary sign-in. A resend
  # has no handoff field, so it may inherit the still-live choice only while the
  # same browser still carries the factor it is replacing.
  defp requested_billing_intent(conn, params, prior_token_id) do
    case verified_billing_intent(params["billing_intent"]) do
      token when is_binary(token) ->
        token

      nil ->
        if is_binary(prior_token_id) and magic_request_present?(conn),
          do: verified_billing_intent(get_session(conn, :billing_intent)),
          else: nil
    end
  end

  defp verified_billing_intent(token) do
    case BillingIntent.verify(token) do
      {:ok, _intent} -> token
      {:error, :invalid} -> nil
    end
  end

  defp replace_billing_intent(conn, token) when is_binary(token),
    do: put_session(conn, :billing_intent, token)

  defp replace_billing_intent(conn, nil), do: delete_session(conn, :billing_intent)

  defp sign_up_path(token) when is_binary(token), do: ~p"/sign_up?billing_intent=#{token}"
  defp sign_up_path(nil), do: ~p"/sign_up"

  defp read_magic_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@magic_cookie])

    case conn.cookies[@magic_cookie] do
      value when is_binary(value) ->
        case String.split(value, ":", parts: 2) do
          [token_id, nonce] when token_id != "" and nonce != "" ->
            {:ok, token_id, nonce}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # A magic link requested from a branded page (/app/:slug/sign_in) threads a
  # `?return_to=/app/<slug>` so it lands on THAT team. `ReturnTo` whitelists it to
  # a local /app/<slug> path — never an open redirect; the slug gate re-authorizes
  # membership on arrival, so a forged ref 404s.
  defp put_return_to(conn, %{"return_to" => rt}) do
    case ReturnTo.app_path(rt) do
      nil -> conn
      path -> put_session(conn, :user_return_to, path)
    end
  end

  defp put_return_to(conn, _params), do: conn

  defp owner_registration(handoff, %Users.User{id: user_id})
       when is_binary(handoff) do
    case RegistrationHandoff.verify(handoff) do
      {:ok, {^user_id, account_name, full_name}}
      when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)) ->
        %{account_name: account_name, full_name: full_name}

      _ ->
        nil
    end
  end

  defp owner_registration(_handoff, %Users.User{}), do: nil

  defp clear_magic_request(conn) do
    conn
    |> delete_resp_cookie(@magic_cookie)
    |> delete_session(:magic_link_token_id)
    |> delete_session(:magic_link_nonce)
    |> delete_session(:magic_link_email)
    |> delete_session(:magic_link_expires_at)
  end

  # A sign-in begun on a team's branded page carries a `/app/<slug>` return_to.
  # `Auth.resolve_post_auth_account/2` decides the landing account; when the
  # operator isn't a member we drop the branded target so they don't land on a
  # bare 404 after a successful sign-in.
  #
  # That decision collapses a non-member, an unknown team, and a stale membership
  # into one `:not_member` (the deliberate no-leak property), so the denial flash
  # never names the team — naming it would confirm a tenant exists on the
  # slug-probing path.
  # Factor one is verified (the magic link proved inbox possession); `Auth`
  # decides everything else from the CURRENT user row — whether a second factor
  # is still owed, which account to land on, and whether a session may be minted
  # at all — and hands back the user it signed in, which is what gets installed.
  # The verified id is only a name for the partial-auth marker, which grants no
  # access: it mints no `:user_token`, so `require_authenticated_user` blocks
  # every /app route.
  defp complete_magic_sign_in(conn, user_id, token_id, context)
       when is_binary(user_id) and is_binary(token_id) do
    account_ref = branded_account_ref(get_session(conn, :user_return_to))

    case Auth.complete_magic_link_sign_in(user_id, token_id, account_ref, context) do
      {:ok, user, token, target, registered?} ->
        install_magic_link_session(
          conn
          |> clear_magic_request()
          |> Analytics.track_sign_up_started(registered?),
          target,
          user,
          token,
          registered?,
          &UserAuth.log_in_magic_link_user/4
        )

      {:error, :mfa_required} ->
        conn
        |> clear_magic_request()
        |> put_session(:mfa_pending_user_id, user_id)
        |> put_session(:mfa_pending_magic_link_token_id, token_id)
        |> put_session(:mfa_pending_at, System.system_time(:second))
        |> redirect(to: ~p"/sign_in/mfa")

      {:error, {:account_disabled, account}} ->
        conn |> clear_magic_request() |> redirect_to_disabled_account(account)

      {:error, _reason} ->
        restart_magic_sign_in(conn)
    end
  end

  defp clear_mfa_pending(conn) do
    conn
    |> delete_session(:mfa_pending_user_id)
    |> delete_session(:mfa_pending_magic_link_token_id)
    |> delete_session(:mfa_pending_at)
  end

  # Factor one remains as the exact server-side factor the final session mint
  # consumes, while this marker is the browser's right to add factor two. Without
  # a deadline, someone who walked away from a shared machine mid-challenge would
  # leave a standing half-authentication for the life of the browser session.
  # Ten minutes matches the verified inbox factor's own completion window.
  @mfa_pending_ttl_seconds 600

  defp mfa_pending_fresh?(conn) do
    case get_session(conn, :mfa_pending_at) do
      started when is_integer(started) ->
        System.system_time(:second) - started <= @mfa_pending_ttl_seconds

      _ ->
        false
    end
  end

  # `log_in` installs the session token `Auth` already minted — the two captures
  # (`log_in_magic_link_user/4`, `log_in_magic_link_mfa_user/4`) are what fix the
  # second-factor provenance, so nothing here decides it.
  defp install_magic_link_session(conn, {:member, account}, user, token, registered?, log_in) do
    # Cookie write is a resp_cookie — separate from the session, so the session
    # renewal inside `log_in` keeps it (same as the SSO callback).
    conn
    |> RecentAccounts.put(%{slug: account.slug, name: account.name})
    |> log_in.(user, token, registered?)
  end

  defp install_magic_link_session(conn, :not_member, user, token, registered?, log_in) do
    # The flash is set AFTER `log_in` — its `renew_session` clears the session
    # (flash included); the flash plug's before_send re-persists this.
    conn =
      conn
      |> delete_session(:user_return_to)
      |> log_in.(user, token, registered?)

    denied_message =
      "Signed you in. You don't have access to that team's workspace yet — ask an admin for an invite."

    put_flash(conn, :info, denied_message)
  end

  defp install_magic_link_session(conn, :no_target, user, token, registered?, log_in),
    do: log_in.(conn, user, token, registered?)

  defp restart_magic_sign_in(conn) do
    conn
    |> put_flash(:error, "That sign-in couldn't be completed. Enter the code again or resend.")
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  defp restart_mfa_sign_in(conn) do
    conn
    |> put_flash(:error, "That sign-in couldn't be completed. Start again below.")
    |> redirect(to: ~p"/sign_in/magic")
  end

  defp branded_account_ref("/app/" <> path) do
    case String.split(path, "/", parts: 2) do
      [ref | _rest] when ref != "" -> ref
      _ -> nil
    end
  end

  defp branded_account_ref(_return_to), do: nil

  defp redirect_to_disabled_account(conn, account) do
    conn
    |> delete_session(:user_return_to)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end
end
