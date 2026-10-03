defmodule EmisarWeb.BillingIntentController do
  @moduledoc """
  Captures a public Team plan/cycle choice, then lets a signed-in operator
  choose the exact workspace they intend to review before checkout.

  GET never contacts Paddle. The selection POST authenticates this browser's
  own session for the chosen workspace, re-checks its billing authority, and
  forwards to that workspace's ordinary Billing page, whose explicit Upgrade
  action remains the only checkout boundary. Nothing is switched server-side:
  the workspace is in the URL from here on.
  """
  use EmisarWeb, :controller
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias EmisarWeb.{BillingIntent, RequestContext, UserAuth}

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
    case pending_intent(conn) do
      {:ok, token, intent} ->
        render(conn, :show, accounts: manageable_accounts(conn), intent: intent, token: token)

      _error ->
        invalid_intent(conn)
    end
  end

  def select(conn, %{"account_id" => account_id}) when is_binary(account_id) do
    with {:ok, token, _intent} <- pending_intent(conn),
         {:ok, chosen_subject} <- UserAuth.subject_for_account(conn, account_id),
         true <- Billing.subject_can_manage_billing?(chosen_subject) do
      conn
      |> delete_session(:billing_intent)
      |> redirect(to: ~p"/app/#{chosen_subject.account}/settings/billing?billing_intent=#{token}")
    else
      false ->
        denied_selection(conn)

      {:error, :not_found} ->
        denied_selection(conn)

      {:error, :invalid} ->
        invalid_intent(conn)
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
      "Only an owner, admin, or billing manager for that workspace can review the Team upgrade."
    )
    |> show(%{})
  end

  # The signed-in workspaces whose Member may manage billing. `require_signed_in`
  # already resolved each live session with its Member and workspace, so the
  # Subjects are built from those rows without another read.
  defp manageable_accounts(conn) do
    context = RequestContext.from_conn(conn)

    conn.assigns.signed_in_sessions
    |> Enum.filter(&Billing.subject_can_manage_billing?(Subject.for_session(&1, context)))
    |> Enum.map(& &1.membership.account)
  end

  defp invalid_intent(conn) do
    conn
    |> delete_session(:billing_intent)
    |> put_flash(:error, "That plan selection is no longer valid. Choose a plan again.")
    |> redirect(to: ~p"/pricing")
  end

  # "Signed in" is the cookie holding a workspace session (no database read on
  # this public handoff); the selector then resolves the live ones.
  defp capture_destination(%{assigns: %{signed_in?: true}}, _token), do: ~p"/app/billing/start"
  defp capture_destination(_conn, token), do: ~p"/sign_up?billing_intent=#{token}"

  defp default_destination(%{assigns: %{signed_in?: true}}), do: ~p"/app"
  defp default_destination(_conn), do: ~p"/sign_up"
end
