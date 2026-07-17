defmodule EmisarWeb.SSORequiredController do
  @moduledoc """
  The require_sso step-up shim (enforcement approach B). `on_mount(:ensure_sso_compliant)`
  bounces a non-SSO session here when the account mandates single sign-on. The GET
  only explains the next step; the explicit POST revokes the session and lands the
  operator on the account's branded sign-in, where they re-authenticate through the
  account's identity provider. Lives OUTSIDE the slug `live_session`, so it doesn't
  re-trigger the gate — no redirect loop.
  """
  use EmisarWeb, :controller
  alias EmisarWeb.UserAuth

  def show(conn, _params) do
    account = conn.assigns.current_account

    # Re-check compliance on GET: a compliant session — or one whose account no
    # longer mandates SSO — reaching this shim from a stale/copied link must not
    # be shown a false "SSO required" state and pushed to sign out.
    case UserAuth.account_compliance(
           account,
           conn.assigns[:current_auth],
           conn.assigns[:current_user]
         ) do
      :sso_required ->
        form = Phoenix.Component.to_form(%{}, as: "sso_required")
        render(conn, :show, account: account, form: form)

      _ ->
        redirect(conn, to: ~p"/app/#{account}")
    end
  end

  def revoke(conn, _params) do
    # require_authenticated_user → assign_current_account resolved the slug to a
    # membership (the user IS a member; require_sso is about HOW they signed in).
    account = conn.assigns.current_account

    UserAuth.log_out_user_with_flash(
      conn,
      "This team requires single sign-on. Sign in with your identity provider to continue.",
      ~p"/app/#{account}/sign_in"
    )
  end
end
