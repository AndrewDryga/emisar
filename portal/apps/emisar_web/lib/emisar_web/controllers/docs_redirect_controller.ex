defmodule EmisarWeb.DocsRedirectController do
  @moduledoc """
  Permanent redirects from retired documentation URLs to their canonical destinations.
  """
  use EmisarWeb, :controller

  @retired_guides [
    caddy_reload_demo: "/docs/investigate-a-service",
    deployment: "/docs/production",
    connect_cli_client: "/docs/connect-cli-agent",
    upgrades: "/docs/runner-upgrades",
    connect_coop: "/docs/connect-agent-sandboxes#coop",
    connect_docker_sandboxes: "/docs/connect-agent-sandboxes#docker-sandboxes",
    connect_nono: "/docs/connect-agent-sandboxes#nono",
    connect_dev_containers: "/docs/connect-agent-sandboxes#dev-containers"
  ]

  for {action, target} <- @retired_guides do
    def unquote(action)(conn, _params) do
      conn
      |> put_status(:moved_permanently)
      |> redirect(to: unquote(target))
    end
  end
end
