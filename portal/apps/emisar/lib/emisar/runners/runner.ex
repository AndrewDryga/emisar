defmodule Emisar.Runners.Runner do
  @moduledoc """
  A single emisar binary running on a host. The DB row holds the most
  recent runner_state advertisement plus durable connect/disconnect
  history; live connection state (online, action_load, last heartbeat)
  is Phoenix.Presence, surfaced here as virtual fields.
  """

  use Emisar, :schema

  schema "runners" do
    field :name, :string
    field :external_id, :string
    field :group, :string
    field :hostname, :string
    field :labels, :map, default: %{}
    field :runner_version, :string
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_disconnect_reason, :string
    field :packs, :map, default: %{}

    # Connection state lives in `Emisar.Runners.Presence`, not the DB.
    # These virtuals are filled from presence metadata by the context
    # read functions; see `Emisar.Runners.connection_state/1`.
    field :online?, :boolean, virtual: true, default: false
    field :action_load, :integer, virtual: true, default: 0
    field :last_heartbeat_at, :utc_datetime_usec, virtual: true

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :bootstrap_auth_key, Emisar.Runners.AuthKey

    has_many :tokens, Emisar.Runners.Token
    has_many :actions, Emisar.Catalog.RunnerAction
    has_many :runs, Emisar.Runs.ActionRun

    timestamps()
  end
end
