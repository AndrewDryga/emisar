defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller for the passwordless sign-in flows: the split-code
  magic-link request (`magic_link_start`), the email-link verifier
  (`magic_link_confirm`), the typed-code sign-in completion (`magic_link_complete`
  — the code itself is verified in `MagicLinkLive`), and sign-out. A user with a
  second factor enrolled is diverted to the MFA challenge (`MfaChallengeLive`)
  after the magic link verifies and only reaches a full session via `mfa_complete`.
  Account-wide MFA *enrollment* is still enforced post-login by `UserAuth`'s
  `:ensure_mfa_compliant` gate.
  """

  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, Mailers, Users}
  alias EmisarWeb.CoreComponents
  alias EmisarWeb.{MagicLinkHandoff, MfaChallengeHandoff}
  alias EmisarWeb.{RecentAccounts, RegistrationHandoff, RequestContext}
  alias EmisarWeb.{ReturnTo, Throttle, UserAuth}

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
              :registration_email_correction,
              :magic_link_complete,
              :magic_link_confirm
            ]

  @doc """
  Magic-link request (POST from the email form). Issues a split-code token,
  emails the link + 6-character code, and stashes the browser nonce in the signed
  cookie. Always lands on the "check your email" page — a throttled or unknown
  email skips the work but shows the same page (no account-existence leak).
  """
  def magic_link_start(conn, %{"user" => %{"email" => email}} = params) when is_binary(email) do
    context = RequestContext.from_conn(conn)
    return_to = ReturnTo.app_path(params["return_to"])
    registration_handoff = params["registration_handoff"]
    # Throttle by recipient so the form can't bomb an inbox — an ETS-bucket key,
    # not a DB lookup (citext owns DB comparison), so the no-app-downcase rule
    # doesn't apply.
    trimmed = String.trim(email)
    key = String.downcase(trimmed)

    conn =
      with :ok <- Throttle.check("magic_link", key, 5, 900_000),
           {:ok, user} <- Users.fetch_user_by_email(email),
           :active <- branded_account_status(return_to) do
        registration_user_id = registration_user_id(registration_handoff, user)
        registered? = is_binary(registration_user_id)
        {token_id, nonce, secret} = Auth.issue_magic_link(user, context)
        Mailers.UserNotifier.deliver_magic_link(user, token_id, secret, context, return_to)

        conn
        |> put_magic_cookie(token_id, nonce, registration_user_id)
        # The LiveView verifies the typed code (the nonce isn't readable from JS),
        # so it reads token_id + nonce from the encrypted session; the cookie stays
        # for the email-link path and the sign-in-completion browser binding.
        |> put_session(:magic_link_token_id, token_id)
        |> put_session(:magic_link_nonce, nonce)
        |> put_session(:magic_link_registered, registered?)
        |> put_magic_registration_user_id(registration_user_id)
      else
        # Surfacing the throttle is safe: it's checked BEFORE the user lookup and
        # fires identically for real and unknown addresses, so it can't leak
        # account existence — only that this address has asked too often.
        {:error, :rate_limited} ->
          put_flash(
            conn,
            :error,
            "You've asked for several sign-in emails for that address. Wait a few minutes, then resend."
          )

        # An unknown email stays silent — same "sent" page either way, so the
        # response never reveals whether the address is an account.
        _ ->
          conn
      end

    conn
    # Stash the typed address + the code's expiry so the "sent" page can offer
    # Resend without a retype and count the code down to expiry. Both are uniform
    # for any address (their own input + a fixed window), so neither leaks whether
    # the address is an account.
    |> put_session(:magic_link_email, trimmed)
    |> put_session(:magic_link_expires_at, magic_link_expiry())
    |> put_magic_return_to(return_to)
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  def magic_link_start(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic?sent=1")

  @doc """
  Signup recovery for a typo in the just-submitted email. Only the same browser
  that holds the pending registration magic cookie can change it.
  """
  def registration_email_correction(conn, %{"user" => %{"email" => email}})
      when is_binary(email) do
    context = RequestContext.from_conn(conn)
    trimmed = String.trim(email)
    key = String.downcase(trimmed)

    with {:ok, token_id, _nonce, registration_user_id} when is_binary(registration_user_id) <-
           read_magic_cookie(conn),
         :ok <- Throttle.check("magic_link", key, 5, 900_000),
         {:ok, user, new_token_id, nonce, secret} <-
           Auth.correct_registration_email(token_id, registration_user_id, trimmed, context) do
      _ = Mailers.UserNotifier.deliver_magic_link(user, new_token_id, secret, context)

      conn
      |> put_magic_cookie(new_token_id, nonce, user.id)
      |> put_session(:magic_link_token_id, new_token_id)
      |> put_session(:magic_link_nonce, nonce)
      |> put_session(:magic_link_registered, true)
      |> put_session(:magic_link_registration_user_id, user.id)
      |> put_session(:magic_link_email, trimmed)
      |> put_session(:magic_link_expires_at, magic_link_expiry())
      |> put_flash(:info, "We updated your signup email and sent a new code.")
      |> redirect(to: ~p"/sign_in/magic?sent=1")
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(
          :error,
          "You've asked for several sign-in emails for that address. Wait a few minutes, then resend."
        )
        |> redirect(to: ~p"/sign_in/magic?sent=1")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:magic_email_attempt, trimmed)
        |> put_flash(:magic_email_error, email_error(changeset))
        |> redirect(to: ~p"/sign_in/magic?sent=1")

      _ ->
        conn
        |> put_flash(:error, "That signup session expired. Create your account again.")
        |> redirect(to: ~p"/sign_up")
    end
  end

  def registration_email_correction(conn, _params) do
    conn
    |> put_flash(:magic_email_attempt, "")
    |> put_flash(:magic_email_error, "Check this email and try again.")
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  defp magic_link_expiry do
    DateTime.utc_now()
    |> DateTime.add(Auth.magic_link_validity_in_minutes() * 60, :second)
    |> DateTime.to_iso8601()
  end

  defp email_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&CoreComponents.translate_error/1)
    |> Map.get(:email, [])
    |> List.first()
    |> case do
      message when is_binary(message) -> message
      _ -> "Check this email and try again."
    end
  end

  @doc """
  Code path — completes sign-in after `MagicLinkLive` verified the typed code.
  The LiveView redirects here with a short-lived signed `handoff` carrying the
  user; it is bound to the still-present magic cookie (same browser), so a leaked
  handoff URL is useless elsewhere and a replay fails once the cookie is cleared.
  """
  def magic_link_complete(conn, %{"handoff" => handoff}) do
    with {:ok, {user_id, registered?, token_id}} <- MagicLinkHandoff.verify(handoff),
         {:ok, cookie_token_id, _nonce, _flag} <- read_magic_cookie(conn),
         true <- cookie_token_id == token_id,
         {:ok, user} <- Users.fetch_user_by_id(user_id) do
      complete_magic_sign_in(conn, user, registered?, RequestContext.from_conn(conn))
    else
      _ ->
        conn
        |> delete_resp_cookie(@magic_cookie)
        |> put_flash(
          :error,
          "That sign-in couldn't be completed. Enter the code again or resend."
        )
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  def magic_link_complete(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic")

  @doc """
  Completes an MFA sign-in challenge (the second factor `MfaChallengeLive` just
  verified). Requires BOTH the signed handoff (proof the LiveView ran the
  verification) AND a matching `:mfa_pending_user_id` session marker (the browser
  that passed factor one) — a handoff alone can't manufacture a session. On
  success, establishes the full session with `mfa: true`; otherwise restarts.
  """
  def mfa_complete(conn, %{"handoff" => handoff}) do
    with {:ok, user_id} <- MfaChallengeHandoff.verify(handoff),
         ^user_id <- get_session(conn, :mfa_pending_user_id),
         {:ok, user} <- Users.fetch_user_by_id(user_id) do
      registered? = get_session(conn, :mfa_pending_registered?) || false
      context = RequestContext.from_conn(conn)

      conn
      |> clear_mfa_pending()
      |> complete_branded_sign_in(user, fn conn, account ->
        log_in_magic_user(conn, user, account, true, registered?, context)
      end)
    else
      _ ->
        conn
        |> clear_mfa_pending()
        |> put_flash(:error, "That sign-in couldn't be completed. Start again below.")
        |> redirect(to: ~p"/sign_in/magic")
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

  # The email-link path: read the cookie's nonce + registered flag, verify BOTH
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

    with {:ok, cookie_token_id, nonce, registration_user_id} <- read_magic_cookie(conn),
         true <- cookie_token_id == link_token_id,
         {:ok, user} <- Auth.verify_magic_link(link_token_id, secret, nonce, context) do
      registered? = is_binary(registration_user_id)

      conn
      |> prep.()
      |> complete_magic_sign_in(user, registered?, context)
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

  defp put_magic_cookie(conn, token_id, nonce, registration_user_id) do
    registration_ref =
      if is_binary(registration_user_id),
        do: "user:#{registration_user_id}",
        else: "-"

    put_resp_cookie(
      conn,
      @magic_cookie,
      "#{token_id}:#{nonce}:#{registration_ref}",
      @magic_cookie_opts
    )
  end

  defp put_magic_return_to(conn, nil), do: conn
  defp put_magic_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  defp read_magic_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@magic_cookie])

    case conn.cookies[@magic_cookie] do
      value when is_binary(value) ->
        case String.split(value, ":", parts: 3) do
          [token_id, nonce, registration_ref] when token_id != "" and nonce != "" ->
            registration_user_id =
              case registration_ref do
                "user:" <> user_id -> user_id
                _ -> nil
              end

            {:ok, token_id, nonce, registration_user_id}

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

  defp registration_user_id(handoff, %Users.User{id: user_id, confirmed_at: nil}) do
    case RegistrationHandoff.verify(handoff) do
      {:ok, ^user_id} -> user_id
      _ -> nil
    end
  end

  defp registration_user_id(_handoff, %Users.User{}), do: nil

  defp put_magic_registration_user_id(conn, registration_user_id)
       when is_binary(registration_user_id),
       do: put_session(conn, :magic_link_registration_user_id, registration_user_id)

  defp put_magic_registration_user_id(conn, _),
    do: delete_session(conn, :magic_link_registration_user_id)

  # A sign-in begun on a team's branded page carries a `/app/<slug>` return_to.
  # Resolve the operator's membership of THAT team and either remember it for the
  # next sign-in's one-click return, or — if they aren't a member — drop the
  # branded target so they don't land on a bare 404 after a successful sign-in.
  #
  # The membership read returns `:not_found` for a non-member AND an unknown team
  # alike (the deliberate no-leak property), so the denial flash never names the
  # team — naming it would confirm a tenant exists on the slug-probing path.
  @branded_denied_message "Signed you in. You don't have access to that team's workspace yet — ask an admin for an invite."

  # After the magic link verifies factor one (email), branch on MFA enrollment:
  # a user with no second factor is signed straight in; an `mfa_enabled_at` user
  # is NOT — we stash a partial-auth marker (which grants no access: it mints no
  # `:user_token`, so `require_authenticated_user` blocks every /app route) and
  # send them to the challenge. `record_sign_in` moves to `mfa_complete` — a
  # sign-in is only complete once both factors pass.
  defp complete_magic_sign_in(conn, user, registered?, context) do
    conn = delete_resp_cookie(conn, @magic_cookie)

    if mfa_required_at_sign_in?(user) do
      conn
      |> put_session(:mfa_pending_user_id, user.id)
      |> put_session(:mfa_pending_registered?, registered?)
      |> redirect(to: ~p"/sign_in/mfa")
    else
      complete_branded_sign_in(conn, user, fn conn, account ->
        log_in_magic_user(conn, user, account, false, registered?, context)
      end)
    end
  end

  defp mfa_required_at_sign_in?(%Users.User{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_required_at_sign_in?(%Users.User{}), do: false

  defp clear_mfa_pending(conn) do
    conn
    |> delete_session(:mfa_pending_user_id)
    |> delete_session(:mfa_pending_registered?)
  end

  defp complete_branded_sign_in(conn, user, log_in) do
    case branded_return_membership(conn, user) do
      {:member, account} ->
        # Cookie write is a resp_cookie — separate from the session, so
        # `log_in_user`'s session renewal keeps it (same as the SSO callback).
        conn
        |> RecentAccounts.put(%{slug: account.slug, name: account.name})
        |> finish_sign_in(account, log_in)

      {:disabled, account} ->
        redirect_to_disabled_account(conn, account)

      :not_member ->
        # The flash is set AFTER `log_in_user` — its `renew_session` clears the
        # session (flash included); the flash plug's before_send re-persists this.
        conn =
          conn
          |> delete_session(:user_return_to)
          |> finish_sign_in(nil, log_in)

        put_flash(conn, :info, @branded_denied_message)

      :no_branded_target ->
        finish_sign_in(conn, nil, log_in)
    end
  end

  defp branded_return_membership(conn, %Users.User{} = user) do
    case branded_account_ref(get_session(conn, :user_return_to)) do
      {:ok, ref} ->
        case Accounts.fetch_membership_by_account_id_or_slug(user, ref) do
          {:ok, membership} -> {:member, membership.account}
          {:error, :not_found} -> disabled_account_or_not_member(ref)
        end

      _ ->
        :no_branded_target
    end
  end

  defp branded_account_ref("/app/" <> path) do
    case String.split(path, "/", parts: 2) do
      [ref | _rest] when ref != "" -> {:ok, ref}
      _ -> :error
    end
  end

  defp branded_account_ref(_return_to), do: :error

  defp branded_account_status(return_to) do
    with {:ok, ref} <- branded_account_ref(return_to),
         {:ok, %{disabled_at: %DateTime{}} = account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(ref) do
      {:disabled, account}
    else
      _ -> :active
    end
  end

  defp disabled_account_or_not_member(ref) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(ref) do
      {:ok, %{disabled_at: %DateTime{}} = account} -> {:disabled, account}
      _ -> :not_member
    end
  end

  defp log_in_magic_user(conn, user, nil, mfa, registered?, context) do
    Users.record_sign_in(user, "magic_link", context)

    {:ok, UserAuth.log_in_user(conn, user, :magic_link, mfa, registered?: registered?)}
  end

  defp log_in_magic_user(conn, user, account, mfa, registered?, _context) do
    UserAuth.log_in_user_for_account(conn, user, account.id, :magic_link, mfa,
      registered?: registered?
    )
  end

  defp finish_sign_in(conn, account, log_in) do
    case log_in.(conn, account) do
      {:ok, conn} -> conn
      {:error, :account_disabled} -> redirect_to_disabled_account(conn, account)
    end
  end

  defp redirect_to_disabled_account(conn, account) do
    conn
    |> delete_session(:user_return_to)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end
end
