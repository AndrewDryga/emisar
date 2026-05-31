defmodule Emisar.Runners.Runner do
  @moduledoc """
  A single emisar binary running on a host. State here is the most
  recent runner_state advertisement plus heartbeat-driven liveness.
  """

  use Emisar, :schema

  @statuses ~w(pending connected disconnected disabled)

  schema "runners" do
    field :name, :string
    field :external_id, :string
    field :group, :string
    field :hostname, :string
    field :labels, :map, default: %{}
    field :runner_version, :string
    field :status, :string, default: "pending"
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_disconnect_reason, :string
    field :last_heartbeat_at, :utc_datetime_usec
    field :action_load, :integer, default: 0
    field :packs, :map, default: %{}
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :bootstrap_auth_key, Emisar.Runners.AuthKey

    has_many :tokens, Emisar.Runners.Token
    has_many :actions, Emisar.Catalog.RunnerAction
    has_many :runs, Emisar.Runs.ActionRun

    timestamps()
  end

  def statuses, do: @statuses
end
