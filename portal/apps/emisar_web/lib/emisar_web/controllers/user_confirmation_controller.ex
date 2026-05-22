defmodule EmisarWeb.UserConfirmationController do
  @moduledoc """
  One-off confirmation link handler. Hit `/confirm/:token` to flip
  `users.confirmed_at`.
  """
  use EmisarWeb, :controller

  alias Emisar.Auth

  def confirm(conn, %{"token" => token}) do
    case Auth.confirm_user_by_token(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email confirmed. Sign in to continue.")
        |> redirect(to: ~p"/sign_in")

      {:error, :invalid_or_expired} ->
        conn
        |> put_flash(:error, "That confirmation link expired or was already used.")
        |> redirect(to: ~p"/sign_in")
    end
  end
end
