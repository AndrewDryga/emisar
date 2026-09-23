defmodule EmisarWeb.SSORequiredController do
  @moduledoc """
  Workspace SSO step-up. A read-only GET offers the current Member's linked
  providers; the explicit POST starts a purpose-bound SSOController ceremony.
  Lives outside the compliance-gated live_session so recovery cannot loop.
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, SSO}

  def show(conn, _params) do
    account = conn.assigns.current_account

    # Re-check compliance on GET: a compliant session — or one whose account no
    # longer mandates SSO — reaching this shim from a stale/copied link must not
    # be shown a false "SSO required" state and pushed to sign out.
    case Accounts.ensure_account_compliant(account, conn.assigns.current_subject) do
      {:error, :sso_required} ->
        case SSO.list_session_step_up_providers(conn.assigns.current_subject) do
          {:ok, providers} ->
            render(conn, :show, account: account, providers: providers)

          {:error, _reason} ->
            redirect(conn, to: ~p"/session/recover")
        end

      :ok ->
        redirect(conn, to: ~p"/app/#{account}")

      {:error, :mfa_required} ->
        redirect(conn, to: ~p"/app/mfa_setup")

      {:error, _reason} ->
        redirect(conn, to: ~p"/session/recover")
    end
  end
end
