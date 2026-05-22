defmodule Emisar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Emisar.Repo,
      {DNSCluster, query: Application.get_env(:emisar, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Emisar.PubSub.Server},
      {Finch, name: Emisar.Finch},
      {Oban, Application.fetch_env!(:emisar, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Emisar.Supervisor)
  end
end
