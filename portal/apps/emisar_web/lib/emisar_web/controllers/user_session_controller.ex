defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller — accepts email+password (and optional MFA) and
  calls `UserAuth.log_in_user/3`. Magic-link consumption lives here
  too, since the LiveView for entering an email finishes by redirecting
  to this controller.
  """

  use EmisarWeb, :controller

  alias Emisar.{Accounts, Auth, Mailers, Users}
  alias EmisarWeb.{RecentAccounts, RequestContext, ReturnTo, Throttle, UserAuth}

  # The split-code magic link keeps its browser-side nonce in this signed,
  # 15-minute, http-only cookie (`token_id:nonce`); the email carries the
  # 6-digit secret. Verifying needs BOTH — an intercepted link/code can't sign
  # in without this cookie. SameSite=Lax so the cookie still rides the top-level
  # GET when the operator clicks the email link.
  @magic_cookie "emisar_magic"
  @magic_cookie_opts [sign: true, max_age: 900, http_only: true, same_site: "Lax"]

  # Brute-force / credential-stuffing throttle. `create` is the password
  # verify AND the MFA-code step (the pending-MFA POST lands here too), so
  # one per-IP cap covers both. By IP, never by email — an email key would
  # let an attacker lock a victim out of their own sign-in. Generous enough
  # that a NAT'd team behind one egress IP isn't blocked; tight enough that
  # 30/min/IP is far too slow to brute-force a password.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "sign_in", limit: 30, window_ms: 60_000] when action == :create

  # How long a successful password verify lets the operator finish MFA
  # without re-entering their password. Short enough that a stolen
  # device can't replay an old pending-MFA cookie hours later; long
  # enough that a typical operator can pull out their phone, open the
  # app, and type the code.
  @pending_mfa_ttl_seconds 5 * 60

  def create(conn, %{"user" => user_params}) do
    conn = put_return_to(conn, user_params)
    pending = get_pending_mfa(conn)

    cond do
      # Step-up path: the operator already passed the password challenge
      # on a prior `/sign_in` POST; the session carries a short-lived
      # `pending_mfa_user_id` and we only need a second factor to
      # complete sign-in. No password re-entry.
      pending && (user_params["otp"] || user_params["recovery_code"]) ->
        do_finish_mfa(conn, pending, user_params)

      # Standard path: email + password (+ optional otp) in the form.
      is_binary(user_params["email"]) and is_binary(user_params["password"]) ->
        do_start_sign_in(conn, user_params["email"], user_params["password"], user_params)

      # Fallback: an OTP-only post with no pending marker (session
      # expired, browser kept an old MFA tab around). Bounce back to
      # the password step instead of crashing on a missing email key.
      true ->
        conn
        |> clear_pending_mfa()
        |> put_flash(:error, "Your sign-in attempt expired. Enter your password again.")
        |> redirect(to: ~p"/sign_in")
    end
  end

  # A sign-in begun on a team's branded page (/app/:slug/sign_in) carries a
  # return_to so userpass + the MFA step (and the magic link, whose email URL
  # threads it through) land on THAT team, not the user's stale default.
  # `ReturnTo` whitelists it to a local /app/<slug> path — never an open redirect;
  # the slug gate still re-authorizes membership on arrival, so a forged ref 404s.
  defp put_return_to(conn, %{"return_to" => rt}) do
    case ReturnTo.app_path(rt) do
      nil -> conn
      path -> put_session(conn, :user_return_to, path)
    end
  end

  defp put_return_to(conn, _params), do: conn

  defp do_start_sign_in(conn, email, password, user_params) do
    context = RequestContext.from_conn(conn)

    case Auth.fetch_user_by_email_and_password(email, password) do
      {:ok, user} ->
        otp = user_params["otp"]
        recovery = user_params["recovery_code"]

        cond do
          Auth.mfa_required?(user) and is_nil(otp) and is_nil(recovery) ->
            # Password is verified — stash a short-lived pending-MFA
            # marker in the session so the MFA challenge step asks only
            # for the code, never the password again.
            conn
            |> put_pending_mfa(user)
            |> put_flash(:info, "Enter the 6-digit code from your authenticator app.")
            |> redirect(to: ~p"/sign_in/mfa")

          Auth.mfa_required?(user) ->
            case verify_second_factor(user, otp, recovery, context) do
              :ok ->
                finalize_sign_in(conn, user, user_params, "password+mfa", context)

              {:error, :replay} ->
                conn
                |> put_pending_mfa(user)
                |> put_flash(:error, "That code was already used. Wait for the next one.")
                |> redirect(to: ~p"/sign_in/mfa")

              {:error, _} ->
                conn
                |> put_pending_mfa(user)
                |> put_flash(:error, "That code didn't match. Try again.")
                |> redirect(to: ~p"/sign_in/mfa")
            end

          true ->
            finalize_sign_in(conn, user, user_params, "password", context)
        end

      {:error, :not_found} ->
        Auth.record_failed_sign_in(email, "bad_credentials", context)

        conn
        |> put_flash(:error, "That email and password don't match anything.")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/sign_in")
    end
  end

  defp do_finish_mfa(conn, user_id, user_params) do
    context = RequestContext.from_conn(conn)

    case Users.fetch_user_by_id(user_id) do
      {:ok, user} ->
        case verify_second_factor(user, user_params["otp"], user_params["recovery_code"], context) do
          :ok ->
            conn
            |> clear_pending_mfa()
            |> finalize_sign_in(user, user_params, "password+mfa", context)

          {:error, :replay} ->
            conn
            |> put_flash(:error, "That code was already used. Wait for the next one.")
            |> redirect(to: ~p"/sign_in/mfa")

          {:error, _} ->
            conn
            |> put_flash(:error, "That code didn't match. Try again.")
            |> redirect(to: ~p"/sign_in/mfa")
        end

      {:error, :not_found} ->
        # The user record vanished between password-verify and the MFA
        # step (suspended, deleted, etc) — bounce back to the start.
        conn
        |> clear_pending_mfa()
        |> put_flash(:error, "Your sign-in attempt expired. Try again.")
        |> redirect(to: ~p"/sign_in")
    end
  end

  defp finalize_sign_in(conn, user, user_params, method, context) do
    Users.record_sign_in(user, method, context)
    # `:password` is the method; `mfa` is whether the TOTP step ran this session.
    complete_branded_sign_in(
      conn,
      user,
      &UserAuth.log_in_user(&1, user, :password, method == "password+mfa", user_params)
    )
  end

  # A sign-in begun on a team's branded page carries a `/app/<slug>` return_to.
  # Resolve the operator's membership of THAT team and either remember it for the
  # next sign-in's one-click return, or — if they aren't a member — drop the
  # branded target so they don't land on a bare 404 after a successful sign-in.
  #
  # The membership read returns `:not_found` for a non-member AND an unknown team
  # alike (the deliberate no-leak property), so the denial flash never names the
  # team — naming it would confirm a tenant exists on the slug-probing path.
  @branded_denied_message "Signed you in. You don't have access to that team's workspace yet — ask an admin for an invite."

  defp complete_branded_sign_in(conn, user, log_in) do
    case branded_return_membership(conn, user) do
      {:member, account} ->
        # Cookie write is a resp_cookie — separate from the session, so
        # `log_in_user`'s session renewal keeps it (same as the SSO callback).
        conn
        |> RecentAccounts.put(%{slug: account.slug, name: account.name})
        |> log_in.()

      :not_member ->
        # The flash is set AFTER `log_in_user` — its `renew_session` clears the
        # session (flash included); the flash plug's before_send re-persists this.
        conn
        |> delete_session(:user_return_to)
        |> log_in.()
        |> put_flash(:info, @branded_denied_message)

      :no_branded_target ->
        log_in.(conn)
    end
  end

  defp branded_return_membership(conn, %Users.User{} = user) do
    case get_session(conn, :user_return_to) do
      "/app/" <> ref ->
        case Accounts.fetch_membership_by_account_id_or_slug(user, ref) do
          {:ok, membership} -> {:member, membership.account}
          {:error, :not_found} -> :not_member
        end

      _ ->
        :no_branded_target
    end
  end

  # -- Pending-MFA session helpers --------------------------------------

  defp put_pending_mfa(conn, user) do
    expires_at = System.system_time(:second) + @pending_mfa_ttl_seconds

    conn
    |> put_session(:pending_mfa_user_id, user.id)
    |> put_session(:pending_mfa_expires_at, expires_at)
  end

  defp clear_pending_mfa(conn) do
    conn
    |> delete_session(:pending_mfa_user_id)
    |> delete_session(:pending_mfa_expires_at)
  end

  @doc """
  Returns the user_id stashed during the password step, IFF the pending
  marker is still within its TTL. Stale markers are silently cleared
  so a stranded session can't drift into "no password needed" territory.

  Public so `EmisarWeb.MfaChallengeLive` can read it from the session
  on mount to decide whether to render the OTP form or bounce the
  visitor back to `/sign_in`.
  """
  def get_pending_mfa(conn_or_session) do
    user_id = get_pending_field(conn_or_session, :pending_mfa_user_id)
    expires_at = get_pending_field(conn_or_session, :pending_mfa_expires_at)

    cond do
      is_nil(user_id) -> nil
      is_nil(expires_at) -> nil
      expires_at <= System.system_time(:second) -> nil
      true -> user_id
    end
  end

  defp get_pending_field(%Plug.Conn{} = conn, key), do: get_session(conn, key)
  defp get_pending_field(%{} = session, key), do: Map.get(session, Atom.to_string(key))

  # MFA can be satisfied by either a fresh TOTP code (replay-checked
  # against `mfa_last_used_at`) or a one-shot recovery code. The TOTP
  # path always wins when provided; the recovery code is the
  # phone-lost fallback.
  defp verify_second_factor(user, otp, _recovery, context) when is_binary(otp) and otp != "",
    do: Auth.verify_mfa(user, otp, context)

  defp verify_second_factor(user, _, recovery, context)
       when is_binary(recovery) and recovery != "",
       do: Auth.consume_mfa_recovery_code(user, recovery, context)

  defp verify_second_factor(_, _, _, _), do: {:error, :invalid}

  @doc """
  Magic-link request (POST from the email form). Issues a split-code token,
  emails the link + 6-digit code, and stashes the browser nonce in the signed
  cookie. Always lands on the "check your email" page — a throttled or unknown
  email skips the work but shows the same page (no account-existence leak).
  """
  def magic_link_start(conn, %{"user" => %{"email" => email}} = params) do
    context = RequestContext.from_conn(conn)
    return_to = ReturnTo.app_path(params["return_to"])
    # Throttle by recipient so the form can't bomb an inbox — an ETS-bucket key,
    # not a DB lookup (citext owns DB comparison), so the no-app-downcase rule
    # doesn't apply. No `else`: throttled OR unknown both fall through to the
    # same "sent" page, leaking neither account existence nor the throttle.
    key = email |> to_string() |> String.trim() |> String.downcase()

    conn =
      with :ok <- Throttle.check("magic_link", key, 5, 900_000),
           {:ok, user} <- Users.fetch_user_by_email(email) do
        {token_id, nonce, secret} = Auth.issue_magic_link(user, context)
        Mailers.UserNotifier.deliver_magic_link(user, token_id, secret, return_to)
        put_magic_cookie(conn, token_id, nonce)
      else
        _ -> conn
      end

    conn
    |> put_magic_return_to(return_to)
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  @doc "Code path — the operator types the 6-digit code into the browser holding the nonce."
  def magic_link_verify_code(conn, %{"code" => code}) when is_binary(code),
    do: finish_magic_link(conn, code, & &1)

  def magic_link_verify_code(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic")

  @doc "Link path — the email link carries `token_id` + the secret; the nonce is the cookie's."
  def magic_link_confirm(conn, %{"token_id" => token_id, "secret" => secret} = params),
    do: finish_magic_link(conn, secret, &put_return_to(&1, params), token_id)

  # Shared finish: read the cookie nonce, verify BOTH halves, sign in. `token_id`
  # comes from the link URL (link path) or the cookie (code path); `prep` threads
  # the link path's URL return_to before logging in (the code path's was stashed
  # in the session at `magic_link_start`).
  defp finish_magic_link(conn, secret, prep, link_token_id \\ nil) do
    context = RequestContext.from_conn(conn)

    with {:ok, cookie_token_id, nonce} <- read_magic_cookie(conn),
         token_id = link_token_id || cookie_token_id,
         {:ok, user} <- Auth.verify_magic_link(token_id, secret, nonce, context) do
      Users.record_sign_in(user, "magic_link", context)

      conn
      |> delete_resp_cookie(@magic_cookie)
      |> prep.()
      |> complete_branded_sign_in(user, &UserAuth.log_in_user(&1, user, :magic_link, false, %{}))
    else
      _ ->
        conn
        |> delete_resp_cookie(@magic_cookie)
        |> put_flash(
          :error,
          "That sign-in code expired or didn't match this browser. Send a fresh one."
        )
        |> redirect(to: ~p"/sign_in/magic")
    end
  end

  defp put_magic_cookie(conn, token_id, nonce),
    do: put_resp_cookie(conn, @magic_cookie, "#{token_id}:#{nonce}", @magic_cookie_opts)

  defp put_magic_return_to(conn, nil), do: conn
  defp put_magic_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  defp read_magic_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@magic_cookie])

    case conn.cookies[@magic_cookie] do
      value when is_binary(value) ->
        case String.split(value, ":", parts: 2) do
          [token_id, nonce] when token_id != "" and nonce != "" -> {:ok, token_id, nonce}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end
end
