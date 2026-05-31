defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller — accepts email+password (and optional MFA) and
  calls `UserAuth.log_in_user/3`. Magic-link consumption lives here
  too, since the LiveView for entering an email finishes by redirecting
  to this controller.
  """

  use EmisarWeb, :controller

  alias Emisar.{Accounts, Auth}
  alias EmisarWeb.{RateLimiter, UserAuth}

  # 5 attempts per 60s per IP, per email — picked so a script kiddie
  # spraying one password against many emails hits the IP cap before
  # they can do real damage.
  @signin_max 5
  @signin_window_ms 60_000

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params
    ip = ip_key(conn)
    email_key = "sign_in:email:" <> normalise_email(email)
    ip_key_ = "sign_in:ip:" <> ip

    cond do
      match?({:error, _, _}, RateLimiter.check(ip_key_, @signin_max, @signin_window_ms)) ->
        audit_throttle(email, ip, "sign_in:ip")
        retry_after(conn, "Too many sign-in attempts from this network. Try again shortly.")

      match?({:error, _, _}, RateLimiter.check(email_key, @signin_max, @signin_window_ms)) ->
        audit_throttle(email, ip, "sign_in:email")
        retry_after(conn, "Too many sign-in attempts for this account. Try again shortly.")

      true ->
        do_create(conn, email, password, user_params)
    end
  end

  defp do_create(conn, email, password, user_params) do
    case Auth.fetch_user_by_email_and_password(email, password) do
      {:ok, user} ->
        cond do
          Auth.mfa_required?(user) and is_nil(user_params["otp"]) ->
            conn
            |> put_flash(:info, "Enter the 6-digit code from your authenticator app.")
            |> redirect(to: ~p"/sign_in/mfa?email=#{email}")

          Auth.mfa_required?(user) and not Auth.verify_mfa(user, user_params["otp"]) ->
            conn
            |> put_flash(:error, "That code didn't match. Try again.")
            |> redirect(to: ~p"/sign_in/mfa?email=#{email}")

          true ->
            Accounts.record_sign_in(user)
            UserAuth.log_in_user(conn, user, user_params)
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "That email and password don't match anything.")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/sign_in")
    end
  end

  def magic_link_confirm(conn, %{"token" => token}) do
    case Auth.consume_magic_link_token(token) do
      {:ok, user} ->
        Accounts.record_sign_in(user)
        UserAuth.log_in_user(conn, user, %{})

      {:error, :invalid_or_expired} ->
        conn
        |> put_flash(:error, "That magic link expired. Send a fresh one.")
        |> redirect(to: ~p"/sign_in/magic")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp ip_key(conn), do: EmisarWeb.RateLimiter.ip_key(conn)

  defp normalise_email(email) when is_binary(email), do: email |> String.downcase() |> String.trim()
  defp normalise_email(_), do: "unknown"

  defp retry_after(conn, msg) do
    conn
    |> put_status(:too_many_requests)
    |> put_flash(:error, msg)
    |> redirect(to: ~p"/sign_in")
  end

  # account_id is unknown at throttle time (caller is anonymous), so we
  # can't write to audit_events. A structured Logger line lands in the
  # JSON log shipping pipeline alongside the audit feed and is enough
  # for ops to spot scanning.
  defp audit_throttle(email, ip, kind) do
    require Logger

    Logger.warning("auth.throttled",
      kind: kind,
      email_hint: email_hint(email),
      ip: ip
    )
  end

  # Hash the email so the audit log doesn't accumulate plaintext probe
  # targets — the log is still useful to spot scanning patterns.
  defp email_hint(email) when is_binary(email) do
    :crypto.hash(:sha256, email) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  defp email_hint(_), do: nil
end
