defmodule EmisarWeb.AccountRedirectController do
  @moduledoc """
  Slugless `/app` URLs → the canonical slugged URL for the user's current
  account: bare `/app`, plus the deep-link shorthands that installers, the
  bridge's `--help`, and docs print without knowing the account
  (`/app/runners`, `/app/runners/install`, `/app/runners/keys`,
  `/app/runners/keys/new`, `/app/runs`, `/app/approvals`, `/app/runbooks`,
  `/app/runbooks/new`, `/app/runbooks/import`, `/app/policies`, `/app/packs`,
  `/app/audit`, `/app/audit/export`, `/app/agents`, `/app/agents/connect`,
  `/app/team`, `/app/team/invite`, `/app/sso`, `/app/sso/new`, `/app/billing`).

  `require_authenticated_user` has already run `assign_current_account/1`, which
  resolves the session-hinted (else default) membership — or bounces a
  no-membership user to onboarding / logs out a fully-suspended one. So by the
  time we get here `current_account` is set; we just forward to its slug.
  """
  use EmisarWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}")
  end

  def runners(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runners")
  end

  def connect_runner(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runners/install")
  end

  def enrollment_keys(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runners/keys")
  end

  def new_enrollment_key(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runners/keys/new")
  end

  def runs(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/runs")
  end

  def approvals(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/approvals")
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

  def policies(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/policies")
  end

  def packs(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/packs")
  end

  def audit(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/audit")
  end

  def audit_export(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/audit/export")
  end

  # /sso/new — the provider guides open with "add the connection in emisar", and
  # a docs page cannot know the reader's account slug to link it.
  def add_sso_provider(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/sso/new")
  end

  def sso(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/sso")
  end

  # /team — authentication docs link the account-wide MFA and SSO controls, but
  # cannot know the reader's account slug.
  def team(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/team")
  end

  def invite_team_member(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/team/invite")
  end

  def billing(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}/settings/billing")
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
