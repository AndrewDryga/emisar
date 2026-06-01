defmodule EmisarWeb.UserSessionController do
  @moduledoc """
  Session controller — accepts email+password (and optional MFA) and
  calls `UserAuth.log_in_user/3`. Magic-link consumption lives here
  too, since the LiveView for entering an email finishes by redirecting
  to this controller.
  """

  use EmisarWeb, :controller

  alias Emisar.{Accounts, Audit, Auth}
  alias EmisarWeb.UserAuth

  # How long a successful password verify lets the operator finish MFA
  # without re-entering their password. Short enough that a stolen
  # device can't replay an old pending-MFA cookie hours later; long
  # enough that a typical operator can pull out their phone, open the
  # app, and type the code.
  @pending_mfa_ttl_seconds 5 * 60

  def create(conn, %{"user" => user_params}) do
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

  defp do_start_sign_in(conn, email, password, user_params) do
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
            case verify_second_factor(user, otp, recovery) do
              :ok ->
                finalize_sign_in(conn, user, user_params, "password+mfa")

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
            finalize_sign_in(conn, user, user_params, "password")
        end

      {:error, :not_found} ->
        Auth.record_failed_sign_in(email, "bad_credentials")

        conn
        |> put_flash(:error, "That email and password don't match anything.")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/sign_in")
    end
  end

  defp do_finish_mfa(conn, user_id, user_params) do
    case Accounts.fetch_user_by_id(user_id) do
      {:ok, user} ->
        case verify_second_factor(user, user_params["otp"], user_params["recovery_code"]) do
          :ok ->
            conn
            |> clear_pending_mfa()
            |> finalize_sign_in(user, user_params, "password+mfa")

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

  defp finalize_sign_in(conn, user, user_params, method) do
    Accounts.record_sign_in(user)
    Audit.log_for_user(user, "user.signed_in", payload: %{method: method})
    UserAuth.log_in_user(conn, user, user_params)
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
  defp verify_second_factor(user, otp, _recovery) when is_binary(otp) and otp != "",
    do: Auth.verify_mfa(user, otp)

  defp verify_second_factor(user, _, recovery) when is_binary(recovery) and recovery != "",
    do: Auth.consume_mfa_recovery_code(user, recovery)

  defp verify_second_factor(_, _, _), do: {:error, :invalid}

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
end
