defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller for the passwordless sign-in flows: the split-code
  magic-link request (`magic_link_start`), the email-link verifier
  (`magic_link_confirm`), the typed-code sign-in completion (`magic_link_complete`
  — the code itself is verified in `MagicLinkLive`), and sign-out. MFA is enforced
  post-login by `UserAuth`'s `:ensure_mfa_compliant` gate.
  """

  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, Mailers, Users}
  alias EmisarWeb.{MagicLinkHandoff, RecentAccounts, RequestContext, ReturnTo, Throttle, UserAuth}

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
       when action in [:magic_link_start, :magic_link_complete, :magic_link_confirm]

  @doc """
  Magic-link request (POST from the email form). Issues a split-code token,
  emails the link + 6-character code, and stashes the browser nonce in the signed
  cookie. Always lands on the "check your email" page — a throttled or unknown
  email skips the work but shows the same page (no account-existence leak).
  """
  def magic_link_start(conn, %{"user" => %{"email" => email}} = params) do
    context = RequestContext.from_conn(conn)
    return_to = ReturnTo.app_path(params["return_to"])
    # The sign-up form posts `registration=1`; carry it in the magic cookie so the
    # sign-in that completes this round-trip fires sign_up_completed (activation).
    registered? = params["registration"] == "1"
    # Throttle by recipient so the form can't bomb an inbox — an ETS-bucket key,
    # not a DB lookup (citext owns DB comparison), so the no-app-downcase rule
    # doesn't apply.
    trimmed = email |> to_string() |> String.trim()
    key = String.downcase(trimmed)

    conn =
      with :ok <- Throttle.check("magic_link", key, 5, 900_000),
           {:ok, user} <- Users.fetch_user_by_email(email) do
        {token_id, nonce, secret} = Auth.issue_magic_link(user, context)
        Mailers.UserNotifier.deliver_magic_link(user, token_id, secret, context, return_to)

        conn
        |> put_magic_cookie(token_id, nonce, registered?)
        # The LiveView verifies the typed code (the nonce isn't readable from JS),
        # so it reads token_id + nonce from the encrypted session; the cookie stays
        # for the email-link path and the sign-in-completion browser binding.
        |> put_session(:magic_link_token_id, token_id)
        |> put_session(:magic_link_nonce, nonce)
        |> put_session(:magic_link_registered, registered?)
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

  defp magic_link_expiry do
    DateTime.utc_now()
    |> DateTime.add(Auth.magic_link_validity_in_minutes() * 60, :second)
    |> DateTime.to_iso8601()
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
      Users.record_sign_in(user, "magic_link", RequestContext.from_conn(conn))

      conn
      |> delete_resp_cookie(@magic_cookie)
      |> complete_branded_sign_in(
        user,
        &UserAuth.log_in_user(&1, user, :magic_link, false, %{}, registered?: registered?)
      )
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

    with {:ok, _cookie_token_id, nonce, registered?} <- read_magic_cookie(conn),
         {:ok, user} <- Auth.verify_magic_link(link_token_id, secret, nonce, context) do
      Users.record_sign_in(user, "magic_link", context)

      conn
      |> delete_resp_cookie(@magic_cookie)
      |> prep.()
      |> complete_branded_sign_in(
        user,
        &UserAuth.log_in_user(&1, user, :magic_link, false, %{}, registered?: registered?)
      )
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

  defp put_magic_cookie(conn, token_id, nonce, registered?) do
    flag = if registered?, do: "1", else: "0"
    put_resp_cookie(conn, @magic_cookie, "#{token_id}:#{nonce}:#{flag}", @magic_cookie_opts)
  end

  defp put_magic_return_to(conn, nil), do: conn
  defp put_magic_return_to(conn, path), do: put_session(conn, :user_return_to, path)

  defp read_magic_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@magic_cookie])

    case conn.cookies[@magic_cookie] do
      value when is_binary(value) ->
        case String.split(value, ":", parts: 3) do
          [token_id, nonce, flag] when token_id != "" and nonce != "" ->
            {:ok, token_id, nonce, flag == "1"}

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
end
