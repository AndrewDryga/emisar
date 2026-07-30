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

      # Do not start database-backed contexts until a new node has stable SQL access.
      Emisar.DatabaseReadiness,

      # Contexts
      Emisar.Accounts,
      Emisar.ApiKeys,
      Emisar.Approvals,
      Emisar.Audit,
      Emisar.Billing,
      Emisar.Catalog,
      Emisar.OAuth,
      Emisar.MCPOperations,
      Emisar.SSO,
      Emisar.Runners,
      Emisar.Runs,
      Emisar.Runbooks
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Emisar.Supervisor)
  end
end
