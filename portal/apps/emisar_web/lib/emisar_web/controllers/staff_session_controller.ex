defmodule EmisarWeb.StaffSessionController do
  @moduledoc """
  The staff sign-in at `/admin/sign_in`: the staff address first, then the
  emailed code and the authenticator code together, and the staff sign-out.

  A controller on the staff cookie, so nothing before the staff session exists
  opens a socket or touches the workspace session. The pending sign-in (the code
  id and the browser half of the split code) lives in the encrypted staff
  cookie, which is what binds the emailed code to the browser that asked.
  """
  use EmisarWeb, :controller
  alias Emisar.Admin
  alias EmisarWeb.{RequestContext, StaffAuth}

  # Per-IP cap on both POSTs, on top of each code's attempt budget, the
  # per-login throttle on code requests and the lock after wrong authenticator
  # codes. The ten a minute is far above what one person needs.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "staff_sign_in", limit: 10, window_ms: 60_000]
       when action in [:create, :verify]

  def new(conn, _params), do: render(conn, :new, form: email_form(""))

  @doc """
  Asks for an emailed code. Every address lands on the same code page with the
  same session shape; only a staff address is sent anything.
  """
  def create(conn, %{"staff" => %{"email" => email}}) when is_binary(email) do
    {:ok, %{token_id: token_id, nonce: nonce}} =
      Admin.request_staff_sign_in(email, RequestContext.from_conn(conn))

    conn
    |> put_session(:staff_sign_in, %{
      "token_id" => token_id,
      "nonce" => nonce,
      "email" => email |> String.trim() |> String.slice(0, 254)
    })
    |> redirect(to: ~p"/admin/sign_in/code")
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/admin/sign_in")

  def code(conn, _params) do
    case get_session(conn, :staff_sign_in) do
      %{"email" => email} -> render_code(conn, email, nil)
      _none -> redirect(conn, to: ~p"/admin/sign_in")
    end
  end

  @doc "Checks the emailed code and the authenticator code in one submission."
  def verify(conn, %{"sign_in" => %{"secret" => code, "otp" => otp}})
      when is_binary(code) and is_binary(otp) do
    case get_session(conn, :staff_sign_in) do
      %{"token_id" => token_id, "nonce" => nonce, "email" => email} ->
        context = RequestContext.from_conn(conn)

        case Admin.complete_staff_sign_in(token_id, nonce, code, otp, context) do
          {:ok, raw_token, _staff_session} ->
            StaffAuth.log_in_staff(conn, raw_token)

          {:error, :locked} ->
            render_code(
              conn,
              email,
              "Too many wrong authenticator codes locked this staff login. Reset it from the production node."
            )

          {:error, :invalid} ->
            render_code(
              conn,
              email,
              "Those codes didn't work. Check both and try again. After five tries, request a new email code."
            )
        end

      _none ->
        redirect(conn, to: ~p"/admin/sign_in")
    end
  end

  def verify(conn, _params), do: redirect(conn, to: ~p"/admin/sign_in/code")

  def delete(conn, _params), do: StaffAuth.log_out_staff(conn)

  defp render_code(conn, email, error),
    do: render(conn, :code, email: email, form: code_form(), error: error)

  defp email_form(email), do: Phoenix.Component.to_form(%{"email" => email}, as: "staff")

  defp code_form, do: Phoenix.Component.to_form(%{"secret" => "", "otp" => ""}, as: "sign_in")
end
