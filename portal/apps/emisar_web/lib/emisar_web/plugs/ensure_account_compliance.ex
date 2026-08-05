defmodule EmisarWeb.Plugs.EnsureAccountCompliance do
  @moduledoc """
  Enforces an account's `require_sso` / `require_mfa` controls on CONTROLLER
  routes — which `live_session` `on_mount` hooks do NOT cover. A `get`/`post`
  controller action lexically nested in a `live_session` block still runs
  WITHOUT those hooks, so a magic-link session in an enforcing account could
  reach controller surfaces the LiveViews gate.

  Wired into the audit CSV download ONLY. The OAuth consent screen enforces the
  same policy inside `Emisar.OAuth.issue_code/3`'s locked transaction instead,
  because session-account gating would be wrong there (the consent screen has no
  single current account). Do not read this plug as covering OAuth and delete
  that check.

  Composed after `:require_authenticated_user` (which resolves
  `current_account` + the subject carrying the session's auth provenance into
  assigns), it runs the SAME `Emisar.Accounts.ensure_account_compliant/2` policy
  the LiveView hooks use — so the two enforcement paths can't drift — and bounces
  a non-compliant session to the matching step-up (the SSO shim / the MFA setup
  interstitial) before the action runs, mirroring the hooks' redirects.
  """
  use EmisarWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Emisar.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    account = conn.assigns[:current_account]

    case Accounts.ensure_account_compliant(account, conn.assigns[:current_subject]) do
      :ok ->
        conn

      {:error, :sso_required} ->
        conn |> redirect(to: ~p"/app/#{account}/sso_required") |> halt()

      {:error, :mfa_required} ->
        conn |> redirect(to: ~p"/app/mfa_setup") |> halt()

      # The pipeline resolves the account and subject together. Treat an
      # inconsistent or unauthorized pair like every other tenant-scope miss.
      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end
end
