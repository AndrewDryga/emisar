defmodule Emisar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Emisar.Repo,
      {DNSCluster, query: Application.get_env(:emisar, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Emisar.PubSub.Server},
      Emisar.Runners.Presence,
      {Finch, name: Emisar.Finch},
      {Oban, Application.fetch_env!(:emisar, Oban)},
      # Per-account OIDC provider-config workers (discovery + JWKS cache)
      # are started lazily under this supervisor, named via the registry by
      # provider id. See `Emisar.SSO.OIDC.Oidcc`.
      {Registry, keys: :unique, name: Emisar.SSO.OIDC.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Emisar.SSO.OIDC.ProviderSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Emisar.Supervisor)
  end
end
