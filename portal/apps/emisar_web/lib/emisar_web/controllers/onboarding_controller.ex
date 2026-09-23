defmodule EmisarWeb.OnboardingController do
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Auth, Users}
  alias Emisar.Auth.Subject
  alias EmisarWeb.{OnboardingLive, RequestContext, UserAuth}

  def new(conn, params), do: render_form(conn, params)

  def create(%{assigns: %{current_user: %Users.User{} = user}} = conn, params) do
    name = submitted_name(params)

    subject = %Subject{
      actor: user,
      session_token_id: conn.assigns.current_auth.id,
      context: RequestContext.from_conn(conn)
    }

    case Accounts.create_account_with_owner_from_name(name, subject) do
      {:ok, account} ->
        continue_to_workspace(conn, account, params["billing_intent"])

      {:error, %Ecto.Changeset{data: %Accounts.Account{}} = changeset} ->
        conn |> put_status(:unprocessable_entity) |> render_form(params, changeset)

      {:error, :unauthorized} ->
        conn
        |> redirect(to: ~p"/session/recover?reason=personal_required")

      {:error, _reason} ->
        changeset = Accounts.change_account(%Accounts.Account{}, %{"name" => name})

        conn
        |> put_flash(:error, "Couldn't create this workspace. Try again.")
        |> put_status(:unprocessable_entity)
        |> render_form(params, changeset)
    end
  end

  # A member-only session has no personal login to own a new workspace.
  def create(%{assigns: %{current_auth: %Auth.UserToken{}}} = conn, _params),
    do: redirect(conn, to: ~p"/session/recover?reason=personal_required")

  def create(conn, _params) do
    conn
    |> put_flash(:error, "You must sign in to set up a workspace.")
    |> redirect(to: ~p"/sign_in")
  end

  defp continue_to_workspace(conn, account, token) do
    # Re-resolve the committed grant, including a memberless first-run browser.
    # The old pinned workspace may just have lost its SSO route.
    with {:ok, current} <- UserAuth.subject_for_account(conn, account.id),
         {:ok, member} <- Accounts.switch_account(account.id, current) do
      UserAuth.redirect_after_account_switch(conn, member, token)
    else
      {:error, _reason} ->
        conn
        |> put_flash(:error, "Workspace created. Sign in again to open it.")
        |> redirect(to: ~p"/session/recover")
    end
  end

  defp render_form(conn, params, changeset \\ nil) do
    conn
    |> put_layout(false)
    |> Phoenix.LiveView.Controller.live_render(OnboardingLive,
      session: %{
        "onboarding_params" => if(changeset, do: %{"name" => submitted_name(params)}),
        "onboarding_errors" => if(changeset, do: Keyword.take(changeset.errors, [:name])),
        "billing_intent" => params["billing_intent"] || get_session(conn, :billing_intent)
      }
    )
  end

  defp submitted_name(%{"account" => %{"name" => name}}) when is_binary(name), do: name
  defp submitted_name(_params), do: ""
end
