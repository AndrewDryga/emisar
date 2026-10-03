defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  The emailed-code sign-in flows. Each start sends one split code — the browser
  keeps a nonce in a signed, 15-minute cookie and the inbox gets the code — and
  the flow finishes only in this browser:

    * `magic_link_start` — a workspace's email sign-in (`/app/:slug/sign_in`)
    * `invitation_start` — an invitation's name form
    * `sign_up_start` — a new workspace
    * `magic_link_resend` — a fresh code for the one this browser holds

  Completion runs through the typed code (`magic_link_complete`, after
  `MagicLinkLive` verified it) or the emailed link (`magic_link_confirm`), and
  for a Member with an authenticator through the second factor
  (`mfa_complete`). `delete` signs this browser out of every workspace.

  Every start shares one budget per address — five codes per 15 minutes,
  whatever the flow or workspace — and lands on the same "check your email"
  page: a refused or unknown address gets a same-shaped decoy, so the response
  never says whether the address can sign in.
  """

  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, Config, Throttle}
  alias EmisarWeb.{Analytics, BillingIntent, MagicLinkHandoff, MfaChallengeHandoff}
  alias EmisarWeb.{RequestContext, UserAuth}

  # The split code keeps its browser-side nonce in this signed, 15-minute,
  # http-only cookie (`token_id:nonce`); the email carries the 6-character code.
  # Verifying needs BOTH — an intercepted link or code can't sign in without
  # this cookie. SameSite=Lax so the cookie still rides the top-level GET when
  # the operator clicks the email link.
  @magic_cookie "emisar_magic"
  @magic_cookie_opts [sign: true, max_age: 900, http_only: true, same_site: "Lax"]

  # One budget per address across sign-in, invitation, sign-up and resend, in
  # every workspace, so neither several flows nor several workspaces multiply
  # the mail an address receives.
  @address_limit 5
  @address_window_ms 15 * 60_000
  @address_rate_limited "You've asked for several sign-in emails for that address."
  # Sign-up's hourly cap per source address.
  @sign_up_limit 20
  @sign_up_window_ms 60 * 60_000
  # The longest valid address. A longer input never resolves a Member, and the
  # stored value must not overflow the ~4 KiB session cookie.
  @max_address_bytes 320

  # Per-IP cap on every start, completion and confirmation, layered over the
  # address budget and the per-code 5-attempt cap. By IP (never email — an email
  # key would let an attacker lock a victim out); generous enough for a NAT'd
  # team behind one egress IP.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "sign_in", limit: 30, window_ms: 60_000]
       when action in [
              :magic_link_start,
              :invitation_start,
              :sign_up_start,
              :magic_link_resend,
              :magic_link_complete,
              :magic_link_confirm,
              :mfa_complete
            ]

  @doc """
  A workspace's email sign-in. The workspace comes from the path; the code goes
  only to an active Member of it whose address is verified, and only while the
  workspace accepts email sign-in. Anything else gets the decoy.
  """
  def magic_link_start(conn, %{"account_id_or_slug" => account_ref} = params) do
    account =
      case Accounts.fetch_account_by_id_or_slug_including_disabled(account_ref) do
        {:ok, account} -> account
        {:error, :not_found} -> raise EmisarWeb.NotFoundError
      end

    address = submitted_address(params["user"])
    back_to = ~p"/app/#{account}/sign_in"

    case check_address_budget(address) do
      :ok ->
        request = Auth.request_magic_link(account, address, RequestContext.from_conn(conn))

        conn
        |> clear_magic_request()
        |> replace_billing_intent(verified_billing_intent(params["billing_intent"]))
        |> put_code_request(request)
        |> finish_code_request(address, back_to)

      {:error, :rate_limited} ->
        conn
        |> keep_or_decoy_code_request(address, back_to)
        |> put_flash(:error, @address_rate_limited <> " Wait a few minutes, then resend.")
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  @doc """
  An invitation's name form. The code goes to the invited address only — never
  one the form names — and nothing is accepted until that inbox's code
  completes in this browser, so a forwarded invitation link changes nothing.
  """
  def invitation_start(conn, %{"token" => token} = params) do
    with {:ok, address, invitation} <-
           Accounts.prepare_invitation_acceptance(token, member_params(params)),
         :ok <- check_address_budget(address),
         {:ok, request} <-
           Auth.request_invitation_code(invitation, RequestContext.from_conn(conn)) do
      conn
      |> clear_magic_request()
      |> replace_billing_intent(nil)
      |> put_code_request({:ok, request})
      |> finish_code_request(address, ~p"/accept_invitation/#{token}")
    else
      {:error, :rate_limited} ->
        # No code exists to resend yet; the invitation page asks again once the
        # address budget allows it.
        conn
        |> put_flash(:error, @address_rate_limited <> " Wait a few minutes, then try again.")
        |> redirect(to: ~p"/accept_invitation/#{token}")

      _invalid_or_no_longer_pending ->
        redirect(conn, to: ~p"/accept_invitation/#{token}")
    end
  end

  @doc """
  A new workspace. The submission is validated and its intent — the workspace
  and owner names — rides the code server-side; nothing exists until the code
  comes back (`Emisar.Auth.complete_sign_up/3`).
  """
  def sign_up_start(conn, params) do
    attrs = sign_up_params(params)
    address = submitted_address(attrs)
    billing_intent = verified_billing_intent(params["billing_intent"])
    client_ip = RequestContext.client_ip(conn)

    with {:ip, :ok} <-
           {:ip, Throttle.check("sign_up", client_ip, @sign_up_limit, @sign_up_window_ms)},
         {:address, :ok} <- {:address, check_address_budget(address)},
         {:ok, request} <- Auth.request_sign_up_code(attrs, RequestContext.from_conn(conn)) do
      conn
      |> clear_magic_request()
      |> replace_billing_intent(billing_intent)
      |> put_code_request({:ok, request})
      |> finish_code_request(address, sign_up_path(billing_intent))
    else
      {:ip, {:error, :rate_limited}} ->
        sign_up_refused(
          conn,
          billing_intent,
          "Too many signup attempts. Wait a while, then try again."
        )

      {:address, {:error, :rate_limited}} ->
        sign_up_refused(
          conn,
          billing_intent,
          @address_rate_limited <> " Wait a few minutes, then try signup again."
        )

      {:error, _invalid} ->
        sign_up_refused(conn, billing_intent, "Check your details and try again.")
    end
  end

  defp sign_up_refused(conn, billing_intent, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: sign_up_path(billing_intent))
  end

  @doc """
  A fresh code for the one this browser holds, re-issued exactly as the first —
  same Member, address or sign-up intent — under the same address budget. A
  decoy or lapsed code gets a decoy again, behind the same page.
  """
  def magic_link_resend(conn, _params) do
    address = get_session(conn, :magic_link_email)
    token_id = get_session(conn, :magic_link_token_id)

    cond do
      not (is_binary(address) and is_binary(token_id)) ->
        redirect(conn, to: ~p"/sign_in")

      check_address_budget(address) == :ok ->
        conn
        |> put_code_request(Auth.resend_email_code(token_id, RequestContext.from_conn(conn)))
        |> put_session(:magic_link_expires_at, magic_link_expiry())
        |> redirect(to: ~p"/sign_in/magic?sent=1")

      true ->
        conn
        |> put_flash(:error, @address_rate_limited <> " Wait a few minutes, then resend.")
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  @doc """
  Code path — completes the sign-in after `MagicLinkLive` verified the typed
  code. The LiveView redirects here with a short-lived signed handoff naming the
  Member (nil for a sign-up) and the verified code; it is bound to the
  still-present magic cookie naming the same code, so a leaked handoff URL is
  useless elsewhere and a replay fails once the cookie is cleared.
  """
  def magic_link_complete(conn, %{"handoff" => handoff}) do
    with {:ok, {membership_id, token_id}} <- MagicLinkHandoff.verify(handoff),
         {:ok, cookie_token_id, _nonce} <- read_magic_cookie(conn),
         true <- Plug.Crypto.secure_compare(cookie_token_id, token_id) do
      complete_code(conn, membership_id, token_id)
    else
      _ -> conn |> delete_resp_cookie(@magic_cookie) |> restart_magic_sign_in()
    end
  end

  def magic_link_complete(conn, _params), do: redirect(conn, to: ~p"/sign_in/magic")

  @doc "Link path — the email link carries the token id and the code; the nonce is the cookie's."
  def magic_link_confirm(conn, %{"token_id" => token_id, "secret" => secret})
      when is_binary(token_id) and is_binary(secret) do
    # The emailed link already carries the canonical uppercase code, so upcasing
    # is a no-op; trim guards a stray copy-paste space.
    secret = secret |> String.trim() |> String.upcase()
    context = RequestContext.from_conn(conn)

    with {:ok, cookie_token_id, nonce} <- read_magic_cookie(conn),
         true <- Plug.Crypto.secure_compare(cookie_token_id, token_id),
         {:ok, membership_id} <- Auth.verify_magic_link(token_id, secret, nonce, context) do
      complete_code(conn, membership_id, token_id)
    else
      _ ->
        conn
        |> delete_resp_cookie(@magic_cookie)
        |> put_flash(
          :error,
          "This sign-in link has expired or can't be used in this browser. Request a new sign-in email."
        )
        |> redirect(to: ~p"/sign_in/magic?sent=1")
    end
  end

  @doc """
  Completes an MFA sign-in challenge (the second factor `MfaChallengeLive` just
  verified). Requires BOTH the signed handoff — carrying the opaque proof, which
  `Auth` re-checks against the locked Member row — AND a matching, fresh
  `:mfa_pending_membership_id` marker (the browser that passed factor one), so
  a handoff alone can't manufacture a session.
  """
  def mfa_complete(conn, %{"handoff" => handoff}) do
    with {:ok, proof} <- MfaChallengeHandoff.verify(handoff),
         membership_id when is_binary(membership_id) <- Auth.mfa_proof_membership_id(proof),
         ^membership_id <- get_session(conn, :mfa_pending_membership_id),
         token_id when is_binary(token_id) <- get_session(conn, :mfa_pending_magic_link_token_id),
         true <- mfa_pending_fresh?(conn) do
      {conn, browser_id} = UserAuth.fetch_browser_id(conn)
      context = RequestContext.from_conn(conn)

      case Auth.complete_magic_link_mfa_sign_in(proof, token_id, browser_id, context) do
        {:ok, :sso_required, %{account: account, proof: invitation_proof}} ->
          conn |> clear_mfa_pending() |> continue_invitation_with_sso(account, invitation_proof)

        {:ok, %Accounts.Membership{} = membership, token} ->
          conn
          |> clear_mfa_pending()
          |> UserAuth.log_in_magic_link_mfa_member(membership, token, false)

        {:error, reason} ->
          conn |> clear_mfa_pending() |> code_sign_in_failed(reason, &restart_mfa_sign_in/1)
      end
    else
      _ -> conn |> clear_mfa_pending() |> restart_mfa_sign_in()
    end
  end

  def mfa_complete(conn, _params), do: redirect(conn, to: ~p"/sign_in")

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  # Factor one is verified; `Auth` decides everything else from the current
  # rows under their locks — whether a second factor is still owed, whether the
  # workspace still accepts the code, and whether a session may be minted at
  # all — and hands back the Member it signed in. A sign-up code (no Member
  # yet) creates the workspace and its owner in the same transaction.
  defp complete_code(conn, nil, token_id) do
    {conn, browser_id} = UserAuth.fetch_browser_id(conn)

    case Auth.complete_sign_up(token_id, browser_id, RequestContext.from_conn(conn)) do
      {:ok, owner, token} ->
        conn
        |> clear_magic_request()
        |> Analytics.track_sign_up_started(true)
        |> UserAuth.log_in_magic_link_member(owner, token, true)

      {:error, _reason} ->
        restart_magic_sign_in(conn)
    end
  end

  defp complete_code(conn, membership_id, token_id) do
    {conn, browser_id} = UserAuth.fetch_browser_id(conn)
    context = RequestContext.from_conn(conn)

    case Auth.complete_magic_link_sign_in(membership_id, token_id, browser_id, context) do
      {:ok, :sso_required, %{account: account, proof: invitation_proof}} ->
        conn |> clear_magic_request() |> continue_invitation_with_sso(account, invitation_proof)

      {:ok, %Accounts.Membership{} = membership, token} ->
        conn
        |> clear_magic_request()
        |> UserAuth.log_in_magic_link_member(membership, token, false)

      # The verified id only names the partial-auth marker, which grants no
      # access: it mints no session, so every workspace route stays closed.
      {:error, :mfa_required} ->
        conn
        |> clear_magic_request()
        |> put_session(:mfa_pending_membership_id, membership_id)
        |> put_session(:mfa_pending_magic_link_token_id, token_id)
        |> put_session(:mfa_pending_at, System.system_time(:second))
        |> redirect(to: ~p"/sign_in/mfa")

      {:error, reason} ->
        code_sign_in_failed(conn, reason, &restart_magic_sign_in/1)
    end
  end

  defp code_sign_in_failed(conn, {:account_disabled, account}, _restart) do
    conn
    |> clear_magic_request()
    |> delete_session(:user_return_to)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end

  # The invitation stopped being acceptable between the email and its code:
  # accepted, revoked, resent or expired. Nothing was signed in.
  defp code_sign_in_failed(conn, :invitation_invalid, _restart) do
    conn
    |> clear_magic_request()
    |> put_flash(
      :error,
      "This invitation can no longer be accepted. Sign in if you already joined, or ask for a fresh invitation."
    )
    |> redirect(to: ~p"/sign_in")
  end

  # The workspace turned on Require SSO after the code was sent.
  defp code_sign_in_failed(conn, :sso_required, _restart) do
    back_to = get_session(conn, :magic_link_back_to) || ~p"/sign_in"

    conn
    |> clear_magic_request()
    |> put_flash(:error, "This workspace now signs in through single sign-on only.")
    |> redirect(to: back_to)
  end

  defp code_sign_in_failed(conn, _reason, restart), do: restart.(conn)

  # The workspace accepts its Members only through its identity provider. The
  # invited inbox is proved, and the proof — bound to this browser — waits in
  # the encrypted session (never a URL) for the SSO step that accepts the
  # invitation, which the workspace's sign-in page offers.
  defp continue_invitation_with_sso(conn, account, invitation_proof) do
    conn
    |> put_session(:invitation_sso_proof, invitation_proof)
    |> redirect(to: ~p"/app/#{account}/sign_in")
  end

  defp restart_magic_sign_in(conn) do
    conn
    |> put_flash(:error, "That sign-in couldn't be completed. Enter the code again or resend.")
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  defp restart_mfa_sign_in(conn) do
    conn
    |> put_flash(:error, "That sign-in couldn't be completed. Start again.")
    |> redirect(to: ~p"/sign_in")
  end

  # -- The code request in this browser --------------------------------

  defp submitted_address(%{"email" => email}) when is_binary(email), do: String.trim(email)
  defp submitted_address(_params), do: ""

  defp member_params(%{"member" => %{} = member}), do: member
  defp member_params(_params), do: %{}

  defp sign_up_params(%{"sign_up" => %{} = attrs}), do: attrs
  defp sign_up_params(_params), do: %{}

  # An ETS bucket key, not a database lookup (citext owns that comparison), so
  # the address is normalized here.
  defp check_address_budget(address),
    do: Throttle.check("magic_link", String.downcase(address), @address_limit, @address_window_ms)

  defp put_code_request(conn, {:ok, %{token_id: token_id, nonce: nonce}}),
    do: put_magic_request(conn, token_id, nonce)

  defp put_code_request(conn, {:error, _refused}), do: put_decoy_magic_request(conn)

  # A rate-limited start must not replace a still-live code with a decoy; with
  # none, the browser gets the decoy every refused request gets.
  defp keep_or_decoy_code_request(conn, address, back_to) do
    if magic_request_present?(conn) do
      conn
    else
      conn
      |> clear_magic_request()
      |> put_decoy_magic_request()
      |> put_sent_state(address, back_to)
    end
  end

  # The browser id is minted when a sign-in starts, so two tabs completing at
  # once present the same id and a later sign-out reaches both sessions.
  defp finish_code_request(conn, address, back_to) do
    {conn, _browser_id} = UserAuth.fetch_browser_id(conn)

    conn
    |> put_sent_state(address, back_to)
    |> redirect(to: ~p"/sign_in/magic?sent=1")
  end

  # The sent page shows the address, counts the code down, offers Resend
  # without a retype, and links back to where the request began (a path this
  # server built). The address and the window are the same for any address
  # alike, so neither says whether it can sign in.
  defp put_sent_state(conn, address, back_to) do
    stored_address = if byte_size(address) <= @max_address_bytes, do: address, else: ""

    conn
    |> put_session(:magic_link_email, stored_address)
    |> put_session(:magic_link_expires_at, magic_link_expiry())
    |> put_session(:magic_link_back_to, back_to)
  end

  defp magic_link_expiry do
    DateTime.utc_now()
    |> DateTime.add(Auth.magic_link_validity_in_minutes() * 60, :second)
    |> DateTime.to_iso8601()
  end

  defp magic_request_present?(conn) do
    is_binary(get_session(conn, :magic_link_token_id)) and
      is_binary(get_session(conn, :magic_link_nonce))
  end

  # The LiveView verifies the typed code (the nonce isn't readable from JS), so
  # it reads the token id and nonce from the encrypted session; the cookie stays
  # for the email-link path and binds completion to this browser.
  defp put_magic_request(conn, token_id, nonce) do
    conn
    |> put_resp_cookie(@magic_cookie, "#{token_id}:#{nonce}", magic_cookie_opts())
    |> put_session(:magic_link_token_id, token_id)
    |> put_session(:magic_link_nonce, nonce)
  end

  # A refused request carries indistinguishable browser state, but the random
  # id resolves to no database row and therefore grants nothing.
  defp put_decoy_magic_request(conn) do
    %{token_id: token_id, nonce: nonce} = Auth.magic_link_decoy()
    put_magic_request(conn, token_id, nonce)
  end

  defp magic_cookie_opts do
    Keyword.put(
      @magic_cookie_opts,
      :secure,
      Config.get_env(:emisar_web, :force_secure_cookies, false)
    )
  end

  defp read_magic_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@magic_cookie])

    with value when is_binary(value) <- conn.cookies[@magic_cookie],
         [token_id, nonce] when token_id != "" and nonce != "" <-
           String.split(value, ":", parts: 2) do
      {:ok, token_id, nonce}
    else
      _ -> :error
    end
  end

  defp clear_magic_request(conn) do
    conn
    |> delete_resp_cookie(@magic_cookie)
    |> delete_session(:magic_link_token_id)
    |> delete_session(:magic_link_nonce)
    |> delete_session(:magic_link_email)
    |> delete_session(:magic_link_expires_at)
    |> delete_session(:magic_link_back_to)
  end

  # A fresh submission must present the signed plan choice again; this keeps an
  # abandoned Team click from leaking into a later ordinary sign-in.
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

  # -- The second-factor marker -----------------------------------------

  defp clear_mfa_pending(conn) do
    conn
    |> delete_session(:mfa_pending_membership_id)
    |> delete_session(:mfa_pending_magic_link_token_id)
    |> delete_session(:mfa_pending_at)
  end

  # Factor one remains as the exact server-side factor the final session mint
  # consumes, while this marker is the browser's right to add factor two.
  # Without a deadline, someone who walked away from a shared machine
  # mid-challenge would leave a standing half-authentication for the life of
  # the browser session. Ten minutes matches the verified code's own window.
  @mfa_pending_ttl_seconds 600

  defp mfa_pending_fresh?(conn) do
    case get_session(conn, :mfa_pending_at) do
      started when is_integer(started) ->
        System.system_time(:second) - started <= @mfa_pending_ttl_seconds

      _ ->
        false
    end
  end
end
