defmodule EmisarWeb.SessionRecoveryController do
  @moduledoc "Recovery outside both the signed-out guard and workspace authorization gate."
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Users}
  alias Emisar.Auth.Subject
  alias EmisarWeb.UserAuth

  def show(conn, params) do
    accounts = continuing_accounts(conn)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> render(:show,
      accounts: accounts,
      signed_in?: not is_nil(conn.assigns[:current_user]),
      sso_incomplete?: params["reason"] == "sso_incomplete",
      personal_required?: params["reason"] == "personal_required"
    )
  end

  # GET never drops the bearer. Only this explicit CSRF-protected choice signs
  # out this browser. A branded return requires its own surviving exact grant;
  # arbitrary params cannot choose an external or unproved destination.
  def restart(conn, params) do
    to = restart_path(conn, params["account_id_or_slug"])
    UserAuth.log_out_user(conn, to)
  end

  defp continuing_accounts(%{assigns: %{current_user: %Users.User{} = user}} = conn) do
    # Recovery has no current workspace Subject. This deliberate cross-account
    # read still resolves only this exact browser's live, frozen Member grants.
    subject = %Subject{actor: user, session_token_id: conn.assigns.current_auth.id}

    {:ok, accounts, _metadata} =
      Accounts.list_accounts_for_user(subject, page: [limit: 100], count: false)

    current_id = get_session(conn, :current_account_id)
    Enum.sort_by(accounts, &(&1.id != current_id))
  end

  defp continuing_accounts(_conn), do: []

  defp restart_path(%{assigns: %{current_user: %Users.User{}}} = conn, account_ref)
       when is_binary(account_ref) do
    case UserAuth.subject_for_account(conn, account_ref) do
      {:ok, subject} -> ~p"/app/#{subject.account}/sign_in"
      {:error, :not_found} -> ~p"/sign_in"
    end
  end

  defp restart_path(_conn, _account_ref), do: ~p"/sign_in"
end
