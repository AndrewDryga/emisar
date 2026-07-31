defmodule EmisarWeb.AccountRedirectController do
  @moduledoc """
  Slugless `/app` URLs → the canonical slugged URL for the user's current
  account: bare `/app`, plus the deep-link shorthands that installers, the
  bridge's `--help`, and docs print without knowing the account
  (`/app/agents`, `/app/agents/connect`, `/app/runbooks`, `/app/runbooks/new`,
  `/app/runbooks/import`).

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

  def runbooks(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runbooks")
  end

  def new_runbook(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runbooks/new")
  end

  def import_runbook(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runbooks/import")
  end

  # /sso/new — the provider guides open with "add the connection in emisar", and
  # a docs page cannot know the reader's account slug to link it.
  def add_sso_provider(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/sso/new")
  end

  # /activate — the device-grant approval URL the MCP installer prints,
  # keeping the ?code= deep link through the forward.
  def activate(conn, %{"code" => code}) when is_binary(code) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/activate?code=#{code}")
  end

  def activate(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/activate")
  end
end
