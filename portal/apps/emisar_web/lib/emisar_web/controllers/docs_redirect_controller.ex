defmodule EmisarWeb.DocsRedirectController do
  @moduledoc """
  Permanent redirects from retired documentation pages to their canonical sections.
  """
  use EmisarWeb, :controller

  @sandbox_guides [
    connect_coop: "/docs/connect-agent-sandboxes#coop",
    connect_docker_sandboxes: "/docs/connect-agent-sandboxes#docker-sandboxes",
    connect_nono: "/docs/connect-agent-sandboxes#nono",
    connect_dev_containers: "/docs/connect-agent-sandboxes#dev-containers"
  ]

  for {action, target} <- @sandbox_guides do
    def unquote(action)(conn, _params) do
      conn
      |> put_status(:moved_permanently)
      |> redirect(to: unquote(target))
    end
  end
end
