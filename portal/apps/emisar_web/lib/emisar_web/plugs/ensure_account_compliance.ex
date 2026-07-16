defmodule EmisarWeb.Plugs.EnsureAccountCompliance do
  @moduledoc """
  Enforces an account's `require_sso` / `require_mfa` controls on CONTROLLER
  routes — which `live_session` `on_mount` hooks do NOT cover. A `get`/`post`
  controller action lexically nested in a `live_session` block still runs
  WITHOUT those hooks, so a magic-link session in an enforcing account could
  reach controller surfaces the LiveViews gate: the audit CSV download and the
  OAuth consent screen (which mints a persistent MCP bearer).

  Composed after `:require_authenticated_user` (which resolves
  `current_account` + the session's auth provenance into assigns), it runs the
  SAME `EmisarWeb.UserAuth.account_compliance/3` predicate the LiveView hooks
  use — so the two enforcement paths can't drift — and bounces a non-compliant
  session to the matching step-up (the SSO shim / the MFA setup interstitial)
  before the action runs, mirroring the hooks' redirects.
  """
  use EmisarWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias EmisarWeb.UserAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    account = conn.assigns[:current_account]
    auth = conn.assigns[:current_auth]
    user = conn.assigns[:current_user]

    case UserAuth.account_compliance(account, auth, user) do
      :sso_required ->
        conn |> redirect(to: ~p"/app/#{account}/sso_required") |> halt()

      :mfa_required ->
        conn |> redirect(to: ~p"/app/mfa_setup") |> halt()

      :ok ->
        conn
    end
  end
end
