defmodule EmisarWeb.AccountRedirectController do
  @moduledoc """
  Slugless `/app` URLs → the canonical slugged URL for the user's current
  account: bare `/app`, plus the deep-link shorthands that installers, the
  bridge's `--help`, and docs print without knowing the account
  (`/app/agents`, `/app/agents/connect`).

  `require_authenticated_user` has already run `assign_current_account/1`, which
  resolves the session-hinted (else default) membership — or bounces a
  no-membership user to onboarding / logs out a fully-suspended one. So by the
  time we get here `current_account` is set; we just forward to its slug.
  """
  use EmisarWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}")
  end

  def agents(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/agents")
  end

  def connect_agent(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/agents/connect")
  end
end
