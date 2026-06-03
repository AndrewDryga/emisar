defmodule EmisarWeb.UserConfirmationController do
  @moduledoc """
  One-off confirmation link handler. Hit `/confirm/:token` to flip
  `users.confirmed_at`.
  """
  use EmisarWeb, :controller

  alias Emisar.Auth

  def confirm(conn, %{"token" => token}) do
    # Works for signed-in and signed-out users alike. Signed-in users go
    # back to the app (the verify-email banner clears on the next mount);
    # signed-out users land on sign-in to continue.
    signed_in? = not is_nil(conn.assigns[:current_user])

    case Auth.confirm_user_by_token(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, if(signed_in?, do: "Email confirmed.", else: "Email confirmed. Sign in to continue."))
        |> redirect(to: post_confirm_path(signed_in?))

      {:error, :invalid_or_expired} ->
        conn
        |> put_flash(:error, "That confirmation link expired or was already used.")
        |> redirect(to: post_confirm_path(signed_in?))
    end
  end

  defp post_confirm_path(true), do: ~p"/app"
  defp post_confirm_path(false), do: ~p"/sign_in"
end
