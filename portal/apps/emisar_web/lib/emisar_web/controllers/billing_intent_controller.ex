defmodule EmisarWeb.BillingIntentController do
  @moduledoc """
  Captures a public Team plan/cycle choice, then lets an authenticated operator
  choose the exact workspace they intend to review before checkout.

  GET never contacts Paddle. The selection POST re-resolves membership and
  billing authority, pins that workspace in the session, and forwards to the
  ordinary Billing page, whose explicit Upgrade action remains the only checkout
  boundary.
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Billing}
  alias EmisarWeb.{BillingIntent, UserAuth}

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  def capture(conn, %{"intent" => token}) do
    case BillingIntent.verify(token) do
      {:ok, _intent} ->
        conn
        |> put_session(:billing_intent, token)
        |> redirect(to: capture_destination(conn, token))

      {:error, :invalid} ->
        conn
        |> delete_session(:billing_intent)
        |> redirect(to: default_destination(conn))
    end
  end

  def capture(conn, _params) do
    conn
    |> delete_session(:billing_intent)
    |> redirect(to: default_destination(conn))
  end

  def show(conn, _params) do
    with {:ok, token, intent} <- pending_intent(conn),
         {:ok, accounts, _meta} <-
           Accounts.list_accounts_for_user(conn.assigns.current_subject,
             page: [limit: 100],
             count: false
           ) do
      render(conn, :show,
        accounts: manageable_accounts(conn, accounts),
        intent: intent,
        token: token
      )
    else
      _error -> invalid_intent(conn)
    end
  end

  def select(conn, %{"account_id" => account_id}) when is_binary(account_id) do
    with {:ok, token, _intent} <- pending_intent(conn),
         {:ok, chosen_subject} <- UserAuth.subject_for_account(conn, account_id),
         true <- Billing.subject_can_manage_billing?(chosen_subject),
         {:ok, membership} <-
           Accounts.switch_account(account_id, conn.assigns.current_subject) do
      conn
      |> delete_session(:billing_intent)
      |> UserAuth.switch_account(membership)
      |> redirect(to: ~p"/app/#{membership.account}/settings/billing?billing_intent=#{token}")
    else
      false -> denied_selection(conn)
      {:error, :unauthorized} -> denied_selection(conn)
      {:error, :not_found} -> denied_selection(conn)
      _error -> invalid_intent(conn)
    end
  end

  def select(conn, _params), do: denied_selection(conn)

  def cancel(conn, _params) do
    conn
    |> delete_session(:billing_intent)
    |> redirect(to: ~p"/app")
  end

  defp pending_intent(conn) do
    token = get_session(conn, :billing_intent)

    case BillingIntent.verify(token) do
      {:ok, intent} -> {:ok, token, intent}
      {:error, :invalid} -> {:error, :invalid}
    end
  end

  defp denied_selection(conn) do
    conn
    |> put_flash(
      :error,
      "Only an owner, admin, or billing manager for that workspace can continue to checkout."
    )
    |> show(%{})
  end

  defp manageable_accounts(conn, accounts) do
    Enum.filter(accounts, fn account ->
      case UserAuth.subject_for_account(conn, account.id) do
        {:ok, subject} -> Billing.subject_can_manage_billing?(subject)
        {:error, :not_found} -> false
      end
    end)
  end

  defp invalid_intent(conn) do
    conn
    |> delete_session(:billing_intent)
    |> put_flash(:error, "That Team checkout choice expired. Choose a plan again.")
    |> redirect(to: ~p"/pricing")
  end

  defp capture_destination(%{assigns: %{current_user: %Emisar.Users.User{}}}, _token),
    do: ~p"/app/billing/start"

  defp capture_destination(_conn, token), do: ~p"/sign_up?billing_intent=#{token}"

  defp default_destination(%{assigns: %{current_user: %Emisar.Users.User{}}}), do: ~p"/app"
  defp default_destination(_conn), do: ~p"/sign_up"
end
