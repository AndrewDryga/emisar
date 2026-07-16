defmodule Emisar.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Persistence
      Emisar.Repo,

      # Cluster, PubSub, presence, and shared HTTP client
      {Phoenix.PubSub, name: Emisar.PubSub.Server},
      Emisar.Runners.Presence,
      {Finch, name: Emisar.Finch},

      # BEAM clustering on GCP MIGs: libcluster's GCE strategy discovers peers via
      # the Compute API (Emisar.Cluster.GCE, which uses Emisar.Finch above). Empty
      # topologies keep local and single-node releases inert.
      {Cluster.Supervisor,
       [Application.get_env(:emisar, :cluster_topologies, []), [name: Emisar.ClusterSupervisor]]},

      # Per-account OIDC provider-config workers (discovery + JWKS cache)
      # are started lazily under this supervisor, named via the registry by
      # provider id. See `Emisar.SSO.OIDC.Oidcc`.
      {Registry, keys: :unique, name: Emisar.SSO.OIDC.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Emisar.SSO.OIDC.ProviderSupervisor},

      # Contexts
      Emisar.Accounts,
      Emisar.Approvals,
      Emisar.Audit,
      Emisar.Billing,
      Emisar.OAuth,
      Emisar.MCPOperations,
      Emisar.Runs
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Emisar.Supervisor)
  end
end
