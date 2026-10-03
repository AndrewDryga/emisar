defmodule EmisarWeb.AccountRedirectController do
  @moduledoc """
  Slugless `/app` URLs → the canonical slugged URL for one of this browser's
  signed-in workspaces: bare `/app`, plus the deep-link shorthands that
  installers, the bridge's `--help`, and docs print without knowing the
  workspace (`/app/runners`, `/app/runners/install`, `/app/runners/keys`,
  `/app/runners/keys/new`, `/app/runs`, `/app/approvals`, `/app/runbooks`,
  `/app/runbooks/new`, `/app/runbooks/import`, `/app/policies`, `/app/packs`,
  `/app/audit`, `/app/audit/export`, `/app/agents`, `/app/agents/connect`,
  `/app/team`, `/app/team/invite`, `/app/sso`, `/app/sso/new`, `/app/billing`,
  `/activate`).

  `require_signed_in` has already resolved the cookie's live sessions (or sent
  a browser with none to `/sign_in`). One signed-in workspace forwards straight
  to its slug, keeping the suffix; several render a small "Choose a workspace"
  page whose links keep the suffix too, so a deep link survives the choice.
  """
  use EmisarWeb, :controller

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  def show(conn, _params), do: forward(conn, &~p"/app/#{&1}")

  def runners(conn, _params), do: forward(conn, &~p"/app/#{&1}/runners")

  def connect_runner(conn, _params), do: forward(conn, &~p"/app/#{&1}/runners/install")

  def enrollment_keys(conn, _params), do: forward(conn, &~p"/app/#{&1}/runners/keys")

  def new_enrollment_key(conn, _params), do: forward(conn, &~p"/app/#{&1}/runners/keys/new")

  def runs(conn, _params), do: forward(conn, &~p"/app/#{&1}/runs")

  def approvals(conn, _params), do: forward(conn, &~p"/app/#{&1}/approvals")

  def agents(conn, _params), do: forward(conn, &~p"/app/#{&1}/agents")

  def connect_agent(conn, _params), do: forward(conn, &~p"/app/#{&1}/agents/connect")

  def runbooks(conn, _params), do: forward(conn, &~p"/app/#{&1}/runbooks")

  def new_runbook(conn, _params), do: forward(conn, &~p"/app/#{&1}/runbooks/new")

  def import_runbook(conn, _params), do: forward(conn, &~p"/app/#{&1}/runbooks/import")

  def policies(conn, _params), do: forward(conn, &~p"/app/#{&1}/policies")

  def packs(conn, _params), do: forward(conn, &~p"/app/#{&1}/packs")

  def audit(conn, _params), do: forward(conn, &~p"/app/#{&1}/audit")

  def audit_export(conn, _params), do: forward(conn, &~p"/app/#{&1}/audit/export")

  # /sso/new — the provider guides open with "add the connection in emisar", and
  # a docs page cannot know the reader's workspace slug to link it.
  def add_sso_provider(conn, _params), do: forward(conn, &~p"/app/#{&1}/settings/sso/new")

  def sso(conn, _params), do: forward(conn, &~p"/app/#{&1}/settings/sso")

  # /team — authentication docs link the workspace-wide MFA and SSO controls,
  # but cannot know the reader's workspace slug.
  def team(conn, _params), do: forward(conn, &~p"/app/#{&1}/settings/team")

  def invite_team_member(conn, _params),
    do: forward(conn, &~p"/app/#{&1}/settings/team/invite")

  def billing(conn, _params), do: forward(conn, &~p"/app/#{&1}/settings/billing")

  # /activate — the device-grant approval URL the MCP installer prints,
  # keeping the ?code= deep link through the forward.
  def activate(conn, %{"code" => code}) when is_binary(code),
    do: forward(conn, &~p"/app/#{&1}/activate?code=#{code}")

  def activate(conn, _params), do: forward(conn, &~p"/app/#{&1}/activate")

  # `path_for` builds the destination for one workspace, so the same suffix
  # reaches the single redirect and every link on the picker.
  defp forward(conn, path_for) do
    case conn.assigns.signed_in_sessions do
      [%{membership: %{account: account}}] ->
        redirect(conn, to: path_for.(account))

      sessions ->
        choices =
          Enum.map(sessions, fn %{membership: %{account: account} = membership} ->
            %{account: account, email: membership.email, path: path_for.(account)}
          end)

        render(conn, :pick, choices: choices, page_title: "Choose a workspace")
    end
  end
end
